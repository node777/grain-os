//! Steward: the root task of a Grain system.
//!
//! Steward holds every initial capability and does one job: make the system
//! the manifest describes, and keep it that way.
//!
//!   1. Verify the boot image: every program's BLAKE3 hash and the closure
//!      hash over the manifest and all programs.
//!   2. Find devices in the device tree and probe the virtio transports.
//!   3. For each domain: carve a private untyped region; build its CSpace,
//!      address space, program, stack, DomainInfo page, CPU budget and
//!      capabilities (services it uses and provides, devices, a write-only
//!      console if granted); start it.
//!   4. Serve the lifecycle endpoint: tasks report exit codes; faults arrive
//!      here too. A faulted domain with `restart = .on_fault` is rebuilt from
//!      its image by resetting its region, up to `max_restarts`.
//!
//! The manifest is checked at compile time (`schema.check`), so Steward only
//! ever runs a system whose wiring is sound.
const std = @import("std");
const g = @import("grain");
const abi = g.abi;
const S = g.S;
const D = g.domain;
const schema = @import("schema");
const image = @import("image");
const elf = @import("elf");
const fdt = @import("fdt");
const proto = @import("proto");

const manifest: schema.Manifest = @import("system.zon");
comptime {
    schema.check(manifest, "system manifest");
    checkProtocols(manifest, "system manifest");
}

/// Every protocol a manifest names must be defined in grain/proto.
pub fn checkProtocols(comptime m: schema.Manifest, comptime file: []const u8) void {
    comptime {
        @setEvalBranchQuota(100_000);
        var known: []const u8 = "";
        for (proto.names(), 0..) |n, i| known = known ++ (if (i > 0) ", " else "") ++ n;
        for (m.domains) |d| {
            for (d.provides) |p| if (!proto.known(p.protocol))
                @compileError(file ++ ": domain '" ++ d.name ++ "' provides '" ++ p.name ++ "' as " ++ p.protocol ++ ", which is not defined in grain/proto (known: " ++ known ++ ")");
            for (d.uses) |u| if (!proto.known(u.protocol))
                @compileError(file ++ ": domain '" ++ d.name ++ "' uses " ++ u.protocol ++ ", which is not defined in grain/proto (known: " ++ known ++ ")");
        }
    }
}
const image_bytes = @embedFile("system.img");

const ndomains = manifest.domains.len;
/// Lifecycle badges with this bit set are fault messages from a domain thread.
const fault_flag: usize = 1 << 16;
/// A scratch window in Steward's own address space for filling pages.
const scratch_va: usize = 0x5000_0000;

var boot: *const abi.BootInfo = undefined;
var img: image.Image = undefined;
var pool: g.CPtr = 0; // the largest RAM untyped
var lifecycle: g.CPtr = 0;

// ---------------------------------------------------------------------------
// Steward's own capability slots: a simple free list.

var next_slot: g.CPtr = 0;
var free_slots: [256]g.CPtr = undefined;
var free_count: usize = 0;

fn slot() g.CPtr {
    if (free_count > 0) {
        free_count -= 1;
        return free_slots[free_count];
    }
    next_slot += 1;
    return next_slot - 1;
}

fn release(s: g.CPtr) void {
    _ = g.invoke(S.cnode, abi.CNodeMethod.delete, .{s});
    if (free_count < free_slots.len) {
        free_slots[free_count] = s;
        free_count += 1;
    }
}

fn ok(r: g.Result) !void {
    if (!r.ok()) return g.statusError(r.status);
}

fn retypeFrom(untyped: g.CPtr, kind: abi.Kind, bits: usize) !g.CPtr {
    const s = slot();
    ok(g.invoke(untyped, abi.UntypedMethod.retype, .{ kind, bits, s })) catch |e| {
        _ = release(s);
        return e;
    };
    return s;
}

