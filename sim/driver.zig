//! One step of random activity on a simulated machine: a system call
//! (plausible or garbage), a fault, an interrupt, an IPI or time passing,
//! then the IPIs the kernel asked for. The simulator draws the choices from
//! a seeded PRNG; the kernel fuzz target from the fuzzer. Every kernel entry
//! is followed by the invariant check.
const std = @import("std");
const abi = @import("abi");
const core = @import("core");
const machine = @import("machine.zig");
const arch = machine.arch;
const Machine = machine.Machine;

pub const Stats = struct {
    steps: u64 = 0,
    syscalls: u64 = 0,
    ok: u64 = 0,
    failed: u64 = 0,
    faults: u64 = 0,
    irqs: u64 = 0,
    timers: u64 = 0,
};

/// What a step did, for tracing.
pub const Step = struct { hart: u32, roll: u8, status: ?abi.Status = null };

pub fn step(m: *Machine, g: anytype, harts: u32, st: *Stats) !Step {
    var status: ?abi.Status = null;
    st.steps += 1;
    const hart = g.rng.uintLessThan(u32, harts);
    const roll = g.rng.uintLessThan(u8, 100);
    if (m.current(hart) != null and roll < 75) {
        st.syscalls += 1;
        status = try randomSyscall(m, g, hart);
        if (status.? == .ok) st.ok += 1 else st.failed += 1;
        if (m.k.exit_code != null) m.k.exit_code = null;
    } else if (m.current(hart) != null and roll < 80 and (m.current(hart) != m.root or g.chance(3))) {
        st.faults += 1;
        const kinds = [_]abi.FaultKind{ .load_page_fault, .store_page_fault, .illegal_instruction, .breakpoint };
        try m.fault(hart, .{ .kind = kinds[g.rng.uintLessThan(usize, kinds.len)], .addr = g.word(), .pc = 0x10000, .raw = 0 });
    } else if (roll < 85) {
        st.irqs += 1;
        m.k.handle(hart, m.now, .{ .irq = if (g.chance(95)) 1 + g.rng.uintLessThan(u32, 31) else g.rng.uintLessThan(u32, core.kernel.max_irqs + 8) });
        try m.check();
    } else if (roll < 88) {
        m.k.handle(hart, m.now, .ipi);
        try m.check();
    } else {
        // Time passes: up to the next deadline on this hart, or a little.
        const dt = 1 + g.rng.uintLessThan(u64, 3_000);
        st.timers += @intFromBool(arch.timer[hart] <= m.now + dt);
        try m.advance(hart, dt);
    }
    // Deliver IPIs the kernel asked for.
    var kicks = m.k.takeKicks();
    while (kicks != 0) {
        const h: u32 = @ctz(kicks);
        kicks &= kicks - 1;
        if (h < harts) {
            m.k.handle(h, m.now, .ipi);
            try m.check();
        }
    }
    return .{ .hart = hart, .roll = roll, .status = status };
}

/// Choices for one step, from `R`: a std.Random (the simulator) or a
/// fuzz source (anything with `uintLessThan` and `int`).
pub fn Gen(comptime R: type) type {
    return struct {
        rng: R,

        fn chance(g: @This(), percent: u8) bool {
            return g.rng.uintLessThan(u8, 100) < percent;
        }

        /// Slots: mostly ones in use, some empty, sometimes nonsense.
        fn slot(g: @This()) u64 {
            const r = g.rng.uintLessThan(u8, 100);
            if (r < 30) return g.rng.uintLessThan(u64, 10);
            if (r < 45) return abi.RootSlot.first_untyped + g.rng.uintLessThan(u64, 3);
            if (r < 95) return 100 + g.rng.uintLessThan(u64, 60);
            return g.rng.int(u64);
        }

        fn word(g: @This()) u64 {
            const r = g.rng.uintLessThan(u8, 100);
            if (r < 40) return g.rng.uintLessThan(u64, 16);
            if (r < 60) return g.slot();
            if (r < 75) return g.rng.uintLessThan(u64, 300) * 4096;
            if (r < 90) return g.rng.uintLessThan(u64, 50_000);
            return g.rng.int(u64);
        }

        fn rights(g: @This()) u64 {
            return if (g.chance(30)) abi.Rights.all.bits() else g.rng.uintLessThan(u64, 1 << 10);
        }
    };
}

fn kindBits(g: anytype, kind: abi.Kind) u64 {
    return switch (kind) {
        .untyped => 12 + g.rng.uintLessThan(u64, 6),
        .cnode => 1 + g.rng.uintLessThan(u64, 8),
        .frame => if (g.chance(95)) 12 else 21,
        .page_table => g.rng.uintLessThan(u64, 3),
        else => 0,
    };
}

