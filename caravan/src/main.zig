//! Caravan — the Grain OS microkernel (riscv64 entry and glue).
//!
//! This file connects the hardware to the portable kernel core: it brings up
//! harts, turns every trap into a `core.Event`, runs `handle` under the
//! kernel lock, then resumes whichever thread the core chose (or idles).
const std = @import("std");
const core = @import("core");
const abi = @import("abi");
const klog = core.klog;
const arch = @import("arch/riscv64/arch.zig");
const boot = @import("arch/riscv64/boot.zig");
const csr = @import("arch/riscv64/csr.zig");
const sbi = @import("arch/riscv64/sbi.zig");
const trap = @import("arch/riscv64/trap.zig");
const plic = @import("arch/riscv64/plic.zig");
const board = @import("arch/riscv64/board.zig");

comptime {
    _ = boot;
}

pub const panic = std.debug.FullPanic(panicHandler);

const Kernel = core.Kernel(arch);
var kernel: Kernel = .{};
var platform: core.fdt.Platform = .{};

const root_elf = @embedFile("root_task.elf");
/// Root task time slice: 10 ms at the platform timebase.
const root_slice_ms = 10;

// ---------------------------------------------------------------------------
// Kernel lock. Kernel entries are short and non-preemptible, so one lock
// serialises them (as seL4 does on SMP). Waiting harts keep servicing
// lock-free requests so a hart holding the lock can rely on them.

var lock_word = std.atomic.Value(u32).init(0);

fn lock(h: *arch.HartLocal) void {
    while (lock_word.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        arch.serviceRequests(h);
        arch.relax();
    }
}

fn unlock() void {
    lock_word.store(0, .release);
}

// ---------------------------------------------------------------------------
// Logging outside the core (boot and panics).

var log_buf: [256]u8 = undefined;

fn log(comptime event: []const u8, fields: anytype) void {
    const line = klog.format(&log_buf, event, fields) catch return;
    arch.debugWrite(line);
    arch.debugWrite("\n");
}

fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    log("panic", .{ .pc = klog.hex(ret_addr orelse @returnAddress()), .msg = msg });
    board.exit(0xff);
}

// ---------------------------------------------------------------------------
// Self-profile: instructions spent in the kernel core per kind of entry,
// printed as records when the system halts.

const ProfileKind = enum { syscall_call, syscall_reply_recv, syscall_invoke, syscall_other, fault, timer, irq, ipi };
var profile_count: [std.meta.fieldNames(ProfileKind).len]u64 = @splat(0);
var profile_instret: [std.meta.fieldNames(ProfileKind).len]u64 = @splat(0);

fn profileKind(ev: core.kernel.Event, ctx: ?*trap.Context) ProfileKind {
    return switch (ev) {
        .syscall => switch (@as(abi.Syscall, @fromBackingInt(@intCast(ctx.?.x[17])))) {
            .call => .syscall_call,
            .reply_recv => .syscall_reply_recv,
            .invoke => .syscall_invoke,
            else => .syscall_other,
        },
        .fault => .fault,
        .timer => .timer,
        .irq => .irq,
        .ipi => .ipi,
    };
}

inline fn instret() u64 {
    return asm volatile ("rdinstret %[r]"
        : [r] "=r" (-> u64),
    );
}

fn handleProfiled(h: *arch.HartLocal, ev: core.kernel.Event, ctx: ?*trap.Context) void {
    const kind = @backingInt(profileKind(ev, ctx));
    const start = instret();
    kernel.handle(h.index, csr.time(), ev);
    profile_instret[kind] += instret() - start;
    profile_count[kind] += 1;
}

fn printProfile() void {
    inline for (comptime std.meta.fieldNames(ProfileKind), 0..) |name, i| {
        if (profile_count[i] != 0) log("profile", .{ .entry = name, .count = profile_count[i], .core_instret_avg = profile_instret[i] / profile_count[i] });
    }
}

// ---------------------------------------------------------------------------
// Running threads