/// Map a frame into `vspace`, making page tables from `untyped` as needed.
/// Table capabilities stay in `owned` so they can be released afterwards.
fn mapInto(untyped: g.CPtr, vspace: g.CPtr, frame: g.CPtr, va: usize, rights: abi.Rights, owned: *Owned) !void {
    var tries: usize = 0;
    while (tries < 3) : (tries += 1) {
        const r = g.invoke(vspace, abi.VSpaceMethod.map_frame, .{ frame, va, rights.bits() });
        switch (r.status) {
            .ok => return,
            .no_page_table => {
                const l1 = try retypeFrom(untyped, .page_table, 1);
                if (g.invoke(vspace, abi.VSpaceMethod.map_table, .{ l1, va }).ok()) {
                    owned.add(l1);
                } else {
                    release(l1);
                    const l0 = try retypeFrom(untyped, .page_table, 0);
                    owned.add(l0);
                    try ok(g.invoke(vspace, abi.VSpaceMethod.map_table, .{ l0, va }));
                }
            },
            else => return g.statusError(r.status),
        }
    }
    return error.MapFailed;
}

/// Slots Steward fills while building a domain and releases afterwards (the
/// objects live on in the domain's region; Steward only drops its copies).
const Owned = struct {
    slots: [512]g.CPtr = undefined,
    n: usize = 0,

    fn add(o: *Owned, s: g.CPtr) void {
        if (o.n < o.slots.len) {
            o.slots[o.n] = s;
            o.n += 1;
        }
    }

    fn releaseAll(o: *Owned) void {
        for (o.slots[0..o.n]) |s| release(s);
        o.n = 0;
    }
};

var scratch_tables = Owned{};

/// Fill a frame through the scratch window in Steward's own address space.
fn withScratch(frame: g.CPtr, ctx: anytype, comptime f: fn (*[4096]u8, @TypeOf(ctx)) void) !void {
    try mapInto(pool, S.vspace, frame, scratch_va, .{ .read = true, .write = true }, &scratch_tables);
    f(@ptrFromInt(scratch_va), ctx);
    try ok(g.invoke(S.vspace, abi.VSpaceMethod.unmap, .{scratch_va}));
}

// ---------------------------------------------------------------------------
// Devices

const VirtioDevice = struct {
    phys: u64,
    irq_line: u32,
    virtio_id: u32,
    frame: g.CPtr, // Steward's capability to the MMIO page
    irq: g.CPtr = 0, // created on first assignment
    owner: ?usize = null,
};

var devices: [16]VirtioDevice = undefined;
var device_count: usize = 0;

fn findDeviceUntyped(base: u64) ?g.CPtr {
    for (boot.untyped[0..boot.untyped_count], 0..) |u, i| {
        if (u.is_device != 0 and u.base <= base and base < u.base + u.size) return S.first_untyped + @as(g.CPtr, @intCast(i));
    }
    return null;
}

fn probeDevices() !void {
    if (boot.dtb_size == 0) return;
    const tree = try fdt.Fdt.init(@as([*]const u8, @ptrFromInt(boot.dtb_addr))[0..boot.dtb_size]);
    var nodes_buf: [16]fdt.DeviceNode = undefined;
    const nodes = try fdt.findCompatible(tree, "virtio,mmio", &nodes_buf);
    for (nodes) |n| {
        const ut = findDeviceUntyped(n.reg.base) orelse continue;
        const frame = retypeFrom(ut, .frame, 12) catch continue;
        try mapInto(pool, S.vspace, frame, scratch_va, .{ .read = true, .write = true }, &scratch_tables);
        const id = g.virtio.Device.identify(scratch_va) orelse 0;
        try ok(g.invoke(S.vspace, abi.VSpaceMethod.unmap, .{scratch_va}));
        if (id == 0) {
            release(frame); // an empty transport
            continue;
        }
        devices[device_count] = .{ .phys = n.reg.base, .irq_line = n.irq orelse 0, .virtio_id = id, .frame = frame };
        device_count += 1;
        g.record("device_found", .{ .bus = "virtio_mmio", .virtio_id = id, .phys = g.klog.hex(n.reg.base), .irq = n.irq orelse 0 });
    }
}

fn claimDevice(virtio_id: u32, owner: usize) ?*VirtioDevice {
    // A restarted domain gets its own devices back.
    for (devices[0..device_count]) |*d| if (d.owner == owner and d.virtio_id == virtio_id) return d;
    for (devices[0..device_count]) |*d| if (d.owner == null and d.virtio_id == virtio_id) {
        d.owner = owner;
        return d;
    };
    return null;
}

