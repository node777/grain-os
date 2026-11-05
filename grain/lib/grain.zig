//! libgrain: the user-side view of Caravan. System-call stubs, typed object
//! methods and structured output. No allocation, no hidden state.
const std = @import("std");
pub const abi = @import("abi");
pub const klog = @import("klog");
pub const domain = @import("domain.zig");
pub const virtio = @import("virtio.zig");
pub const virtio_blk = @import("virtio_blk.zig");
pub const tablecloth = @import("tablecloth.zig");
pub const kumara = @import("kumara.zig");
pub const generation = @import("generation.zig");
pub const paint = @import("paint.zig");
pub const ui = @import("ui.zig");
pub const virtio_gpu = @import("virtio_gpu.zig");
pub const virtio_input = @import("virtio_input.zig");
pub const virtio_net = @import("virtio_net.zig");
pub const net = @import("net.zig");
pub const noise = @import("noise.zig");
pub const pci = @import("pci.zig");
pub const nvme = @import("nvme.zig");
pub const e1000 = @import("e1000.zig");
pub const bochs = @import("bochs.zig");
pub const xhci = @import("xhci.zig");
pub const cpu = @import("cpu.zig");
pub const measure = @import("measure.zig");

/// Options for a program's root (`pub const std_options = grain.std_options;`):
/// Caravan's pages are 4 KiB, which std cannot know for a freestanding target.
pub const std_options: std.Options = .{ .page_size_min = 4096, .page_size_max = 4096 };
pub const idl = @import("idl.zig");

pub const CPtr = abi.CPtr;
pub const Status = abi.Status;
pub const Tag = abi.Tag;
pub const S = abi.RootSlot;

pub const Result = struct {
    status: Status,
    tag: Tag,
    w: [5]usize,
    badge: usize,
    /// On receive: the protocol id stamped on the sender's capability (0 if none).
    protocol: u16 = 0,
    /// On receive: no message came; the thread's bound signal fired, with
    /// its bits in `w[0]` (see `bindSignal`).
    signalled: bool = false,

    pub fn ok(r: Result) bool {
        return r.status == .ok;
    }
};

/// The raw system call: a7 = call, a0 = capability, a1 = tag/method, a2..a6 = words.
pub inline fn syscall(number: abi.Syscall, a0: usize, a1: usize, w: [5]usize) Result {
    const r = cpu.syscall(.{ a0, a1, w[0], w[1], w[2], w[3], w[4], @backingInt(number) });
    const r0 = r[0];
    const r1 = r[1];
    const r2 = r[2];
    const r3 = r[3];
    const r4 = r[4];
    const r5 = r[5];
    const r6 = r[6];
    const r7 = r[7];
    return .{ .status = @fromBackingInt(@intCast(r0)), .tag = @bitCast(r1), .w = .{ r2, r3, r4, r5, r6 }, .badge = r7 & 0xffff_ffff, .protocol = @truncate(r7 >> 32), .signalled = r7 & abi.recv_signalled != 0 };
}

fn words(args: anytype) [5]usize {
    var w: [5]usize = @splat(0);
    inline for (args, 0..) |a, i| w[i] = switch (@typeInfo(@TypeOf(a))) {
        .@"enum" => @backingInt(a),
        .bool => @intFromBool(a),
        else => @intCast(a),
    };
    return w;
}

/// Call a method on a kernel object: `invoke(slot, abi.UntypedMethod.retype, .{ kind, bits, dest })`.
pub fn invoke(cap: CPtr, method: anytype, args: anytype) Result {
    return syscall(.invoke, cap, @backingInt(method), words(args));
}

