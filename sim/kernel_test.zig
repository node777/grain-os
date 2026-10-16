//! Scenario tests for the kernel core, driven through system calls on the
//! simulated machine.
const std = @import("std");
const abi = @import("abi");
const core = @import("core");
const machine = @import("machine.zig");
const Machine = machine.Machine;
const S = abi.RootSlot;
const expectEqual = std.testing.expectEqual;

const ram_size = 32 * 1024 * 1024;
const first_untyped = S.first_untyped;

fn bootMachine() !Machine {
    var m = try Machine.boot(1, ram_size);
    try m.check();
    return m;
}

fn retype(m: *Machine, kind: abi.Kind, bits: u64, dest: u64) !void {
    const r = try m.invoke(0, first_untyped, abi.UntypedMethod.retype, &.{ @backingInt(kind), bits, dest });
    try expectEqual(abi.Status.ok, r.status);
}

fn identify(m: *Machine, slot: u64) !machine.Result {
    return m.invoke(0, S.cnode, abi.CNodeMethod.identify, &.{slot});
}

test "boot builds the root task" {
    var m = try bootMachine();
    defer m.deinit();
    try std.testing.expect(m.current(0) == m.root);
    try expectEqual(abi.ThreadState.running, m.root.state);
    try expectEqual(@as(u64, 0x10000), m.root.ctx.get(.pc));
    try expectEqual(@as(u64, abi.RootLayout.boot_info), m.root.ctx.get(.a0));
    const r = try identify(&m, S.cnode);
    try expectEqual(abi.Status.ok, r.status);
    try expectEqual(@as(u64, @backingInt(abi.Kind.cnode)), r.words[0]);
    const u = try identify(&m, first_untyped);
    try expectEqual(@as(u64, @backingInt(abi.Kind.untyped)), u.words[0]);
    const empty = try identify(&m, 100);
    try expectEqual(abi.Status.invalid_cap, empty.status);
}

test "retype, mint with fewer rights, revoke" {
    var m = try bootMachine();
    defer m.deinit();
    try retype(&m, .endpoint, 0, 100);
    try expectEqual(@as(u64, @backingInt(abi.Kind.endpoint)), (try identify(&m, 100)).words[0]);

    // A send-only copy with a badge.
    const send_only: abi.Rights = .{ .send = true };
    var r = try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ 101, 100, send_only.bits(), 7 });
    try expectEqual(abi.Status.ok, r.status);
    const id = try identify(&m, 101);
    try expectEqual(@as(u64, send_only.bits()), id.words[1]);
    try expectEqual(@as(u64, 7), id.words[2]);
    // Rights only shrink.
    r = try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ 102, 101, abi.Rights.all.bits(), 0 });
    try expectEqual(@as(u64, send_only.bits()), (try identify(&m, 102)).words[1]);
    // recv needs a right the copy lacks.
    const t = try m.sys(0, .recv, 101, 0, &.{});
    try expectEqual(abi.Status.no_rights, Machine.result(t).status);
    // Re-badging is refused.
    r = try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ 103, 101, send_only.bits(), 9 });
    try expectEqual(abi.Status.invalid_argument, r.status);

    // Revoke through the original: every copy dies, the original slot lives.
    r = try m.invoke(0, S.cnode, abi.CNodeMethod.revoke, &.{100});
    try expectEqual(abi.Status.ok, r.status);
    try expectEqual(abi.Status.invalid_cap, (try identify(&m, 101)).status);
    try expectEqual(abi.Status.invalid_cap, (try identify(&m, 102)).status);
    try expectEqual(abi.Status.ok, (try identify(&m, 100)).status);
}

