//! libgrain: the user-side view of Caravan. System-call stubs, typed object
//! methods and structured output. No allocation, no hidden state.
const std = @import("std");
pub const abi = @import("abi");
pub const klog = @import("klog");

pub const CPtr = abi.CPtr;
pub const Status = abi.Status;
pub const Tag = abi.Tag;
pub const S = abi.RootSlot;

pub const Result = struct {
    status: Status,
    tag: Tag,
    w: [5]usize,
    badge: usize,

    pub fn ok(r: Result) bool {
        return r.status == .ok;
    }
};

/// The raw system call: a7 = call, a0 = capability, a1 = tag/method, a2..a6 = words.
pub inline fn syscall(number: abi.Syscall, a0: usize, a1: usize, w: [5]usize) Result {
    var r0: usize = undefined;
    var r1: usize = undefined;
    var r2: usize = undefined;
    var r3: usize = undefined;
    var r4: usize = undefined;
    var r5: usize = undefined;
    var r6: usize = undefined;
    var r7: usize = undefined;
    asm volatile ("ecall"
        : [r0] "={a0}" (r0),
          [r1] "={a1}" (r1),
          [r2] "={a2}" (r2),
          [r3] "={a3}" (r3),
          [r4] "={a4}" (r4),
          [r5] "={a5}" (r5),
          [r6] "={a6}" (r6),
          [r7] "={a7}" (r7),
        : [a0] "{a0}" (a0),
          [a1] "{a1}" (a1),
          [a2] "{a2}" (w[0]),
          [a3] "{a3}" (w[1]),
          [a4] "{a4}" (w[2]),
          [a5] "{a5}" (w[3]),
          [a6] "{a6}" (w[4]),
          [a7] "{a7}" (@backingInt(number)),
        : .{ .memory = true });
    return .{ .status = @fromBackingInt(@intCast(r0)), .tag = @bitCast(r1), .w = .{ r2, r3, r4, r5, r6 }, .badge = r7 };
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

// ---------------------------------------------------------------------------
// Counters (user-readable on Caravan: scounteren enables them).

pub inline fn time() u64 {
    return asm volatile ("rdtime %[r]"
        : [r] "=r" (-> u64),
    );
}
pub inline fn cycles() u64 {
    return asm volatile ("rdcycle %[r]"
        : [r] "=r" (-> u64),
    );
}
pub inline fn instret() u64 {
    return asm volatile ("rdinstret %[r]"
        : [r] "=r" (-> u64),
    );
}

// ---------------------------------------------------------------------------
// Debug console and structured records

pub var console: CPtr = S.debug_console;

pub fn write(bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = @min(rest.len, 32);
        var chunk: [32]u8 = @splat(0);
        @memcpy(chunk[0..n], rest[0..n]);
        var w: [5]usize = undefined;
        w[0] = n;
        for (0..4) |i| w[i + 1] = std.mem.readInt(u64, chunk[i * 8 ..][0..8], .little);
        _ = syscall(.invoke, console, @backingInt(abi.DebugMethod.write), w);
        rest = rest[n..];
    }
}

var record_buf: [256]u8 = undefined;

/// Print `@grain <event> k=v ...` — the same record format the kernel uses.
pub fn record(comptime event: []const u8, fields: anytype) void {
    const line = klog.formatPrefixed("@grain", &record_buf, event, fields) catch {
        write("@grain record_truncated event=" ++ event ++ "\n");
        return;
    };
    write(line);
    write("\n");
}

pub fn exit(code: u16) noreturn {
    _ = invoke(console, abi.DebugMethod.exit, .{code});
    while (true) yield();
}