pub fn call(cap: CPtr, tag: Tag, args: anytype) Result {
    return syscall(.call, cap, @bitCast(tag), words(args));
}
pub fn send(cap: CPtr, tag: Tag, args: anytype) Result {
    return syscall(.send, cap, @bitCast(tag), words(args));
}
pub fn recv(cap: CPtr) Result {
    return syscall(.recv, cap, 0, @splat(0));
}
pub fn replyRecv(cap: CPtr, tag: Tag, args: anytype) Result {
    return syscall(.reply_recv, cap, @bitCast(tag), words(args));
}
/// Reply to the last caller (or resume a faulted thread) without waiting.
pub fn reply(tag: Tag, args: anytype) Status {
    return syscall(.reply, 0, @bitCast(tag), words(args)).status;
}
pub fn signal(cap: CPtr) Status {
    return syscall(.signal, cap, 0, @splat(0)).status;
}
/// Block until the signal is non-zero; returns the bits.
pub fn wait(cap: CPtr) Result {
    return syscall(.wait, cap, 0, @splat(0));
}
pub fn poll(cap: CPtr) Result {
    return syscall(.poll, cap, 0, @splat(0));
}
pub fn yield() void {
    _ = syscall(.yield, 0, 0, @splat(0));
}

/// Fire `sig` (through this capability: its badge, or 1) after `ticks`
/// timer ticks; 0 cancels. One alarm per signal; arming again replaces it.
pub fn alarm(sig: CPtr, ticks: u64) Status {
    return invoke(sig, abi.SignalMethod.alarm, .{ticks}).status;
}

/// Let `sig` end this thread's receives too: one thread then serves its
/// clients and its interrupts (a receive returns `signalled`).
pub fn bindSignal(sig: CPtr) Status {
    return invoke(S.thread, abi.ThreadMethod.bind_signal, .{sig}).status;
}

// ---------------------------------------------------------------------------
// Counters (user-readable on Caravan: scounteren enables them).

pub const time = cpu.time;
pub const cycles = cpu.cycles;
pub const instret = cpu.instret;

// ---------------------------------------------------------------------------
// Debug console and structured records

pub var console: CPtr = S.debug_console;

/// Write to the debug console. Up to `abi.max_debug_write` bytes go out in
/// one uninterrupted write, so a whole record line never interleaves with
/// another hart's. Longer writes pass through the IPC buffer, which every
/// thread started by the kernel or Steward has at `ipc_buffer`.
pub fn write(bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = @min(rest.len, abi.max_debug_write);
        var w: [5]usize = @splat(0);
        w[0] = n;
        if (n <= 32) {
            var chunk: [32]u8 = @splat(0);
            @memcpy(chunk[0..n], rest[0..n]);
            for (0..4) |i| w[i + 1] = std.mem.readInt(u64, chunk[i * 8 ..][0..8], .little);
        } else {
            const ib: *[abi.max_debug_write]u8 = @ptrFromInt(ipc_buffer);
            @memcpy(ib[0..n], rest[0..n]);
        }
        if (syscall(.invoke, console, @backingInt(abi.DebugMethod.write), w).status != .ok and n > 32) {
            // No IPC buffer bound: fall back to 32-byte writes.
            var small = rest[0..n];
            while (small.len > 0) {
                const m = @min(small.len, 32);
                write(small[0..m]);
                small = small[m..];
            }
        }
        rest = rest[n..];
    }
}

/// Where the IPC buffer is mapped, in the root task and in every domain.
pub const ipc_buffer: usize = abi.RootLayout.ipc_buffer;

var record_buf: [256]u8 = undefined;

/// Print `@grain <event> k=v ...` — the same record format the kernel uses.
pub fn record(comptime event: []const u8, fields: anytype) void {
    const line = klog.formatPrefixed("@grain", record_buf[0 .. record_buf.len - 1], event, fields) catch {
        write("@grain record_truncated event=" ++ event ++ "\n");
        return;
    };
    record_buf[line.len] = '\n';
    write(record_buf[0 .. line.len + 1]);
}

pub fn exit(code: u16) noreturn {
    _ = invoke(console, abi.DebugMethod.exit, .{code});
    while (true) yield();
}

// ---------------------------------------------------------------------------
// Domains (programs Steward starts from the manifest)

/// This domain's description, written by Steward.
pub fn env() *const domain.DomainInfo {
    return @ptrFromInt(domain.Layout.info);
}

