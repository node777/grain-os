//! The root task: the first and only program the kernel starts. It holds
//! every initial capability. Later phases make it Steward (the manifest
//! runner); for now it exercises the kernel from user mode and reports
//! structured results:
//!
//!   @grain test name=<name> result=pass|fail [detail=...]
//!   @grain bench name=<name> ops=<n> cycles_per_op=<n> instret_per_op=<n>
//!   @grain summary tests=<n> failed=<n>
const std = @import("std");
const g = @import("grain");
const abi = g.abi;
const S = g.S;
const Kind = abi.Kind;

var boot_info: *const abi.BootInfo = undefined;
var next_slot: g.CPtr = 0;
var ut: g.CPtr = 0; // the largest RAM untyped

export fn _start() linksection(".text._start") callconv(.naked) noreturn {
    // The kernel sets sp and passes the boot-info address in a0.
    asm volatile (g.cpu.callStub("rootMain"));
}

fn slot() g.CPtr {
    const s = next_slot;
    next_slot += 1;
    return s;
}

fn retype(kind: Kind, bits: usize) !g.CPtr {
    const s = slot();
    const r = g.invoke(ut, abi.UntypedMethod.retype, .{ kind, bits, s });
    if (!r.ok()) {
        g.record("retype_failed", .{ .kind = @tagName(kind), .status = @tagName(r.status) });
        return error.RetypeFailed;
    }
    return s;
}

fn check(cond: bool) !void {
    if (!cond) return error.CheckFailed;
}

fn expectStatus(want: abi.Status, got: abi.Status) !void {
    if (want != got) {
        g.record("expect", .{ .want = @tagName(want), .got = @tagName(got) });
        return error.CheckFailed;
    }
}

// ---------------------------------------------------------------------------
// Memory: map frames into our own address space, making page tables on demand.

fn mapPage(frame: g.CPtr, va: usize, rights: abi.Rights) !void {
    var tries: usize = 0;
    while (tries < 3) : (tries += 1) {
        const r = g.invoke(S.vspace, abi.VSpaceMethod.map_frame, .{ frame, va, rights.bits() });
        switch (r.status) {
            .ok => return,
            .no_page_table => {
                // Try a level-1 table first, then level 0.
                const l1 = try retype(.page_table, 1);
                if (!g.invoke(S.vspace, abi.VSpaceMethod.map_table, .{ l1, va }).ok()) {
                    const l0 = try retype(.page_table, 0);
                    try expectStatus(.ok, g.invoke(S.vspace, abi.VSpaceMethod.map_table, .{ l0, va }).status);
                }
            },
            else => {
                g.record("map_failed", .{ .va = g.klog.hex(va), .status = @tagName(r.status) });
                return error.MapFailed;
            },
        }
    }
    return error.MapFailed;
}

const rw: abi.Rights = .{ .read = true, .write = true };

var stack_cursor: usize = 0x6000_0000;

/// A fresh 16 KiB stack in our address space; returns its top.
fn newStack() !usize {
    const base = stack_cursor;
    stack_cursor += 0x8000; // 16 KiB stack + 16 KiB guard gap
    for (0..4) |i| try mapPage(try retype(.frame, 12), base + i * 4096, rw);
    return base + 4 * 4096;
}

// ---------------------------------------------------------------------------
// Threads sharing our CSpace and address space.

const Spawn = struct {
    prio: u8 = 200,
    budget_us: u64 = 10_000,
    period_us: u64 = 10_000,
    hart: usize = 0,
    fault_ep: g.CPtr = 0,
    with_sc: bool = true,
};

fn ticks(us: u64) u64 {
    return boot_info.timebase_hz * us / 1_000_000;
}

const Worker = struct { thread: g.CPtr, sc: g.CPtr };