// ---------------------------------------------------------------------------
// Domains

const Status = enum { not_started, running, exited, failed };

const Domain = struct {
    region: g.CPtr = 0,
    restarts: u32 = 0,
    status: Status = .not_started,
    exit_code: u16 = 0,
    /// One endpoint per provided service, in Steward's memory so it
    /// survives the provider's restarts.
    endpoints: [schema.max_provides]g.CPtr = @splat(0),
    thread_id: u64 = 0,
};

var domains: [ndomains]Domain = @splat(.{});

fn ticks(us: u64) u64 {
    return boot.timebase_hz * us / 1_000_000;
}

fn log2Ceil(x: u64) u6 {
    return @intCast(std.math.log2_int_ceil(u64, @max(x, 4096)));
}

const InfoFill = struct { info: *const D.DomainInfo };
fn fillInfo(page: *[4096]u8, ctx: InfoFill) void {
    @memset(page, 0);
    @memcpy(page[0..@sizeOf(D.DomainInfo)], std.mem.asBytes(ctx.info));
}

const CopyFill = struct { data: []const u8, offset: usize };
fn fillCopy(page: *[4096]u8, ctx: CopyFill) void {
    @memcpy(page[ctx.offset..][0..ctx.data.len], ctx.data);
}

fn mint(cnode: g.CPtr, index: u32, src: g.CPtr, rights: abi.Rights, badge: usize) !void {
    try mintProtocol(cnode, index, src, rights, badge, 0);
}

/// Mint with the protocol id the kernel checks on endpoints.
fn mintProtocol(cnode: g.CPtr, index: u32, src: g.CPtr, rights: abi.Rights, badge: usize, protocol: u16) !void {
    try ok(g.invoke(cnode, abi.CNodeMethod.mint, .{ index, src, rights.bits(), badge, protocol }));
}