fn findService(list: []const domain.Service, name: []const u8) ?CPtr {
    for (list) |*sv| if (std.mem.eql(u8, domain.nameOf(&sv.name), name)) return sv.slot;
    return null;
}

/// The endpoint for a service this domain uses, by its manifest name.
pub fn use(name: []const u8) ?CPtr {
    const e = env();
    return findService(e.uses[0..e.use_count], name);
}

/// The endpoint this domain serves a service on, by its manifest name.
pub fn provided(name: []const u8) ?CPtr {
    const e = env();
    return findService(e.provides[0..e.provide_count], name);
}

/// A device the manifest gave this domain, by name; null if it has none by
/// that name or the machine lacks it (an `extra` device).
pub fn device(name: []const u8) ?*const domain.Device {
    const e = env();
    for (e.devices[0..e.device_count]) |*d| if (std.mem.eql(u8, domain.nameOf(&d.name), name)) return if (d.bus == .absent) null else d;
    return null;
}

/// Finish this task with an exit code. Steward tears the domain down.
pub fn exitTask(code: u16) noreturn {
    _ = syscall(.call, domain.Slot.steward, @bitCast(Tag{ .label = @backingInt(domain.Lifecycle.exit), .length = 1 }), .{ code, 0, 0, 0, 0 });
    while (true) yield();
}

/// `@grain <event> domain=<name> k=v ...`
pub fn log(comptime event: []const u8, fields: anytype) void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const ok = blk: {
        w.writeAll("@grain " ++ event ++ " domain=") catch break :blk false;
        w.writeAll(domain.nameOf(&env().name)) catch break :blk false;
        var fbuf: [200]u8 = undefined;
        const rest = klog.formatFields(&fbuf, fields) catch break :blk false;
        w.writeAll(rest) catch break :blk false;
        w.writeAll("\n") catch break :blk false;
        break :blk true;
    };
    if (ok) write(w.buffered()) else write("@grain record_truncated event=" ++ event ++ "\n");
}

/// The standard entry point for domain programs: `comptime { grain.exportStart(); }`
/// in a program whose root file has `pub fn main() !u16`. The return value is the
/// task's exit code; an error is reported and exits with code 1.
pub fn exportStart() void {
    // The section goes on the function itself: an export's `.section` can
    // leak to other symbols of the module (a mutable global once landed in
    // read-only text).
    @export(&startStub, .{ .name = "_start" });
    @export(&startMain, .{ .name = "grainStartMain" });
}

fn startStub() linksection(".text._start") callconv(.naked) noreturn {
    asm volatile (cpu.callStub("grainStartMain"));
}

fn startMain() callconv(.c) noreturn {
    const root = @import("root");
    console = domain.Slot.debug_console;
    const code = root.main() catch |e| {
        log("error", .{ .err = @errorName(e) });
        exitTask(1);
    };
    exitTask(code);
}

/// Panic handler for domain programs: report, then fault, so Steward's
/// restart policy applies. Use as `pub const panic = grain.panic;`.
pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, ret: ?usize) noreturn {
    @branchHint(.cold);
    log("panic", .{ .msg = msg, .pc = klog.hex(ret orelse @returnAddress()) });
    while (true) cpu.trap();
}

// ---------------------------------------------------------------------------
// Servers

pub const Message = struct {
    label: u32,
    badge: usize,
    w: [5]usize,
    length: u7,
};

pub const Reply = struct {
    label: u32 = 0,
    w: [5]usize = @splat(0),
    length: u7 = 0,
};

/// Receive requests on `ep` forever, answering each with `handler`.
pub fn serve(ep: CPtr, ctx: anytype, comptime handler: fn (@TypeOf(ctx), Message) Reply) noreturn {
    var r = recv(ep);
    while (true) {
        const answer = handler(ctx, .{ .label = r.tag.label, .badge = r.badge, .w = r.w, .length = r.tag.length });
        r = syscall(.reply_recv, ep, @bitCast(Tag{ .label = answer.label, .length = answer.length }), answer.w);
    }
}

// ---------------------------------------------------------------------------
// Memory: make objects from an untyped region and map frames, creating
// page tables on demand.