fn spawn(entry: *const fn (usize) callconv(.c) noreturn, arg: usize, o: Spawn) !Worker {
    const t = try retype(.thread, 0);
    try expectStatus(.ok, g.invoke(t, abi.ThreadMethod.configure, .{ S.cnode, S.vspace, o.fault_ep }).status);
    try expectStatus(.ok, g.invoke(t, abi.ThreadMethod.set_priority, .{o.prio}).status);
    const sp = try newStack();
    try expectStatus(.ok, g.invoke(t, abi.ThreadMethod.write_registers, .{ @intFromPtr(entry), sp, arg, 0 }).status);
    var sc: g.CPtr = 0;
    if (o.with_sc) {
        sc = try retype(.sched_context, 0);
        try expectStatus(.ok, g.invoke(S.sched_control, abi.SchedControlMethod.configure, .{ sc, ticks(o.budget_us), ticks(o.period_us), o.hart }).status);
        try expectStatus(.ok, g.invoke(t, abi.ThreadMethod.bind_sched, .{sc}).status);
    }
    try expectStatus(.ok, g.invoke(t, abi.ThreadMethod.resume_thread, .{}).status);
    return .{ .thread = t, .sc = sc };
}

fn threadState(t: g.CPtr) abi.ThreadState {
    return @fromBackingInt(@intCast(g.invoke(t, abi.ThreadMethod.info, .{}).w[0]));
}

fn threadHart(t: g.CPtr) usize {
    return g.invoke(t, abi.ThreadMethod.info, .{}).w[3];
}

/// Let lower-priority threads run until `cond` holds: drop our priority,
/// spin on the clock, then take it back (our maximum priority stays 255).
fn runOthersUntil(cond: *const fn () bool, timeout_us: u64) bool {
    _ = g.invoke(S.thread, abi.ThreadMethod.set_priority, .{1});
    const deadline = g.time() + ticks(timeout_us);
    var ok = false;
    while (g.time() < deadline) {
        if (cond()) {
            ok = true;
            break;
        }
        g.yield();
    }
    _ = g.invoke(S.thread, abi.ThreadMethod.set_priority, .{255});
    return ok;
}

// ---------------------------------------------------------------------------
// Tests

fn testBootInfo() !void {
    try check(boot_info.magic == abi.boot_info_magic);
    try check(boot_info.untyped_count > 0);
    try check(boot_info.timebase_hz > 0);
    try check(boot_info.hart_count >= 1);
    g.record("boot_info", .{ .harts = boot_info.hart_count, .untyped = boot_info.untyped_count, .timebase_hz = boot_info.timebase_hz });
}

fn testDeviceTree() !void {
    try check(boot_info.dtb_size >= 40);
    const p: [*]const u8 = @ptrFromInt(boot_info.dtb_addr);
    try check(std.mem.readInt(u32, p[0..4], .big) == 0xd00dfeed);
    try check(std.mem.readInt(u32, p[4..8], .big) <= boot_info.dtb_size);
}

fn testIdentify() !void {
    const want = [_]struct { g.CPtr, Kind }{
        .{ S.cnode, .cnode },                 .{ S.vspace, .page_table },       .{ S.thread, .thread },
        .{ S.sched_context, .sched_context }, .{ S.irq_control, .irq_control }, .{ S.sched_control, .sched_control },
        .{ S.debug_console, .debug_console }, .{ S.boot_info_frame, .frame },   .{ S.ipc_buffer_frame, .frame },
    };
    for (want) |w| {
        const r = g.invoke(S.cnode, abi.CNodeMethod.identify, .{w[0]});
        try expectStatus(.ok, r.status);
        try check(r.w[0] == @backingInt(w[1]));
    }
    try expectStatus(.invalid_cap, g.invoke(S.cnode, abi.CNodeMethod.identify, .{next_slot + 100}).status);
}