/// Create a thread sharing the root's CSpace and VSpace, with its own
/// scheduling context, ready to run. Returns its id.
fn spawn(m: *Machine, tslot: u64, scslot: u64, prio: u64, budget: u64, period: u64) !*machine.Thread {
    try retype(m, .thread, 0, tslot);
    try expectEqual(abi.Status.ok, (try m.invoke(0, tslot, abi.ThreadMethod.configure, &.{ S.cnode, S.vspace, 0 })).status);
    try expectEqual(abi.Status.ok, (try m.invoke(0, tslot, abi.ThreadMethod.set_priority, &.{prio})).status);
    try expectEqual(abi.Status.ok, (try m.invoke(0, tslot, abi.ThreadMethod.write_registers, &.{ 0x20000, 0x30000, 0, 0 })).status);
    if (scslot != 0) {
        try retype(m, .sched_context, 0, scslot);
        try expectEqual(abi.Status.ok, (try m.invoke(0, S.sched_control, abi.SchedControlMethod.configure, &.{ scslot, budget, period, 0 })).status);
        try expectEqual(abi.Status.ok, (try m.invoke(0, tslot, abi.ThreadMethod.bind_sched, &.{scslot})).status);
    }
    const id = (try identify(m, tslot)).words[4];
    return m.k.thread(@intCast(id));
}

test "call and reply with a passive server, donation and badge" {
    var m = try bootMachine();
    defer m.deinit();
    try retype(&m, .endpoint, 0, 100);
    _ = try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ 101, 100, (abi.Rights{ .send = true }).bits(), 42 });

    // The server starts with its own context so it can reach recv.
    const server = try spawn(&m, 110, 111, 200, 50_000, 50_000);
    _ = try m.invoke(0, 110, abi.ThreadMethod.resume_thread, &.{});
    try expectEqual(abi.ThreadState.ready, server.state);
    // Root lowers itself; the server now preempts it.
    _ = try m.invoke(0, S.thread, abi.ThreadMethod.set_priority, &.{100});
    try std.testing.expect(m.current(0) == server);
    _ = try m.sys(0, .recv, 100, 0, &.{});
    try expectEqual(abi.ThreadState.blocked_recv, server.state);
    try std.testing.expect(m.current(0) == m.root);
    // Make it passive: it will run only on its callers' time.
    try expectEqual(abi.Status.ok, (try m.invoke(0, 110, abi.ThreadMethod.bind_sched, &.{0})).status);
    try expectEqual(@as(u32, 0), server.sc);

    // Call: the server receives the words and badge, on the root's context.
    const tag: abi.Tag = .{ .label = 5, .length = 2 };
    _ = try m.sys(0, .call, 101, @bitCast(tag), &.{ 10, 20 });
    try expectEqual(abi.ThreadState.blocked_reply, m.root.state);
    try std.testing.expect(m.current(0) == server);
    try expectEqual(m.root.sc, server.sc);
    const got = Machine.result(server);
    try expectEqual(abi.Status.ok, got.status);
    try expectEqual(@as(u32, 5), got.tag.label);
    try expectEqual(@as(u64, 42), got.badge);
    try expectEqual(@as(u64, 10), got.words[0]);
    try expectEqual(@as(u64, 20), got.words[1]);

    // Reply and wait again: the root resumes with the answer and its context.
    const rtag: abi.Tag = .{ .length = 1 };
    _ = try m.sys(0, .reply_recv, 100, @bitCast(rtag), &.{30});
    try std.testing.expect(m.current(0) == m.root);
    try expectEqual(abi.ThreadState.blocked_recv, server.state);
    try expectEqual(@as(u32, 0), server.sc);
    const back = Machine.result(m.root);
    try expectEqual(abi.Status.ok, back.status);
    try expectEqual(@as(u64, 30), back.words[0]);
    try expectEqual(@as(u32, 1), back.tag.length);
}