pub const Space = struct {
    untyped: CPtr,
    vspace: CPtr,
    next_slot: CPtr,
    /// Slots below this were handed out; retype goes from here.
    limit: CPtr = std.math.maxInt(CPtr),

    pub fn slot(s: *Space) !CPtr {
        if (s.next_slot >= s.limit) return error.OutOfSlots;
        const n = s.next_slot;
        s.next_slot += 1;
        return n;
    }

    pub fn retype(s: *Space, kind: abi.Kind, bits: usize) !CPtr {
        const dest = try s.slot();
        const r = invoke(s.untyped, abi.UntypedMethod.retype, .{ kind, bits, dest });
        if (!r.ok()) return statusError(r.status);
        return dest;
    }

    /// Map `frame` at `va` in `vspace` (default: this space's), creating
    /// page tables from this space's untyped as needed.
    pub fn mapIn(s: *Space, vspace: CPtr, frame: CPtr, va: usize, rights: abi.Rights) !void {
        var tries: usize = 0;
        while (tries < 3) : (tries += 1) {
            const r = invoke(vspace, abi.VSpaceMethod.map_frame, .{ frame, va, rights.bits() });
            switch (r.status) {
                .ok => return,
                .no_page_table => {
                    const l1 = try s.retype(.page_table, 1);
                    if (!invoke(vspace, abi.VSpaceMethod.map_table, .{ l1, va }).ok()) {
                        _ = invoke(S.cnode, abi.CNodeMethod.delete, .{l1});
                        const l0 = try s.retype(.page_table, 0);
                        const m = invoke(vspace, abi.VSpaceMethod.map_table, .{ l0, va });
                        if (!m.ok()) return statusError(m.status);
                    }
                },
                else => return statusError(r.status),
            }
        }
        return error.MapFailed;
    }

    pub fn map(s: *Space, frame: CPtr, va: usize, rights: abi.Rights) !void {
        return s.mapIn(s.vspace, frame, va, rights);
    }

    /// Fresh zeroed pages mapped at `va`, through one reused slot: a
    /// mapping keeps its frame alive without a capability (objects live
    /// until their untyped is reset), so a heap of any size costs one slot.
    pub fn mapHeap(s: *Space, va: usize, pages: usize) ![]u8 {
        const scratch = try s.slot();
        for (0..pages) |i| {
            const r = invoke(s.untyped, abi.UntypedMethod.retype, .{ abi.Kind.frame, 12, scratch });
            if (!r.ok()) return statusError(r.status);
            try s.map(scratch, va + i * 4096, .{ .read = true, .write = true });
            _ = invoke(S.cnode, abi.CNodeMethod.delete, .{scratch});
        }
        return @as([*]u8, @ptrFromInt(va))[0 .. pages * 4096];
    }

    /// Fresh zeroed pages mapped at `va`; returns the first frame's slot.
    pub fn mapNew(s: *Space, va: usize, pages: usize, rights: abi.Rights) !CPtr {
        var first: CPtr = 0;
        for (0..pages) |i| {
            const f = try s.retype(.frame, 12);
            if (i == 0) first = f;
            try s.map(f, va + i * 4096, rights);
        }
        return first;
    }
};

pub fn statusError(st: Status) anyerror {
    return switch (st) {
        .invalid_cap => error.InvalidCap,
        .wrong_kind => error.WrongKind,
        .no_rights => error.NoRights,
        .invalid_argument => error.InvalidArgument,
        .no_memory => error.NoMemory,
        .no_objects => error.NoObjects,
        .slot_occupied => error.SlotOccupied,
        .already_mapped => error.AlreadyMapped,
        .no_page_table => error.NoPageTable,
        .not_mapped => error.NotMapped,
        .aborted => error.Aborted,
        else => error.SyscallFailed,
    };
}

/// Physical address of a frame (for DMA).
pub fn physOf(frame: CPtr) !u64 {
    const r = invoke(frame, abi.FrameMethod.info, .{});
    if (!r.ok()) return statusError(r.status);
    return r.w[0];
}

pub const fence = cpu.fence;