/// Build (or rebuild) domain `i` in its region and start it.
fn build(comptime i: usize) !void {
    const md = manifest.domains[i];
    const st = &domains[i];
    const entry = img.find(md.program) orelse return error.ProgramMissing;
    const program = img.data(entry);
    const exe = try elf.Image.parse(program, elf.machine_riscv);

    // Size the region: the domain's own memory plus room for its kernel
    // objects (program pages, stack, tables, CNode, thread, ...).
    var program_pages: u64 = 0;
    var segs = exe.segments();
    while (try segs.next()) |seg| program_pages += (std.mem.alignForward(u64, seg.vaddr + seg.mem_size, 4096) - std.mem.alignBackward(u64, seg.vaddr, 4096)) / 4096;
    const memory_bytes: u64 = @as(u64, md.memory_kib) * 1024;
    const overhead = (program_pages + D.Layout.stack_pages + 2 + md.devices.len) * 4096 + 128 * 1024;
    const region_bits = log2Ceil(memory_bytes + 2 * overhead);
    if (st.region == 0) {
        st.region = try retypeFrom(pool, .untyped, region_bits);
    }
    const region = st.region;

    var owned: Owned = .{};
    defer owned.releaseAll();
    const R = struct {
        fn make(r: g.CPtr, o: *Owned, kind: abi.Kind, bits: usize) !g.CPtr {
            const s = try retypeFrom(r, kind, bits);
            o.add(s);
            return s;
        }
    };
    const cnode = try R.make(region, &owned, .cnode, D.cnode_bits);
    const vspace = try R.make(region, &owned, .page_table, 2);
    const thread = try R.make(region, &owned, .thread, 0);
    const sc = try R.make(region, &owned, .sched_context, 0);
    const info_frame = try R.make(region, &owned, .frame, 12);
    const ipc_frame = try R.make(region, &owned, .frame, 12);
    const memory = try R.make(region, &owned, .untyped, log2Ceil(memory_bytes));

    // Program: copy each page through the scratch window, then map it.
    segs = exe.segments();
    while (try segs.next()) |seg| {
        const start = std.mem.alignBackward(u64, seg.vaddr, 4096);
        const end = std.mem.alignForward(u64, seg.vaddr + seg.mem_size, 4096);
        var va = start;
        while (va < end) : (va += 4096) {
            const f = try R.make(region, &owned, .frame, 12);
            const lo = @max(va, seg.vaddr);
            const hi = @min(va + 4096, seg.vaddr + seg.data.len);
            if (hi > lo) try withScratch(f, CopyFill{ .data = seg.data[@intCast(lo - seg.vaddr)..][0..@intCast(hi - lo)], .offset = @intCast(lo - va) }, fillCopy);
            try mapInto(region, vspace, f, @intCast(va), .{ .read = seg.read, .write = seg.write, .execute = seg.execute }, &owned);
        }
    }
    const rw: abi.Rights = .{ .read = true, .write = true };
    for (0..D.Layout.stack_pages) |p| {
        const f = try R.make(region, &owned, .frame, 12);
        try mapInto(region, vspace, f, D.Layout.stack_top - (p + 1) * 4096, rw, &owned);
    }
    try mapInto(region, vspace, ipc_frame, D.Layout.ipc_buffer, rw, &owned);

    // The DomainInfo page and the capability space.
    var info: D.DomainInfo = std.mem.zeroes(D.DomainInfo);
    info.magic = D.info_magic;
    D.setName(&info.name, md.name);
    D.setName(&info.program, md.program);
    D.setName(&info.system, manifest.name);
    info.index = i;
    info.restart_count = st.restarts;
    info.timebase_hz = boot.timebase_hz;
    info.memory_bytes = memory_bytes;
    info.program_hash = entry.hash;
    info.closure = img.header.closure;
    const hart: u32 = if (md.hart < boot.hart_count) md.hart else 0;
    info.hart = hart;

    const all = abi.Rights.all;
    try mint(cnode, D.Slot.cnode, cnode, all, 0);
    try mint(cnode, D.Slot.vspace, vspace, all, 0);
    try mint(cnode, D.Slot.thread, thread, all, 0);
    try mint(cnode, D.Slot.memory, memory, all, 0);
    try mint(cnode, D.Slot.steward, lifecycle, .{ .send = true }, i + 1);
    if (md.debug_console) try mint(cnode, D.Slot.debug_console, S.debug_console, .{ .write = true }, 0);
    try mint(cnode, D.Slot.ipc_buffer_frame, ipc_frame, rw, 0);

    inline for (md.uses, 0..) |u, ui| {
        const t = comptime schema.resolveUse(manifest, u.from).?;
        const ep = domains[t.domain].endpoints[t.service];
        try mintProtocol(cnode, D.Slot.first_use + ui, ep, .{ .send = true, .grant = true }, i + 1, comptime proto.kernelIdOf(u.protocol));
        info.uses[ui] = .{ .name = undefined, .protocol = undefined, .slot = D.Slot.first_use + ui };
        D.setName(&info.uses[ui].name, u.name);
        D.setName(&info.uses[ui].protocol, u.protocol);
    }
    info.use_count = md.uses.len;
    inline for (md.provides, 0..) |p, pi| {
        try mintProtocol(cnode, D.Slot.first_provide + pi, st.endpoints[pi], .{ .send = true, .recv = true, .grant = true }, 0, comptime proto.kernelIdOf(p.protocol));
        info.provides[pi] = .{ .name = undefined, .protocol = undefined, .slot = D.Slot.first_provide + pi };
        D.setName(&info.provides[pi].name, p.name);
        D.setName(&info.provides[pi].protocol, p.protocol);
    }
    info.provide_count = md.provides.len;
    inline for (md.devices, 0..) |want, di| {
        const dev = claimDevice(want.virtio, i) orelse {
            g.record("device_missing", .{ .domain = md.name, .device = want.name, .virtio_id = want.virtio });
            return error.DeviceMissing;
        };
        if (dev.irq == 0) {
            dev.irq = slot();
            try ok(g.invoke(S.irq_control, abi.IrqControlMethod.get, .{ dev.irq_line, dev.irq }));
        }
        const frame_slot = D.Slot.first_device + 2 * di;
        const mmio_va = D.Layout.devices + di * 4096;
        try mint(cnode, frame_slot, dev.frame, rw, 0);
        try mint(cnode, frame_slot + 1, dev.irq, .{ .configure = true }, 0);
        try mapInto(region, vspace, dev.frame, mmio_va, rw, &owned);
        info.devices[di] = .{ .name = undefined, .virtio_id = want.virtio, .irq_line = dev.irq_line, .frame_slot = frame_slot, .irq_slot = frame_slot + 1, .mmio = mmio_va, .phys = dev.phys };
        D.setName(&info.devices[di].name, want.name);
    }
    info.device_count = md.devices.len;
    try withScratch(info_frame, InfoFill{ .info = &info }, fillInfo);
    try mapInto(region, vspace, info_frame, D.Layout.info, .{ .read = true }, &owned);

    // The thread, on its own time.
    const fault_ep = slot();
    defer release(fault_ep);
    try mint(S.cnode, fault_ep, lifecycle, .{ .send = true }, fault_flag | i);
    try ok(g.invoke(thread, abi.ThreadMethod.configure, .{ cnode, vspace, fault_ep }));
    try ok(g.invoke(thread, abi.ThreadMethod.set_priority, .{md.priority}));
    try ok(g.invoke(thread, abi.ThreadMethod.write_registers, .{ D.Layout.program_base + (exe.entry - D.Layout.program_base), D.Layout.stack_top, D.Layout.info, 0 }));
    try ok(g.invoke(thread, abi.ThreadMethod.set_ipc_buffer, .{ ipc_frame, D.Layout.ipc_buffer }));
    try ok(g.invoke(S.sched_control, abi.SchedControlMethod.configure, .{ sc, ticks(md.budget_us), ticks(md.period_us), hart }));
    try ok(g.invoke(thread, abi.ThreadMethod.bind_sched, .{sc}));
    st.thread_id = g.invoke(S.cnode, abi.CNodeMethod.identify, .{thread}).w[4];
    st.status = .running;
    g.record("domain_start", .{
        .domain = md.name,
        .program = md.program,
        .program_hash = @as([]const u8, image.hexHash(entry.hash)[0..16]),
        .thread = st.thread_id,
        .kind = @tagName(md.kind),
        .priority = md.priority,
        .hart = hart,
        .budget_us = md.budget_us,
        .period_us = md.period_us,
        .region_kib = (@as(u64, 1) << region_bits) / 1024,
        .restart = st.restarts,
    });
    try ok(g.invoke(thread, abi.ThreadMethod.resume_thread, .{}));
}