test "leases: use limits, expiry, revocation" {
    var m = try bootMachine();
    defer m.deinit();
    try retype(&m, .signal, 0, 100);
    try retype(&m, .lease, 0, 101);
    // Arm: signal rights only, two uses.
    var r = try m.invoke(0, 101, abi.LeaseMethod.arm, &.{ 100, (abi.Rights{ .send = true, .recv = true }).bits(), 0, 2 });
    try expectEqual(abi.Status.ok, r.status);
    // Hand out a copy without revoke right.
    _ = try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ 102, 101, (abi.Rights{ .send = true, .recv = true }).bits(), 0 });
    try expectEqual(@as(u64, @backingInt(abi.Kind.signal)), (try identify(&m, 102)).words[3]);
    try expectEqual(abi.Status.ok, Machine.result(try m.sys(0, .signal, 102, 0, &.{})).status);
    try expectEqual(abi.Status.ok, Machine.result(try m.sys(0, .poll, 102, 0, &.{})).status);
    try expectEqual(abi.Status.lease_exhausted, Machine.result(try m.sys(0, .signal, 102, 0, &.{})).status);
    r = try m.invoke(0, S.cnode, abi.CNodeMethod.lease_info, &.{101});
    try expectEqual(@as(u64, 0), r.words[0]);

    // Expiry.
    try retype(&m, .lease, 0, 103);
    _ = try m.invoke(0, 103, abi.LeaseMethod.arm, &.{ 100, abi.Rights.all.bits(), 500, 0 });
    try expectEqual(abi.Status.ok, Machine.result(try m.sys(0, .signal, 103, 0, &.{})).status);
    try m.advance(0, 1000);
    try expectEqual(abi.Status.lease_expired, Machine.result(try m.sys(0, .signal, 103, 0, &.{})).status);

    // Revocation: the holder's copy dies, the target is untouched.
    try retype(&m, .lease, 0, 104);
    _ = try m.invoke(0, 104, abi.LeaseMethod.arm, &.{ 100, abi.Rights.all.bits(), 0, 0 });
    _ = try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ 105, 104, (abi.Rights{ .send = true }).bits(), 0 });
    try expectEqual(abi.Status.ok, Machine.result(try m.sys(0, .signal, 105, 0, &.{})).status);
    _ = try m.invoke(0, S.cnode, abi.CNodeMethod.revoke, &.{104});
    try expectEqual(abi.Status.invalid_cap, Machine.result(try m.sys(0, .signal, 105, 0, &.{})).status);
    try expectEqual(abi.Status.ok, Machine.result(try m.sys(0, .signal, 100, 0, &.{})).status);
}

test "untyped reset destroys everything made from it" {
    var m = try bootMachine();
    defer m.deinit();
    // A child untyped of 64 KiB, so resetting it leaves the root task alone.
    try retype(&m, .untyped, 16, 100);
    var r = try m.invoke(0, 100, abi.UntypedMethod.info, &.{});
    try expectEqual(@as(u64, 65536), r.words[1]);
    try expectEqual(@as(u64, 16), r.words[3]); // 64 KiB / 4 KiB objects
    // Fill it with frames until it runs out.
    var slot: u64 = 200;
    while (true) : (slot += 1) {
        r = try m.invoke(0, 100, abi.UntypedMethod.retype, &.{ @backingInt(abi.Kind.frame), 12, slot });
        if (r.status != .ok) break;
    }
    try std.testing.expect(r.status == .no_memory or r.status == .no_objects);
    try std.testing.expect(slot - 200 >= 15);
    // Map one, then reset: the mapping disappears and the caps die.
    try retype(&m, .page_table, 1, 101);
    try retype(&m, .page_table, 0, 102);
    try expectEqual(abi.Status.ok, (try m.invoke(0, S.vspace, abi.VSpaceMethod.map_table, &.{ 101, 0x1_0000_0000 })).status);
    try expectEqual(abi.Status.ok, (try m.invoke(0, S.vspace, abi.VSpaceMethod.map_table, &.{ 102, 0x1_0000_0000 })).status);
    const rw: abi.Rights = .{ .read = true, .write = true };
    try expectEqual(abi.Status.ok, (try m.invoke(0, S.vspace, abi.VSpaceMethod.map_frame, &.{ 200, 0x1_0000_0000, rw.bits() })).status);
    try expectEqual(abi.Status.already_mapped, (try m.invoke(0, S.vspace, abi.VSpaceMethod.map_frame, &.{ 201, 0x1_0000_0000, rw.bits() })).status);
    try expectEqual(abi.Status.ok, (try m.invoke(0, 100, abi.UntypedMethod.reset, &.{})).status);
    try expectEqual(abi.Status.invalid_cap, (try identify(&m, 200)).status);
    try expectEqual(abi.Status.not_mapped, (try m.invoke(0, S.vspace, abi.VSpaceMethod.unmap, &.{0x1_0000_0000})).status);
    // The page tables (from the root untyped) still exist; the slot is free again.
    r = try m.invoke(0, 100, abi.UntypedMethod.retype, &.{ @backingInt(abi.Kind.frame), 12, 300 });
    try expectEqual(abi.Status.ok, r.status);
    try expectEqual(abi.Status.ok, (try m.invoke(0, S.vspace, abi.VSpaceMethod.map_frame, &.{ 300, 0x1_0000_0000, rw.bits() })).status);
}