fn testMintRevoke() !void {
    const ep = try retype(.endpoint, 0);
    const copy = slot();
    const send_only: abi.Rights = .{ .send = true };
    try expectStatus(.ok, g.invoke(S.cnode, abi.CNodeMethod.mint, .{ copy, ep, send_only.bits(), 7 }).status);
    const id = g.invoke(S.cnode, abi.CNodeMethod.identify, .{copy});
    try check(id.w[1] == send_only.bits() and id.w[2] == 7);
    try expectStatus(.no_rights, g.recv(copy).status);
    try expectStatus(.ok, g.invoke(S.cnode, abi.CNodeMethod.revoke, .{ep}).status);
    try expectStatus(.invalid_cap, g.invoke(S.cnode, abi.CNodeMethod.identify, .{copy}).status);
    try expectStatus(.ok, g.invoke(S.cnode, abi.CNodeMethod.identify, .{ep}).status);
}

var shared_signal: g.CPtr = 0;

fn signalWorker(arg: usize) callconv(.c) noreturn {
    _ = g.signal(@intCast(arg));
    while (true) _ = g.wait(@intCast(arg + 1000)); // invalid slot: returns at once
}

fn testThreadSignal() !void {
    const sig = try retype(.signal, 0);
    const badged = slot();
    try expectStatus(.ok, g.invoke(S.cnode, abi.CNodeMethod.mint, .{ badged, sig, (abi.Rights{ .send = true }).bits(), 0b1010 }).status);
    const w = try spawn(signalWorker, badged, .{ .prio = 254 });
    const r = g.wait(sig);
    try expectStatus(.ok, r.status);
    try check(r.w[0] == 0b1010);
    _ = g.invoke(w.thread, abi.ThreadMethod.suspend_thread, .{});
}

var bound_bits: usize = 0;

/// Serves calls and its bound signal on one wait: a call is answered with
/// the signal bits seen so far.
fn boundServer(ep: usize) callconv(.c) noreturn {
    var r = g.recv(@intCast(ep));
    while (true) {
        if (r.signalled) {
            bound_bits |= r.w[0];
            r = g.recv(@intCast(ep));
        } else r = g.replyRecv(@intCast(ep), .{ .length = 1 }, .{bound_bits});
    }
}

fn boundBitsSeen() bool {
    return bound_bits != 0;
}

fn testBoundSignal() !void {
    const ep = try retype(.endpoint, 0);
    const sig = try retype(.signal, 0);
    const badged = slot();
    try expectStatus(.ok, g.invoke(S.cnode, abi.CNodeMethod.mint, .{ badged, sig, (abi.Rights{ .send = true }).bits(), 0b100 }).status);
    const w = try spawn(boundServer, ep, .{ .prio = 254 });
    try expectStatus(.ok, g.invoke(w.thread, abi.ThreadMethod.bind_signal, .{sig}).status);
    server_thread = w.thread;
    try check(runOthersUntil(serverWaiting, 100_000));
    // The signal ends the server's receive; it notes the bits and waits again.
    _ = g.signal(badged);
    try check(runOthersUntil(boundBitsSeen, 100_000));
    try check(runOthersUntil(serverWaiting, 100_000));
    // And it still serves calls.
    const r = g.call(ep, .{ .length = 1 }, .{0});
    try expectStatus(.ok, r.status);
    try check(r.w[0] == 0b100 and !r.signalled);
    _ = g.invoke(w.thread, abi.ThreadMethod.suspend_thread, .{});
}

fn testAlarm() !void {
    const sig = try retype(.signal, 0);
    const badged = slot();
    try expectStatus(.ok, g.invoke(S.cnode, abi.CNodeMethod.mint, .{ badged, sig, (abi.Rights{ .send = true }).bits(), 0b10 }).status);
    // Not yet; then, after its ticks, once.
    const t0 = g.time();
    try expectStatus(.ok, g.alarm(badged, ticks(2_000)));
    try check(g.poll(sig).w[0] == 0);
    const r = g.wait(sig);
    try check(r.w[0] == 0b10 and g.time() - t0 >= ticks(2_000));
    try check(g.poll(sig).w[0] == 0);
    // Cancelled, it never fires.
    try expectStatus(.ok, g.alarm(badged, ticks(1_000)));
    try expectStatus(.ok, g.alarm(badged, 0));
    const t1 = g.time();
    while (g.time() - t1 < ticks(3_000)) g.yield();
    try check(g.poll(sig).w[0] == 0);
}