/// Act as the current thread on `hart`. The root task is the system's
/// lifeline, so it avoids destroying itself (except, rarely, on purpose);
/// workers do anything, including blocking forever and faulting.
fn randomSyscall(m: *Machine, g: anytype, hart: u32) !abi.Status {
    const is_root = m.current(hart) == m.root;
    var w: [5]u64 = undefined;
    for (&w) |*x| x.* = g.word();
    const tag: abi.Tag = .{ .label = g.rng.uintLessThan(u32, 4), .length = g.rng.uintLessThan(u7, 8), .caps = g.rng.uintLessThan(u3, 2) };
    const roll = g.rng.uintLessThan(u8, 100);
    const t = blk: {
        if (g.chance(2)) {
            // Anything at all in the registers, any system-call number.
            const t0 = m.current(hart).?;
            const regs = [_]core.kernel.Reg{ .a0, .a1, .a2, .a3, .a4, .a5, .a6 };
            for (regs) |r| t0.ctx.set(r, g.word());
            t0.ctx.set(.a7, if (g.chance(50)) g.rng.uintLessThan(u64, 32) else g.rng.int(u64));
            m.k.handle(hart, m.now, .syscall);
            try m.check();
            break :blk if (m.current(hart) == t0) t0 else null;
        }
        if (roll < 25) {
            const kinds = [_]abi.Kind{ .endpoint, .signal, .thread, .frame, .page_table, .sched_context, .lease, .cnode, .untyped };
            const kind = kinds[g.rng.uintLessThan(usize, kinds.len)];
            const ut = if (g.chance(85)) abi.RootSlot.first_untyped + g.rng.uintLessThan(u64, 2) else g.slot();
            break :blk try m.sys(hart, .invoke, ut, @backingInt(abi.UntypedMethod.retype), &.{ @backingInt(kind), kindBits(g, kind), 100 + g.rng.uintLessThan(u64, 60) });
        }
        if (roll < 45) {
            var target = g.slot();
            const method = 1 + g.rng.uintLessThan(u64, 10);
            // Slots below 100 hold the root's own objects and its untyped
            // regions; mostly only look at them.
            if (target < 100 and !g.chance(2)) {
                target = if (g.chance(50)) 100 + g.rng.uintLessThan(u64, 60) else abi.RootSlot.cnode;
                if (target == abi.RootSlot.cnode) {
                    const cm = [_]abi.CNodeMethod{ .identify, .lease_info, .mint, .revoke, .delete, .move };
                    const mm = cm[g.rng.uintLessThan(usize, cm.len)];
                    // CNode operations only on the scratch slots 100..159.
                    const a = 100 + g.rng.uintLessThan(u64, 60);
                    const b = if (g.chance(70)) 100 + g.rng.uintLessThan(u64, 60) else g.slot();
                    break :blk try m.sys(hart, .invoke, target, @backingInt(mm), &.{ a, b, g.rights(), if (g.chance(30)) g.rng.uintLessThan(u64, 16) else 0, if (g.chance(30)) 1 + g.rng.uintLessThan(u64, 3) else 0 });
                }
            }
            if (target == abi.RootSlot.debug_console) break :blk try m.sys(hart, .yield, 0, 0, &.{});
            const args = [_]u64{ g.word(), g.word(), g.rights(), g.word(), g.word() };
            break :blk try m.sys(hart, .invoke, target, method, &args);
        }
        if (roll < 60) {
            // Spawn a worker: thread + scheduling context, configured and resumed.
            const ts = 100 + g.rng.uintLessThan(u64, 60);
            const sc = 100 + g.rng.uintLessThan(u64, 60);
            const ut = abi.RootSlot.first_untyped;
            _ = try m.sys(hart, .invoke, ut, @backingInt(abi.UntypedMethod.retype), &.{ @backingInt(abi.Kind.thread), 0, ts });
            if (m.current(hart) == null) break :blk null;
            _ = try m.sys(hart, .invoke, ut, @backingInt(abi.UntypedMethod.retype), &.{ @backingInt(abi.Kind.sched_context), 0, sc });
            if (m.current(hart) == null) break :blk null;
            const fault_ep = if (g.chance(50)) 100 + g.rng.uintLessThan(u64, 60) else 0;
            _ = try m.sys(hart, .invoke, ts, @backingInt(abi.ThreadMethod.configure), &.{ abi.RootSlot.cnode, abi.RootSlot.vspace, fault_ep });
            if (m.current(hart) == null) break :blk null;
            _ = try m.sys(hart, .invoke, ts, @backingInt(abi.ThreadMethod.set_priority), &.{100 + g.rng.uintLessThan(u64, 150)});
            if (m.current(hart) == null) break :blk null;
            const period = 1_000 + g.rng.uintLessThan(u64, 20_000);
            _ = try m.sys(hart, .invoke, abi.RootSlot.sched_control, @backingInt(abi.SchedControlMethod.configure), &.{ sc, 1 + g.rng.uintLessThan(u64, period), period, g.rng.uintLessThan(u64, m.k.hart_count) });
            if (m.current(hart) == null) break :blk null;
            if (g.chance(80)) {
                _ = try m.sys(hart, .invoke, ts, @backingInt(abi.ThreadMethod.bind_sched), &.{sc});
                if (m.current(hart) == null) break :blk null;
            }
            break :blk try m.sys(hart, .invoke, ts, @backingInt(abi.ThreadMethod.resume_thread), &.{});
        }
        if (roll < 63) break :blk try m.sys(hart, .yield, 0, 0, &.{});
        // IPC. The root blocks rarely; workers often.
        const blocking = [_]abi.Syscall{ .call, .recv, .reply_recv, .wait, .send };
        const quick = [_]abi.Syscall{ .signal, .poll };
        const c = if (!is_root or g.chance(15)) blocking[g.rng.uintLessThan(usize, blocking.len)] else quick[g.rng.uintLessThan(usize, quick.len)];
        const slot = if (g.chance(80)) 100 + g.rng.uintLessThan(u64, 60) else g.slot();
        break :blk try m.sys(hart, c, slot, @as(usize, @bitCast(tag)), &w);
    };
    if (t) |th| return @fromBackingInt(@intCast(th.ctx.get(.a0)));
    return .ok;
}