test "faults go to the fault endpoint; reply resumes at a new pc" {
    var m = try bootMachine();
    defer m.deinit();
    try retype(&m, .endpoint, 0, 100);
    const worker = try spawn(&m, 110, 111, 200, 100_000, 100_000);
    _ = try m.invoke(0, 110, abi.ThreadMethod.configure, &.{ S.cnode, S.vspace, 100 });
    // Root waits on the fault endpoint, then the worker runs and faults.
    _ = try m.invoke(0, 110, abi.ThreadMethod.resume_thread, &.{});
    _ = try m.sys(0, .recv, 100, 0, &.{});
    try std.testing.expect(m.current(0) == worker);
    try m.fault(0, .{ .kind = .load_page_fault, .addr = 0xdead000, .pc = 0x20004, .raw = 13 });
    try expectEqual(abi.ThreadState.blocked_reply, worker.state);
    try std.testing.expect(m.current(0) == m.root);
    const f = Machine.result(m.root);
    try expectEqual(@as(u32, @backingInt(abi.FaultKind.load_page_fault)), f.tag.label);
    try expectEqual(@as(u64, 0xdead000), f.words[0]);
    try expectEqual(@as(u64, 0x20004), f.words[1]);
    // Reply "resume at 0x20100".
    const tag: abi.Tag = .{ .label = 1, .length = 1 };
    _ = try m.sys(0, .reply_recv, 100, @bitCast(tag), &.{0x20100});
    try std.testing.expect(m.current(0) == worker);
    try expectEqual(@as(u64, 0x20100), worker.ctx.get(.pc));
    // Without a handler a fault stops the thread.
    _ = try m.invoke(0, 110, abi.ThreadMethod.configure, &.{ S.cnode, S.vspace, 0 });
    try m.fault(0, .{ .kind = .illegal_instruction, .addr = 0, .pc = 0x20100, .raw = 2 });
    try expectEqual(abi.ThreadState.inactive, worker.state);
}

test "budgets: a thread with 20% of a period is throttled and refilled" {
    var m = try bootMachine();
    defer m.deinit();
    const w = try spawn(&m, 110, 111, 200, 2_000, 10_000);
    _ = try m.invoke(0, 110, abi.ThreadMethod.resume_thread, &.{});
    // Root blocks on a signal so only the worker wants the CPU.
    try retype(&m, .signal, 0, 100);
    _ = try m.sys(0, .wait, 100, 0, &.{});
    try std.testing.expect(m.current(0) == w);
    try m.advance(0, 2_000);
    try expectEqual(abi.ThreadState.stalled, w.state);
    try std.testing.expect(m.current(0) == null);
    try m.advance(0, 8_000);
    try std.testing.expect(m.current(0) == w);
}

test "round robin between equal priorities on full-bandwidth contexts" {
    var m = try bootMachine();
    defer m.deinit();
    const a = try spawn(&m, 110, 111, 150, 1_000, 1_000);
    const b = try spawn(&m, 112, 113, 150, 1_000, 1_000);
    _ = try m.invoke(0, 110, abi.ThreadMethod.resume_thread, &.{});
    _ = try m.invoke(0, 112, abi.ThreadMethod.resume_thread, &.{});
    try retype(&m, .signal, 0, 100);
    _ = try m.sys(0, .wait, 100, 0, &.{});
    try std.testing.expect(m.current(0) == a);
    try m.advance(0, 1_000);
    try std.testing.expect(m.current(0) == b);
    try m.advance(0, 1_000);
    try std.testing.expect(m.current(0) == a);
}