fn echoServer(ep: usize) callconv(.c) noreturn {
    var r = g.recv(@intCast(ep));
    while (true) {
        // Answers value + 1, the badge it saw, and the sender's protocol id.
        r = g.replyRecv(@intCast(ep), .{ .length = 3 }, .{ r.w[0] + 1, r.badge, r.protocol });
    }
}

var server_ep: g.CPtr = 0;
fn serverWaiting() bool {
    return threadState(server_thread) == .blocked_recv;
}
var server_thread: g.CPtr = 0;

fn benchCalls(ep: g.CPtr, comptime name: []const u8, n: usize) !void {
    var i: usize = 0;
    const c0 = g.cycles();
    const n0 = g.instret();
    const t0 = g.time();
    while (i < n) : (i += 1) {
        const r = g.call(ep, .{ .length = 1 }, .{i});
        try expectStatus(.ok, r.status);
        try check(r.w[0] == i + 1);
    }
    const dc = g.cycles() - c0;
    const dn = g.instret() - n0;
    const dt = g.time() - t0;
    g.record("bench", .{ .name = name, .ops = n, .cycles_per_op = dc / n, .instret_per_op = dn / n, .ns_per_op = dt * 1_000_000_000 / boot_info.timebase_hz / n });
}

fn testSyscallCost() !void {
    const n = 2000;
    var c0 = g.instret();
    for (0..n) |_| g.yield();
    g.record("bench", .{ .name = "syscall_yield", .ops = n, .instret_per_op = (g.instret() - c0) / n });
    c0 = g.instret();
    for (0..n) |_| try expectStatus(.ok, g.invoke(S.cnode, abi.CNodeMethod.identify, .{S.cnode}).status);
    g.record("bench", .{ .name = "invoke_identify", .ops = n, .instret_per_op = (g.instret() - c0) / n });
}

fn testProtocolCheck() !void {
    const ep = try retype(.endpoint, 0);
    const all = abi.Rights.all.bits();
    const server_cap = slot();
    const good = slot();
    const bad = slot();
    try expectStatus(.ok, g.invoke(S.cnode, abi.CNodeMethod.mint, .{ server_cap, ep, all, 0, 0x1111 }).status);
    try expectStatus(.ok, g.invoke(S.cnode, abi.CNodeMethod.mint, .{ good, ep, all, 3, 0x1111 }).status);
    try expectStatus(.ok, g.invoke(S.cnode, abi.CNodeMethod.mint, .{ bad, ep, all, 4, 0x2222 }).status);
    const w = try spawn(echoServer, server_cap, .{ .prio = 250 });
    server_thread = w.thread;
    try check(runOthersUntil(serverWaiting, 100_000));
    try expectStatus(.protocol_mismatch, g.call(bad, .{ .length = 1 }, .{1}).status);
    const r = g.call(good, .{ .length = 1 }, .{1});
    try expectStatus(.ok, r.status);
    // The server learns which protocol the caller's capability speaks.
    try check(r.w[0] == 2 and r.w[1] == 3 and r.w[2] == 0x1111);
    _ = g.invoke(w.thread, abi.ThreadMethod.suspend_thread, .{});
}

/// One long write reaches the console whole (here: a record line longer
/// than the 32 register bytes); more than the IPC buffer holds is refused.
fn testLongDebugWrite() !void {
    const line = "@grain long_write_ok text=" ++ "01234567890123456789012345678901234567890123456789012345678901234567890123456789" ++ "\n";
    comptime std.debug.assert(line.len > 32 and line.len <= abi.max_debug_write);
    g.write(line);
    const too_long = g.syscall(.invoke, S.debug_console, @backingInt(abi.DebugMethod.write), .{ abi.max_debug_write + 1, 0, 0, 0, 0 });
    try expectStatus(.invalid_argument, too_long.status);
}