/// Resume the thread the core chose for this hart, or idle. Called with the
/// kernel lock held; releases it.
fn enterNext(h: *arch.HartLocal) noreturn {
    deliverKicks(h);
    if (kernel.exitRequested()) |code| {
        printProfile();
        board.exit(code);
    }
    if (kernel.currentThread(h.index)) |t| {
        const root = kernel.vspaceRoot(t).?;
        if (h.active_root.raw != root) arch.switchRoot(h, root);
        t.ctx.kernel_sp = h.stack_top;
        t.ctx.hart_local = @intFromPtr(h);
        h.in_user.store(true, .release);
        unlock();
        trap.caravanResume(&t.ctx);
    }
    // Idle on the kernel's own table, so no user root stays live here.
    if (h.active_root.raw != arch.bootRootPhys()) arch.switchRoot(h, arch.bootRootPhys());
    unlock();
    idle(h);
}

fn idle(h: *arch.HartLocal) noreturn {
    _ = h;
    // Reset to the top of this hart's stack: whatever was below is finished.
    asm volatile (
        \\mv sp, %[top]
        \\csrsi sstatus, 2
        \\1: wfi
        \\j 1b
        :
        : [top] "r" (arch.self().stack_top),
    );
    unreachable;
}

/// Make other harts notice changes to their state, and wait until any hart
/// that was running user code has trapped into the kernel. After this, no
/// hart still executes a thread the core just took away from it.
fn deliverKicks(h: *arch.HartLocal) void {
    const mask = kernel.takeKicks();
    if (mask == 0) return;
    var snap: [arch.max_harts]u64 = undefined;
    for (arch.harts[0..arch.hart_count], 0..) |*o, i| {
        if (mask & (@as(u32, 1) << @intCast(i)) == 0 or o == h or !o.online) continue;
        snap[i] = o.epoch.load(.acquire);
        sbi.sendIpi(o.hart_id);
    }
    for (arch.harts[0..arch.hart_count], 0..) |*o, i| {
        if (mask & (@as(u32, 1) << @intCast(i)) == 0 or o == h or !o.online) continue;
        while (o.in_user.load(.acquire) and o.epoch.load(.acquire) == snap[i]) arch.relax();
    }
}

fn eventFor(h: *arch.HartLocal, cause: trap.Cause, claimed: *?u32) core.kernel.Event {
    return switch (cause) {
        .syscall => .syscall,
        .fault => |f| .{ .fault = f },
        .interrupt => |i| switch (i) {
            .timer => .timer,
            .software => blk: {
                csr.clear("sip", csr.sip_ssip);
                break :blk .ipi;
            },
            .external => blk: {
                const ctx = h.plic_context orelse break :blk .ipi;
                const line = plic.claim(ctx);
                if (line == 0) break :blk .ipi;
                claimed.* = line;
                break :blk .{ .irq = line };
            },
        },
        .unknown_interrupt => .ipi,
    };
}

export fn caravanUserTrap(ctx: *trap.Context) callconv(.c) noreturn {
    const h = arch.self();
    _ = h.epoch.fetchAdd(1, .acq_rel);
    h.in_user.store(false, .release);
    arch.serviceRequests(h);
    const cause = trap.decode(csr.read("scause"), csr.read("stval"), ctx.pc);
    if (cause == .syscall) ctx.pc += 4;
    var claimed: ?u32 = null;
    const ev = eventFor(h, cause, &claimed);
    lock(h);
    handleProfiled(h, ev, ctx);
    if (claimed) |line| plic.complete(h.plic_context.?, line);
    enterNext(h);
}

/// Traps taken in kernel mode: expected only while idling (interrupts).
export fn caravanKernelTrap(frame: *trap.Frame) callconv(.c) void {
    const h = arch.self();
    const scause = csr.read("scause");
    const cause = trap.decode(scause, csr.read("stval"), frame.sepc);
    if (cause != .interrupt) {
        log("kernel_fault", .{ .scause = scause, .stval = klog.hex(csr.read("stval")), .pc = klog.hex(frame.sepc), .ra = klog.hex(frame.x[1]) });
        @panic("fault in kernel mode");
    }
    csr.clear("sstatus", csr.sstatus_sie);
    arch.serviceRequests(h);
    var claimed: ?u32 = null;
    const ev = eventFor(h, cause, &claimed);
    lock(h);
    handleProfiled(h, ev, null);
    if (claimed) |line| plic.complete(h.plic_context.?, line);
    enterNext(h);
}

// ---------------------------------------------------------------------------
// Boot

extern const __kernel_start: u8;
extern const __kernel_end: u8;
extern const __stacks_start: u8;
extern fn _start_secondary() callconv(.naked) void;