test "capability transfer through an endpoint needs grant" {
    var m = try bootMachine();
    defer m.deinit();
    try retype(&m, .endpoint, 0, 100);
    try retype(&m, .signal, 0, 101);
    try retype(&m, .frame, 12, 102);
    try expectEqual(abi.Status.ok, (try m.invoke(0, S.thread, abi.ThreadMethod.set_ipc_buffer, &.{ S.ipc_buffer_frame, abi.RootLayout.ipc_buffer })).status);
    const rx = try spawn(&m, 110, 111, 200, 100_000, 100_000);
    _ = try m.invoke(0, 110, abi.ThreadMethod.set_ipc_buffer, &.{ 102, 0x50000 });
    _ = try m.invoke(0, 110, abi.ThreadMethod.resume_thread, &.{});
    _ = try m.invoke(0, S.thread, abi.ThreadMethod.set_priority, &.{100});
    try std.testing.expect(m.current(0) == rx);
    const rx_buf: *abi.IpcBuffer = @ptrFromInt(machine.arch.physToVirt(m.k.table[@intCast((try identify(&m, 102)).words[4])].addr));
    _ = &rx_buf;
    // (identify ran as rx, which shares the CSpace; fine.)
    rx_buf.recv_slots[0] = 120;
    _ = try m.sys(0, .recv, 100, 0, &.{});
    try std.testing.expect(m.current(0) == m.root);
    const root_buf: *abi.IpcBuffer = @ptrFromInt(machine.arch.physToVirt(m.k.table[@intCast((try identify(&m, S.ipc_buffer_frame)).words[4])].addr));
    root_buf.send_caps[0] = 101;
    const tag: abi.Tag = .{ .length = 0, .caps = 1 };
    // Without grant: the message arrives, the capability does not.
    _ = try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ 130, 100, (abi.Rights{ .send = true }).bits(), 0 });
    _ = try m.sys(0, .send, 130, @bitCast(tag), &.{});
    try expectEqual(@as(u3, 0), Machine.result(rx).tag.caps);
    try expectEqual(abi.Status.invalid_cap, (try identify(&m, 120)).status);
    // rx waits again; with grant the signal capability lands in slot 120.
    try std.testing.expect(m.current(0) == rx);
    _ = try m.sys(0, .recv, 100, 0, &.{});
    _ = try m.sys(0, .send, 100, @bitCast(tag), &.{});
    try expectEqual(@as(u3, 1), Machine.result(rx).tag.caps);
    try expectEqual(@as(u64, @backingInt(abi.Kind.signal)), (try identify(&m, 120)).words[0]);
}

test "interrupts arrive as signals and stay masked until acked" {
    var m = try bootMachine();
    defer m.deinit();
    try retype(&m, .signal, 0, 100);
    _ = try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ 101, 100, (abi.Rights{ .send = true }).bits(), 0b100 });
    try expectEqual(abi.Status.ok, (try m.invoke(0, S.irq_control, abi.IrqControlMethod.get, &.{ 10, 102 })).status);
    try expectEqual(abi.Status.invalid_state, (try m.invoke(0, S.irq_control, abi.IrqControlMethod.get, &.{ 10, 103 })).status);
    _ = try m.invoke(0, 102, abi.IrqMethod.set_signal, &.{101});
    try std.testing.expect(!machine.arch.irq_masked[10]);
    _ = try m.sys(0, .wait, 100, 0, &.{});
    try std.testing.expect(m.current(0) == null);
    try m.irq(10);
    try std.testing.expect(machine.arch.irq_masked[10]);
    try std.testing.expect(m.current(0) == m.root);
    try expectEqual(@as(u64, 0b100), Machine.result(m.root).words[0]);
    _ = try m.invoke(0, 102, abi.IrqMethod.ack, &.{});
    try std.testing.expect(!machine.arch.irq_masked[10]);
}