fn testPassiveServerCall() !void {
    const ep = try retype(.endpoint, 0);
    const badged = slot();
    try expectStatus(.ok, g.invoke(S.cnode, abi.CNodeMethod.mint, .{ badged, ep, (abi.Rights{ .send = true }).bits(), 99 }).status);
    // The server needs time to reach recv; then it gives its context up.
    const w = try spawn(echoServer, ep, .{ .prio = 250 });
    server_thread = w.thread;
    try check(runOthersUntil(serverWaiting, 100_000));
    try expectStatus(.ok, g.invoke(w.thread, abi.ThreadMethod.bind_sched, .{0}).status);
    const r = g.call(badged, .{ .length = 1 }, .{41});
    try expectStatus(.ok, r.status);
    try check(r.w[0] == 42 and r.w[1] == 99 and r.w[2] == 0 and r.tag.length == 3);
    try benchCalls(badged, "ipc_call_passive_server", 2000);
}

var fault_value: usize = 0;
var fault_done: g.CPtr = 0;
const fault_va: usize = 0x5000_0000;

fn faultingWorker(arg: usize) callconv(.c) noreturn {
    _ = arg;
    const p: *volatile usize = @ptrFromInt(fault_va);
    fault_value = p.*; // faults until the root maps a page here
    _ = g.signal(fault_done);
    while (true) g.yield();
}

fn testFaultHandling() !void {
    const ep = try retype(.endpoint, 0);
    const fep = slot();
    try expectStatus(.ok, g.invoke(S.cnode, abi.CNodeMethod.mint, .{ fep, ep, (abi.Rights{ .send = true }).bits(), 5 }).status);
    fault_done = try retype(.signal, 0);
    const w = try spawn(faultingWorker, 0, .{ .prio = 250, .fault_ep = fep });
    const f = g.recv(ep);
    try expectStatus(.ok, f.status);
    try check(f.tag.label == @backingInt(abi.FaultKind.load_page_fault));
    try check(f.w[0] == fault_va and f.badge == 5);
    // Map the missing page, put a value in it, and retry the instruction.
    try mapPage(try retype(.frame, 12), fault_va, rw);
    @as(*volatile usize, @ptrFromInt(fault_va)).* = 0xfeed;
    try expectStatus(.ok, g.reply(.{ .label = 0 }, .{}));
    const r = g.wait(fault_done);
    try expectStatus(.ok, r.status);
    try check(fault_value == 0xfeed);
    _ = g.invoke(w.thread, abi.ThreadMethod.suspend_thread, .{});
}

fn testLeases() !void {
    const sig = try retype(.signal, 0);
    const lease = try retype(.lease, 0);
    const sr: abi.Rights = .{ .send = true, .recv = true };
    try expectStatus(.ok, g.invoke(lease, abi.LeaseMethod.arm, .{ sig, sr.bits(), 0, 3 }).status);
    const held = slot();
    try expectStatus(.ok, g.invoke(S.cnode, abi.CNodeMethod.mint, .{ held, lease, sr.bits(), 0 }).status);
    for (0..3) |_| try expectStatus(.ok, g.signal(held));
    try expectStatus(.lease_exhausted, g.signal(held));

    const timed = try retype(.lease, 0);
    try expectStatus(.ok, g.invoke(timed, abi.LeaseMethod.arm, .{ sig, sr.bits(), ticks(2_000), 0 }).status);
    try expectStatus(.ok, g.signal(timed));
    const until = g.time() + ticks(3_000);
    while (g.time() < until) {}
    try expectStatus(.lease_expired, g.signal(timed));

    const revocable = try retype(.lease, 0);
    try expectStatus(.ok, g.invoke(revocable, abi.LeaseMethod.arm, .{ sig, sr.bits(), 0, 0 }).status);
    const given = slot();
    try expectStatus(.ok, g.invoke(S.cnode, abi.CNodeMethod.mint, .{ given, revocable, (abi.Rights{ .send = true }).bits(), 0 }).status);
    try expectStatus(.ok, g.signal(given));
    try expectStatus(.ok, g.invoke(S.cnode, abi.CNodeMethod.revoke, .{revocable}).status);
    try expectStatus(.invalid_cap, g.signal(given));
    try expectStatus(.ok, g.signal(sig));
}