fn buildByIndex(i: usize) !void {
    inline for (0..ndomains) |ci| if (ci == i) return build(ci);
}

/// A provider is gone for good: revoke its endpoints, so clients waiting in
/// them are woken with `aborted` and later calls fail with `invalid_cap`,
/// instead of blocking forever.
fn servicesDown(i: usize) void {
    inline for (manifest.domains, 0..) |md, ci| if (ci == i) {
        inline for (md.provides, 0..) |p, pi| {
            _ = g.invoke(S.cnode, abi.CNodeMethod.revoke, .{domains[ci].endpoints[pi]});
            g.record("service_revoked", .{ .domain = md.name, .service = p.name });
        }
    };
}

/// Tear the domain down: everything it was made of goes back to its region.
fn teardown(i: usize) void {
    _ = g.invoke(domains[i].region, abi.UntypedMethod.reset, .{});
}

// ---------------------------------------------------------------------------

fn onFault(i: usize, m: g.Result) void {
    const md = manifest.domains[i];
    const st = &domains[i];
    const kind: abi.FaultKind = std.enums.fromInt(abi.FaultKind, m.tag.label) orelse .unknown;
    g.record("domain_fault", .{ .domain = md.name, .kind = @tagName(kind), .addr = g.klog.hex(m.w[0]), .pc = g.klog.hex(m.w[1]), .restarts = st.restarts });
    teardown(i);
    if (md.restart == .on_fault and st.restarts < md.max_restarts) {
        st.restarts += 1;
        buildByIndex(i) catch |e| {
            st.status = .failed;
            g.record("domain_restart_failed", .{ .domain = md.name, .err = @errorName(e) });
            teardown(i);
            servicesDown(i);
        };
        return;
    }
    st.status = .failed;
    g.record("domain_stopped", .{ .domain = md.name, .reason = if (md.restart == .on_fault) "restart_limit" else "fault" });
    servicesDown(i);
}

