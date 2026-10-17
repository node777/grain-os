//! caravan-profile: the IPC round trip on the simulated kernel core, in a
//! loop, for a profiler (the core is the same code the kernel runs):
//!
//!   valgrind --tool=callgrind zig-out/bin/caravan-profile
//!   callgrind_annotate callgrind.out.<pid>
//!
//! A passive server waits on an endpoint; the root task calls it and it
//! answers with reply_recv, on the root's scheduling context.
const std = @import("std");
const abi = @import("abi");
const machine = @import("machine.zig");
const Machine = machine.Machine;
const S = abi.RootSlot;

pub fn main() !void {
    var m = try Machine.boot(1, 16 << 20);
    defer m.deinit();
    _ = try m.invoke(0, S.first_untyped, abi.UntypedMethod.retype, &.{ @backingInt(abi.Kind.endpoint), 0, 100 });
    _ = try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ 101, 100, (abi.Rights{ .send = true }).bits(), 42 });
    _ = try m.invoke(0, S.first_untyped, abi.UntypedMethod.retype, &.{ @backingInt(abi.Kind.thread), 0, 110 });
    _ = try m.invoke(0, 110, abi.ThreadMethod.configure, &.{ S.cnode, S.vspace, 0 });
    _ = try m.invoke(0, 110, abi.ThreadMethod.set_priority, &.{200});
    _ = try m.invoke(0, S.first_untyped, abi.UntypedMethod.retype, &.{ @backingInt(abi.Kind.sched_context), 0, 111 });
    _ = try m.invoke(0, S.sched_control, abi.SchedControlMethod.configure, &.{ 111, 50_000, 50_000, 0 });
    _ = try m.invoke(0, 110, abi.ThreadMethod.bind_sched, &.{111});
    _ = try m.invoke(0, 110, abi.ThreadMethod.resume_thread, &.{});
    _ = try m.invoke(0, S.thread, abi.ThreadMethod.set_priority, &.{100});
    _ = try m.sys(0, .recv, 100, 0, &.{}); // the server, now running, waits
    _ = try m.invoke(0, 110, abi.ThreadMethod.bind_sched, &.{0}); // passive

    const n: usize = 200_000;
    const tag: u64 = @bitCast(abi.Tag{ .label = 1, .length = 2 });
    const t0 = m.root;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Without the invariant check Machine.sys runs after each call.
        t0.ctx.set(.a7, @backingInt(abi.Syscall.call));
        t0.ctx.set(.a0, 101);
        t0.ctx.set(.a1, tag);
        m.k.handle(0, m.now, .syscall);
        const server = m.current(0).?;
        server.ctx.set(.a7, @backingInt(abi.Syscall.reply_recv));
        server.ctx.set(.a0, 100);
        server.ctx.set(.a1, tag);
        m.k.handle(0, m.now, .syscall);
        if (m.current(0) != t0) return error.RoundTripFailed;
    }
    try m.check();
    std.debug.print("@profile round_trips={d}\n", .{n});
}