var counters: [2]u64 = .{ 0, 0 };
var stop_spinning = std.atomic.Value(bool).init(false);

fn spinner(i: usize) callconv(.c) noreturn {
    while (!stop_spinning.load(.acquire)) {
        const p: *volatile u64 = &counters[i];
        p.* += 1;
    }
    while (true) g.yield();
}

fn spinnersRan() bool {
    return false; // run for the whole window
}

fn testBudgets() !void {
    // Two equal-priority spinners, each allowed 30% of every 10 ms. They
    // must share the CPU, and leave the rest to us even though they
    // outrank us while we wait.
    const a = try spawn(spinner, 0, .{ .prio = 200, .budget_us = 3_000, .period_us = 10_000 });
    const b = try spawn(spinner, 1, .{ .prio = 200, .budget_us = 3_000, .period_us = 10_000 });
    const t0 = g.time();
    _ = runOthersUntil(spinnersRan, 60_000);
    const elapsed = g.time() - t0;
    stop_spinning.store(true, .release);
    _ = g.invoke(a.thread, abi.ThreadMethod.suspend_thread, .{});
    _ = g.invoke(b.thread, abi.ThreadMethod.suspend_thread, .{});
    const ca = @as(*volatile u64, &counters[0]).*;
    const cb = @as(*volatile u64, &counters[1]).*;
    g.record("budget_share", .{ .spinner_a = ca, .spinner_b = cb, .elapsed_ticks = elapsed });
    try check(ca > 0 and cb > 0);
    // Equal budgets: within a factor of two of each other.
    try check(ca < 2 * cb and cb < 2 * ca);
}

fn testUntypedReset() !void {
    const child = try retype(.untyped, 16); // 64 KiB, 16 objects
    var made: usize = 0;
    var first: g.CPtr = 0;
    while (true) {
        const s = slot();
        const r = g.invoke(child, abi.UntypedMethod.retype, .{ Kind.endpoint, 0, s });
        if (!r.ok()) {
            try check(r.status == .no_objects);
            break;
        }
        if (first == 0) first = s;
        made += 1;
    }
    try check(made == 16); // 64 KiB earns 16 objects; the child's own body lives in its parent
    try expectStatus(.ok, g.invoke(child, abi.UntypedMethod.reset, .{}).status);
    try expectStatus(.invalid_cap, g.invoke(S.cnode, abi.CNodeMethod.identify, .{first}).status);
    const again = slot();
    try expectStatus(.ok, g.invoke(child, abi.UntypedMethod.retype, .{ Kind.endpoint, 0, again }).status);
}

fn findDeviceUntyped(base: u64) ?g.CPtr {
    for (boot_info.untyped[0..boot_info.untyped_count], 0..) |u, i| {
        if (u.is_device != 0 and u.base <= base and base < u.base + u.size) return S.first_untyped + @as(g.CPtr, @intCast(i));
    }
    return null;
}

/// The board's UART (QEMU virt): a 16550 on RISC-V, a PL011 on Arm.
const arm = @import("builtin").cpu.arch == .aarch64;
const uart_base: u64 = if (arm) 0x0900_0000 else 0x1000_0000;
const uart_irq: usize = if (arm) 33 else 10;

/// Make the UART raise its interrupt now (transmitter empty), or stop.
fn uartTxInterrupt(va: usize, on: bool) void {
    if (arm) {
        const imsc: *volatile u32 = @ptrFromInt(va + 0x38);
        const icr: *volatile u32 = @ptrFromInt(va + 0x44);
        const dr: *volatile u32 = @ptrFromInt(va);
        if (on) {
            imsc.* = 1 << 5;
            dr.* = '\n'; // a sent byte raises the transmit interrupt
        } else {
            imsc.* = 0;
            icr.* = 1 << 5;
        }
    } else {
        const ier: *volatile u8 = @ptrFromInt(va + 1);
        ier.* = if (on) 0x02 else 0x00;
    }
}