fn setupHart(h: *arch.HartLocal) void {
    asm volatile ("mv tp, %[hl]"
        :
        : [hl] "r" (@intFromPtr(h)),
    );
    csr.write("stvec", @intFromPtr(&trap.caravanTrapEntry));
    csr.write("sscratch", 0);
    // Let user code read cycle, time and instret.
    csr.write("scounteren", 0b111);
    csr.set("sie", csr.sie_stie | csr.sie_ssie | csr.sie_seie);
    if (h.plic_context) |ctx| plic.setThreshold(ctx, 0);
    h.active_root.store(arch.bootRootPhys(), .release);
}

export fn kmain(hart_id: usize, dtb_pa: usize) callconv(.c) noreturn {
    // Hart-local block 0 is the boot hart until the device tree says more.
    const h0 = &arch.harts[0];
    h0.* = .{ .hart_id = @intCast(hart_id), .stack_top = @intFromPtr(&__stacks_start) + boot.stack_size };
    setupHart(h0);

    const fdt = core.fdt.Fdt.fromPtr(@ptrFromInt(arch.physToVirt(dtb_pa))) catch @panic("bad device tree");
    platform = core.fdt.parsePlatform(fdt) catch @panic("unreadable device tree");
    if (platform.test_finisher) |f| board.finisher = arch.physToVirt(f);

    // Number harts in device-tree order, the boot hart's index taken from it.
    arch.hart_count = @intCast(@min(platform.harts_len, arch.max_harts));
    const boot_index = platform.hartIndex(@intCast(hart_id)) orelse 0;
    if (boot_index != 0) @panic("boot hart must be the first hart in the device tree");
    for (platform.hartList()[0..arch.hart_count], 0..) |ph, i| {
        const h = &arch.harts[i];
        h.index = @intCast(i);
        h.hart_id = ph.id;
        h.plic_context = ph.plic_context;
        h.stack_top = @intFromPtr(&__stacks_start) + (i + 1) * boot.stack_size;
    }
    if (platform.plic) |p| plic.init(arch.physToVirt(p.base), platform.plic_ndev);
    setupHart(h0);

    log("boot", .{
        .kernel = "caravan",
        .arch = .riscv64,
        .hart = hart_id,
        .harts = arch.hart_count,
        .timebase_hz = platform.timebase_hz,
        .dtb = klog.hex(dtb_pa),
        .image = klog.hex(@intFromPtr(&__kernel_start) - boot.kernel_offset),
    });
    log("platform", .{
        .plic = klog.hex(if (platform.plic) |p| p.base else 0),
        .plic_lines = platform.plic_ndev,
        .plic_context = if (h0.plic_context) |c| c else 0xffff,
        .uart = klog.hex(if (platform.uart) |u| u.base else 0),
        .uart_irq = platform.uart_irq orelse 0,
        .finisher = klog.hex(platform.test_finisher orelse 0),
    });

    const image_pa = @intFromPtr(&__kernel_start) - boot.kernel_offset;
    const image_end = @intFromPtr(&__kernel_end) - boot.kernel_offset;
    const reserved = [_]core.fdt.Range{
        .{ .base = image_pa, .size = image_end - image_pa },
        .{ .base = dtb_pa, .size = fdt.totalSize() },
    };
    kernel.boot(.{
        .platform = &platform,
        .reserved = &reserved,
        .root_elf = root_elf,
        .now = csr.time(),
        .root_budget_ticks = platform.timebase_hz / 1000 * root_slice_ms,
    }) catch |e| {
        log("boot_failed", .{ .err = @errorName(e) });
        @panic("kernel boot failed");
    };

    // Start the other harts; each joins at kmainSecondary.
    const secondary_pa = @intFromPtr(&_start_secondary) - boot.kernel_offset;
    for (arch.harts[1..arch.hart_count]) |*h| {
        sbi.hartStart(h.hart_id, secondary_pa, h.index) catch {
            log("hart_start_failed", .{ .hart = h.hart_id });
            continue;
        };
    }

    lock(h0);
    h0.online = true;
    kernel.hartOnline(0, csr.time());
    enterNext(h0);
}

export fn kmainSecondary(hart_id: usize, index: usize) callconv(.c) noreturn {
    const h = &arch.harts[index];
    setupHart(h);
    lock(h);
    h.online = true;
    log("hart_online", .{ .hart = hart_id, .index = index });
    kernel.hartOnline(@intCast(index), csr.time());
    enterNext(h);
}