test "destroying a server aborts its waiting caller" {
    var m = try bootMachine();
    defer m.deinit();
    try retype(&m, .untyped, 16, 90);
    try retype(&m, .endpoint, 0, 100);
    // The server lives in the child untyped, so resetting that destroys it alone.
    try expectEqual(abi.Status.ok, (try m.invoke(0, 90, abi.UntypedMethod.retype, &.{ @backingInt(abi.Kind.thread), 0, 110 })).status);
    try expectEqual(abi.Status.ok, (try m.invoke(0, 90, abi.UntypedMethod.retype, &.{ @backingInt(abi.Kind.sched_context), 0, 111 })).status);
    _ = try m.invoke(0, S.sched_control, abi.SchedControlMethod.configure, &.{ 111, 50_000, 50_000, 0 });
    _ = try m.invoke(0, 110, abi.ThreadMethod.configure, &.{ S.cnode, S.vspace, 0 });
    _ = try m.invoke(0, 110, abi.ThreadMethod.set_priority, &.{200});
    _ = try m.invoke(0, 110, abi.ThreadMethod.bind_sched, &.{111});
    _ = try m.invoke(0, 110, abi.ThreadMethod.resume_thread, &.{});
    _ = try m.invoke(0, S.thread, abi.ThreadMethod.set_priority, &.{100});
    const server = m.current(0).?;
    try std.testing.expect(server != m.root);
    _ = try m.sys(0, .recv, 100, 0, &.{});
    _ = try m.sys(0, .call, 100, 0, &.{});
    try std.testing.expect(m.current(0) == server);
    try expectEqual(abi.ThreadState.blocked_reply, m.root.state);
    // The server destroys itself by resetting the region it was made from.
    _ = try m.sys(0, .invoke, 90, @backingInt(abi.UntypedMethod.reset), &.{});
    try std.testing.expect(m.current(0) == m.root);
    try expectEqual(abi.Status.aborted, Machine.result(m.root).status);
    try expectEqual(abi.Status.invalid_cap, (try identify(&m, 110)).status);
}

/// Root becomes a caller lending its context to a passive server. Returns the server.
fn lendToPassiveServer(m: *Machine) !*machine.Thread {
    try retype(m, .endpoint, 0, 100);
    const server = try spawn(m, 110, 111, 200, 50_000, 50_000);
    _ = try m.invoke(0, 110, abi.ThreadMethod.resume_thread, &.{});
    _ = try m.invoke(0, S.thread, abi.ThreadMethod.set_priority, &.{100});
    _ = try m.sys(0, .recv, 100, 0, &.{}); // as the server
    _ = try m.invoke(0, 110, abi.ThreadMethod.bind_sched, &.{0});
    // Spawn a helper so someone can act while the root waits for its reply.
    _ = try m.sys(0, .call, 100, 0, &.{});
    try std.testing.expect(m.current(0) == server);
    try expectEqual(m.root.sc, server.sc);
    return server;
}

test "suspending a caller takes back the context its server borrowed" {
    var m = try bootMachine();
    defer m.deinit();
    const server = try lendToPassiveServer(&m);
    // The server (acting now) suspends the root, which is waiting for its reply.
    _ = try m.invoke(0, S.thread, abi.ThreadMethod.suspend_thread, &.{});
    try expectEqual(@as(u32, 0), server.sc);
    try expectEqual(abi.ThreadState.inactive, m.root.state);
    try std.testing.expect(server.state != .running);
    // Resuming the root must not make two threads share one context.
    m.k.handle(0, m.now, .ipi);
    try m.check();
}

test "unbinding a lent context takes it from the server too" {
    var m = try bootMachine();
    defer m.deinit();
    const server = try lendToPassiveServer(&m);
    _ = try m.invoke(0, S.thread, abi.ThreadMethod.bind_sched, &.{0});
    try expectEqual(@as(u32, 0), server.sc);
    try expectEqual(@as(u32, 0), m.root.sc);
}

test "huge sizes and periods are refused, not overflowed" {
    var m = try bootMachine();
    defer m.deinit();
    const r = try m.invoke(0, first_untyped, abi.UntypedMethod.retype, &.{ @backingInt(abi.Kind.untyped), 47, 100 });
    try expectEqual(abi.Status.no_objects, r.status);
    try retype(&m, .sched_context, 0, 101);
    const big = std.math.maxInt(u64);
    try expectEqual(abi.Status.invalid_argument, (try m.invoke(0, S.sched_control, abi.SchedControlMethod.configure, &.{ 101, big, big, 0 })).status);
    try expectEqual(abi.Status.ok, (try m.invoke(0, S.sched_control, abi.SchedControlMethod.configure, &.{ 101, 1 << 48, 1 << 48, 0 })).status);
}