fn testUartInterrupt() !void {
    const dev = findDeviceUntyped(uart_base) orelse return error.NoUartUntyped;
    const frame = slot();
    try expectStatus(.ok, g.invoke(dev, abi.UntypedMethod.retype, .{ Kind.frame, 12, frame }).status);
    const va: usize = 0x6100_0000;
    try mapPage(frame, va, rw);
    const sig = try retype(.signal, 0);
    const badged = slot();
    try expectStatus(.ok, g.invoke(S.cnode, abi.CNodeMethod.mint, .{ badged, sig, (abi.Rights{ .send = true }).bits(), 1 << 10 }).status);
    const irq = slot();
    try expectStatus(.ok, g.invoke(S.irq_control, abi.IrqControlMethod.get, .{ uart_irq, irq }).status);
    try expectStatus(.ok, g.invoke(irq, abi.IrqMethod.set_signal, .{badged}).status);
    // Enable the "transmitter empty" interrupt: it fires straight away.
    uartTxInterrupt(va, true);
    const r = g.wait(sig);
    uartTxInterrupt(va, false);
    try expectStatus(.ok, r.status);
    try check(r.w[0] == 1 << 10);
    try expectStatus(.ok, g.invoke(irq, abi.IrqMethod.ack, .{}).status);
}

var foreign_thread: g.CPtr = 0;
fn foreignRunning() bool {
    return threadState(foreign_thread) == .running;
}

fn retypeFrom(region: g.CPtr, kind: Kind, bits: usize) !g.CPtr {
    const s = slot();
    try expectStatus(.ok, g.invoke(region, abi.UntypedMethod.retype, .{ kind, bits, s }).status);
    return s;
}

/// Destroy a running thread and its whole address space while it executes
/// on another hart: the kernel must stop that hart from running it and
/// from translating through the dead page tables before memory is reused.
fn testForeignTeardown() !void {
    if (boot_info.hart_count < 2) return error.Skip;
    const region = try retype(.untyped, 20); // 1 MiB
    const vs = try retypeFrom(region, .page_table, 2);
    const l1 = try retypeFrom(region, .page_table, 1);
    const l0 = try retypeFrom(region, .page_table, 0);
    const code_va: usize = 0x10000;
    try expectStatus(.ok, g.invoke(vs, abi.VSpaceMethod.map_table, .{ l1, code_va }).status);
    try expectStatus(.ok, g.invoke(vs, abi.VSpaceMethod.map_table, .{ l0, code_va }).status);
    // The program is one instruction, `j .` (`b .`), written through a
    // temporary mapping in our own address space.
    const code = try retypeFrom(region, .frame, 12);
    const tmp_va: usize = 0x6200_0000;
    try mapPage(code, tmp_va, rw);
    @as(*volatile u32, @ptrFromInt(tmp_va)).* = g.cpu.spin_instruction;
    try expectStatus(.ok, g.invoke(S.vspace, abi.VSpaceMethod.unmap, .{tmp_va}).status);
    const rx: abi.Rights = .{ .read = true, .execute = true };
    try expectStatus(.ok, g.invoke(vs, abi.VSpaceMethod.map_frame, .{ code, code_va, rx.bits() }).status);

    const t = try retypeFrom(region, .thread, 0);
    const sc = try retypeFrom(region, .sched_context, 0);
    try expectStatus(.ok, g.invoke(t, abi.ThreadMethod.configure, .{ S.cnode, vs, 0 }).status);
    try expectStatus(.ok, g.invoke(t, abi.ThreadMethod.write_registers, .{ code_va, 0, 0, 0 }).status);
    try expectStatus(.ok, g.invoke(S.sched_control, abi.SchedControlMethod.configure, .{ sc, ticks(1_000), ticks(1_000), 1 }).status);
    try expectStatus(.ok, g.invoke(t, abi.ThreadMethod.bind_sched, .{sc}).status);
    try expectStatus(.ok, g.invoke(t, abi.ThreadMethod.resume_thread, .{}).status);
    foreign_thread = t;
    var tries: usize = 0;
    while (!foreignRunning() and tries < 100_000) : (tries += 1) g.yield();
    try check(foreignRunning());
    try check(threadHart(t) == 1);

    try expectStatus(.ok, g.invoke(region, abi.UntypedMethod.reset, .{}).status);
    try expectStatus(.invalid_cap, g.invoke(S.cnode, abi.CNodeMethod.identify, .{t}).status);
    try expectStatus(.invalid_cap, g.invoke(S.cnode, abi.CNodeMethod.identify, .{vs}).status);
    // The region is whole again.
    const r = g.invoke(region, abi.UntypedMethod.info, .{});
    try check(r.w[2] == r.w[1]);
}