fn onExit(i: usize, code: u16) void {
    const md = manifest.domains[i];
    teardown(i);
    domains[i].status = .exited;
    domains[i].exit_code = code;
    g.record("domain_exit", .{ .domain = md.name, .code = code });
}

fn tasksDone() bool {
    inline for (manifest.domains, 0..) |md, i| {
        if (md.kind == .task and (domains[i].status == .running or domains[i].status == .not_started)) return false;
    }
    return true;
}

fn summary() noreturn {
    var tasks: u32 = 0;
    var failed: u32 = 0;
    inline for (manifest.domains, 0..) |md, i| {
        const st = domains[i];
        if (md.kind == .task) {
            tasks += 1;
            if (st.status != .exited or st.exit_code != 0) failed += 1;
        }
        g.record("domain_status", .{ .domain = md.name, .status = @tagName(st.status), .code = st.exit_code, .restarts = st.restarts });
    }
    g.record("summary", .{ .tests = tasks, .failed = failed });
    g.exit(@intCast(@min(failed, 0xfe)));
}

export fn _start() linksection(".text._start") callconv(.naked) noreturn {
    asm volatile (
        \\ call stewardMain
        \\ unimp
    );
}

pub const panic = std.debug.FullPanic(panicFn);
fn panicFn(msg: []const u8, ret: ?usize) noreturn {
    @branchHint(.cold);
    g.record("steward_panic", .{ .msg = msg, .pc = g.klog.hex(ret orelse @returnAddress()) });
    g.exit(0xff);
}

export fn stewardMain(bi: *const abi.BootInfo) callconv(.c) noreturn {
    boot = bi;
    next_slot = bi.first_free_slot;
    var best: usize = 0;
    for (bi.untyped[0..bi.untyped_count], 0..) |u, j| {
        if (u.is_device == 0 and u.size > bi.untyped[best].size) best = j;
    }
    pool = S.first_untyped + @as(g.CPtr, @intCast(best));

    img = image.Image.parse(image_bytes) catch |e| {
        g.record("image_invalid", .{ .err = @errorName(e) });
        g.exit(2);
    };
    img.verify() catch |e| {
        g.record("image_invalid", .{ .err = @errorName(e) });
        g.exit(2);
    };
    g.record("steward_start", .{
        .system = manifest.name,
        .domains = ndomains,
        .programs = img.entries.len,
        .harts = bi.hart_count,
        .closure = @as([]const u8, &image.hexHash(img.header.closure)),
        .verified = true,
    });

    lifecycle = retypeFrom(pool, .endpoint, 0) catch @panic("no lifecycle endpoint");
    probeDevices() catch |e| g.record("device_probe_failed", .{ .err = @errorName(e) });
    inline for (manifest.domains, 0..) |md, i| {
        inline for (md.provides, 0..) |_, pi| domains[i].endpoints[pi] = retypeFrom(pool, .endpoint, 0) catch @panic("no endpoint");
    }
    inline for (0..ndomains) |i| {
        build(i) catch |e| {
            domains[i].status = .failed;
            g.record("domain_build_failed", .{ .domain = manifest.domains[i].name, .err = @errorName(e) });
            teardown(i);
            servicesDown(i);
        };
    }

    // Lifecycle loop: exits and faults.
    while (true) {
        if (manifest.halt_when_tasks_finish and tasksDone()) summary();
        const m = g.recv(lifecycle);
        if (m.status != .ok) continue;
        if (m.badge & fault_flag != 0) {
            const i = m.badge & ~fault_flag;
            if (i < ndomains) onFault(i, m);
        } else if (m.badge >= 1 and m.badge <= ndomains) {
            const i = m.badge - 1;
            if (m.tag.label == @backingInt(D.Lifecycle.exit)) onExit(i, @truncate(m.w[0]));
        }
    }
}