test "a budget that runs out during a call is still refilled (no lost wakeup)" {
    var m = try bootMachine();
    defer m.deinit();
    try retype(&m, .endpoint, 0, 100);
    const server = try spawn(&m, 110, 111, 200, 50_000, 50_000);
    _ = try m.invoke(0, 110, abi.ThreadMethod.resume_thread, &.{});
    _ = try m.invoke(0, S.thread, abi.ThreadMethod.set_priority, &.{100});
    _ = try m.sys(0, .recv, 100, 0, &.{}); // as the server
    _ = try m.invoke(0, 110, abi.ThreadMethod.bind_sched, &.{0});
    try std.testing.expect(m.current(0) == m.root);
    // The root's whole 100_000-tick budget passes without a timer interrupt
    // (it is charged at its next kernel entry), and that entry is a call.
    m.now += 100_000;
    _ = try m.sys(0, .call, 100, 0, &.{});
    // The server must run on the (refilled) lent context, not stall forever.
    try std.testing.expect(m.current(0) == server);
    try std.testing.expect(!m.k.stuck());
}

test "frame info reports physical address; exit needs configure" {
    var m = try bootMachine();
    defer m.deinit();
    try retype(&m, .frame, 12, 100);
    const r = try m.invoke(0, 100, abi.FrameMethod.info, &.{});
    try expectEqual(abi.Status.ok, r.status);
    try std.testing.expect(r.words[0] >= machine.arch.ram_base and r.words[0] % 4096 == 0);
    try expectEqual(@as(u64, 4096), r.words[1]);
    try expectEqual(@as(u64, 0), r.words[3]);
    // A write-only console capability can print but not power off.
    _ = try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ 101, S.debug_console, (abi.Rights{ .write = true }).bits(), 0 });
    try expectEqual(abi.Status.no_rights, (try m.invoke(0, 101, abi.DebugMethod.exit, &.{0})).status);
    try std.testing.expect(m.k.exitRequested() == null);
}

test "endpoints refuse a sender whose protocol differs from the receiver's" {
    var m = try bootMachine();
    defer m.deinit();
    try retype(&m, .endpoint, 0, 100);
    const all = abi.Rights.all.bits();
    // Server side stamped 0x1234, a right client and a wrong one.
    try expectEqual(abi.Status.ok, (try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ 101, 100, all, 0, 0x1234 })).status);
    try expectEqual(abi.Status.ok, (try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ 102, 100, all, 7, 0x1234 })).status);
    try expectEqual(abi.Status.ok, (try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ 103, 100, all, 8, 0x9999 })).status);
    // A stamped protocol cannot be changed.
    try expectEqual(abi.Status.invalid_argument, (try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ 104, 101, all, 0, 0x4321 })).status);

    const server = try spawn(&m, 110, 111, 200, 50_000, 50_000);
    _ = try m.invoke(0, 110, abi.ThreadMethod.resume_thread, &.{});
    _ = try m.invoke(0, S.thread, abi.ThreadMethod.set_priority, &.{100});
    try std.testing.expect(m.current(0) == server);
    _ = try m.sys(0, .recv, 101, 0, &.{});
    try std.testing.expect(m.current(0) == m.root);
    // Wrong protocol: refused at once, the server keeps waiting.
    try expectEqual(abi.Status.protocol_mismatch, Machine.result(try m.sys(0, .send, 103, 0, &.{})).status);
    try expectEqual(abi.ThreadState.blocked_recv, server.state);
    // Unstamped capabilities are not checked; the right protocol goes through.
    _ = try m.sys(0, .send, 102, 0, &.{});
    try expectEqual(@as(u64, 7), Machine.result(server).badge);
}

test "a queued sender with the wrong protocol is refused when the receiver arrives" {
    var m = try bootMachine();
    defer m.deinit();
    try retype(&m, .endpoint, 0, 100);
    const all = abi.Rights.all.bits();
    _ = try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ 101, 100, all, 0, 0x1234 });
    _ = try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ 103, 100, all, 8, 0x9999 });
    const server = try spawn(&m, 110, 111, 100, 50_000, 50_000);
    _ = try m.invoke(0, 110, abi.ThreadMethod.resume_thread, &.{});
    // Root queues a send with the wrong protocol, then the server receives.
    _ = try m.sys(0, .send, 103, 0, &.{});
    try expectEqual(abi.ThreadState.blocked_send, m.root.state);
    try std.testing.expect(m.current(0) == server);
    _ = try m.sys(0, .recv, 101, 0, &.{});
    try expectEqual(abi.Status.protocol_mismatch, Machine.result(m.root).status);
    try expectEqual(abi.ThreadState.blocked_recv, server.state);
    try std.testing.expect(m.current(0) == m.root);
}