fn testCrossHartCall() !void {
    if (boot_info.hart_count < 2) return error.Skip;
    const ep = try retype(.endpoint, 0);
    // An active server with its own time on hart 1.
    const w = try spawn(echoServer, ep, .{ .prio = 250, .hart = 1 });
    server_thread = w.thread;
    var tries: usize = 0;
    while (threadState(w.thread) != .blocked_recv and tries < 1_000_000) : (tries += 1) std.atomic.spinLoopHint();
    try check(threadHart(w.thread) == 1);
    const r = g.call(ep, .{ .length = 1 }, .{7});
    try expectStatus(.ok, r.status);
    try check(r.w[0] == 8);
    try benchCalls(ep, "ipc_call_cross_hart", 500);
}

// ---------------------------------------------------------------------------

var failed: u32 = 0;
var ran: u32 = 0;

fn run(comptime name: []const u8, f: fn () anyerror!void) void {
    f() catch |e| {
        if (e == error.Skip) {
            g.record("test", .{ .name = name, .result = "skip" });
            return;
        }
        failed += 1;
        ran += 1;
        g.record("test", .{ .name = name, .result = "fail", .err = @errorName(e) });
        return;
    };
    ran += 1;
    g.record("test", .{ .name = name, .result = "pass" });
}

export fn rootMain(bi: *const abi.BootInfo) callconv(.c) noreturn {
    boot_info = bi;
    next_slot = bi.first_free_slot;
    // The largest RAM region is where our own objects came from too.
    var best: usize = 0;
    for (bi.untyped[0..bi.untyped_count], 0..) |u, i| {
        if (u.is_device == 0 and u.size > bi.untyped[best].size) best = i;
    }
    ut = S.first_untyped + @as(g.CPtr, @intCast(best));
    g.record("root_start", .{ .first_free_slot = bi.first_free_slot, .untyped = bi.untyped_count, .harts = bi.hart_count });

    run("boot_info", testBootInfo);
    run("device_tree", testDeviceTree);
    run("identify_root_caps", testIdentify);
    run("mint_and_revoke", testMintRevoke);
    run("thread_signal", testThreadSignal);
    run("bound_signal", testBoundSignal);
    run("alarm", testAlarm);
    run("syscall_cost", testSyscallCost);
    run("protocol_check", testProtocolCheck);
    run("long_debug_write", testLongDebugWrite);
    run("call_passive_server", testPassiveServerCall);
    run("fault_handler", testFaultHandling);
    run("leases", testLeases);
    run("budgets_share_cpu", testBudgets);
    run("untyped_reset", testUntypedReset);
    run("uart_interrupt", testUartInterrupt);
    run("foreign_teardown_on_other_hart", testForeignTeardown);
    run("cross_hart_call", testCrossHartCall);

    g.record("summary", .{ .tests = ran, .failed = failed });
    g.exit(@intCast(@min(failed, 0xfe)));
}
