//! caravan-sim: deterministic simulation of the kernel core.
//!
//! Boots the real kernel core on a simulated machine and throws seeded
//! random events at it: system calls with plausible and garbage arguments,
//! faults, interrupts, IPIs and the passage of time. After every step it
//! checks the kernel's invariants. A failure prints the seed and step, and
//! `--seed N` replays it exactly. Each seed also runs twice to check that the
//! final state is bit-for-bit identical.
//!
//!   caravan-sim [--seed N | --seeds N] [--steps N] [--harts N] [--verbose]
const std = @import("std");
const abi = @import("abi");
const core = @import("core");
const machine = @import("machine.zig");
const arch = machine.arch;
const Machine = machine.Machine;

const Options = struct {
    seed: ?u64 = null,
    seeds: u64 = 16,
    steps: u64 = 50_000,
    harts: u32 = 2,
    verbose: bool = false,
    /// Print every step (use with --seed to replay a failure).
    trace: bool = false,
};

const RunStats = struct {
    steps: u64 = 0,
    syscalls: u64 = 0,
    ok: u64 = 0,
    failed: u64 = 0,
    faults: u64 = 0,
    irqs: u64 = 0,
    timers: u64 = 0,
    /// Times the machine went quiet (nothing runnable, no timers) and was rebooted.
    reboots: u64 = 0,
    hash: u64 = 0,
};

pub fn main(init: std.process.Init) !void {
    var opts: Options = .{};
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--seed")) {
            opts.seed = try std.fmt.parseInt(u64, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--seeds")) {
            opts.seeds = try std.fmt.parseInt(u64, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--steps")) {
            opts.steps = try std.fmt.parseInt(u64, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--harts")) {
            opts.harts = try std.fmt.parseInt(u32, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--trace")) {
            opts.trace = true;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            opts.verbose = true;
        } else {
            std.debug.print("unknown argument: {s}\n", .{a});
            return error.InvalidArgument;
        }
    }

    const first: u64 = opts.seed orelse 1;
    const last: u64 = if (opts.seed) |s| s else opts.seeds;
    var seed = first;
    var total: RunStats = .{};
    while (seed <= last) : (seed += 1) {
        const a = runSeed(seed, opts) catch |e| {
            std.debug.print("@sim result=fail seed={d} error={s}\n", .{ seed, @errorName(e) });
            std.process.exit(1);
        };
        const b = try runSeed(seed, opts);
        if (a.hash != b.hash) {
            std.debug.print("@sim result=fail seed={d} error=nondeterministic hash_a=0x{x} hash_b=0x{x}\n", .{ seed, a.hash, b.hash });
            std.process.exit(1);
        }
        if (opts.verbose or opts.seed != null)
            std.debug.print("@sim seed={d} steps={d} syscalls={d} ok={d} failed={d} faults={d} irqs={d} timers={d} reboots={d} hash=0x{x}\n", .{
                seed, a.steps, a.syscalls, a.ok, a.failed, a.faults, a.irqs, a.timers, a.reboots, a.hash,
            });
        total.steps += a.steps;
        total.syscalls += a.syscalls;
        total.ok += a.ok;
    }
    std.debug.print("@sim result=pass seeds={d} steps={d} syscalls={d} ok={d} harts={d}\n", .{ last - first + 1, total.steps, total.syscalls, total.ok, opts.harts });
}

const Gen = struct {
    rng: std.Random,

    fn chance(g: Gen, percent: u8) bool {
        return g.rng.uintLessThan(u8, 100) < percent;
    }

    /// Slots: mostly ones in use, some empty, sometimes nonsense.
    fn slot(g: Gen) u64 {
        const r = g.rng.uintLessThan(u8, 100);
        if (r < 30) return g.rng.uintLessThan(u64, 10);
        if (r < 45) return abi.RootSlot.first_untyped + g.rng.uintLessThan(u64, 3);
        if (r < 95) return 100 + g.rng.uintLessThan(u64, 60);
        return g.rng.int(u64);
    }

    fn word(g: Gen) u64 {
        const r = g.rng.uintLessThan(u8, 100);
        if (r < 40) return g.rng.uintLessThan(u64, 16);
        if (r < 60) return g.slot();
        if (r < 75) return g.rng.uintLessThan(u64, 300) * 4096;
        if (r < 90) return g.rng.uintLessThan(u64, 50_000);
        return g.rng.int(u64);
    }

    fn rights(g: Gen) u64 {
        return if (g.chance(30)) abi.Rights.all.bits() else g.rng.uintLessThan(u64, 1 << 10);
    }
};

fn kindBits(g: Gen, kind: abi.Kind) u64 {
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
fn randomSyscall(m: *Machine, g: Gen, hart: u32) !abi.Status {
    const is_root = m.current(hart) == m.root;
    var w: [5]u64 = undefined;
    for (&w) |*x| x.* = g.word();
    const tag: abi.Tag = .{ .label = g.rng.uintLessThan(u32, 4), .length = g.rng.uintLessThan(u7, 8), .caps = g.rng.uintLessThan(u3, 2) };
    const roll = g.rng.uintLessThan(u8, 100);
    const t = blk: {
        if (roll < 25) {
            const kinds = [_]abi.Kind{ .endpoint, .signal, .thread, .frame, .page_table, .sched_context, .lease, .cnode, .untyped };
            const kind = kinds[g.rng.uintLessThan(usize, kinds.len)];
            const ut = if (g.chance(85)) abi.RootSlot.first_untyped + g.rng.uintLessThan(u64, 2) else g.slot();
            break :blk try m.sys(hart, .invoke, ut, @backingInt(abi.UntypedMethod.retype), &.{ @backingInt(kind), kindBits(g, kind), 100 + g.rng.uintLessThan(u64, 60) });
        }
        if (roll < 45) {
            var target = g.slot();
            const method = 1 + g.rng.uintLessThan(u64, 9);
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

fn runSeed(seed: u64, opts: Options) !RunStats {
    var prng = std.Random.DefaultPrng.init(seed);
    const g: Gen = .{ .rng = prng.random() };
    var m = try Machine.boot(opts.harts, 16 * 1024 * 1024);
    defer m.deinit();
    var st: RunStats = .{};
    var epoch_hash: u64 = 0;

    var step: u64 = 0;
    while (step < opts.steps) : (step += 1) {
        st.steps += 1;
        const hart = g.rng.uintLessThan(u32, opts.harts);
        const roll = g.rng.uintLessThan(u8, 100);
        if (m.current(hart) != null and roll < 75) {
            st.syscalls += 1;
            const status = randomSyscall(&m, g, hart) catch |e| return report(seed, step, e);
            if (status == .ok) st.ok += 1 else st.failed += 1;
            if (opts.trace) std.debug.print("step={d} hart={d} syscall status={s} hash=0x{x}\n", .{ step, hart, @tagName(status), stateHash(&m, seed, opts.harts) });
            if (m.k.exit_code != null) m.k.exit_code = null;
        } else if (m.current(hart) != null and roll < 80 and (m.current(hart) != m.root or g.chance(3))) {
            st.faults += 1;
            const kinds = [_]abi.FaultKind{ .load_page_fault, .store_page_fault, .illegal_instruction, .breakpoint };
            m.fault(hart, .{ .kind = kinds[g.rng.uintLessThan(usize, kinds.len)], .addr = g.word(), .pc = 0x10000, .raw = 0 }) catch |e| return report(seed, step, e);
        } else if (roll < 85) {
            st.irqs += 1;
            m.k.handle(hart, m.now, .{ .irq = 1 + g.rng.uintLessThan(u32, 31) });
            m.check() catch |e| return report(seed, step, e);
        } else if (roll < 88) {
            m.k.handle(hart, m.now, .ipi);
            m.check() catch |e| return report(seed, step, e);
        } else {
            // Time passes: up to the next deadline on this hart, or a little.
            const dt = 1 + g.rng.uintLessThan(u64, 3_000);
            st.timers += @intFromBool(arch.timer[hart] <= m.now + dt);
            m.advance(hart, dt) catch |e| return report(seed, step, e);
        }
        if (opts.trace) std.debug.print("step={d} hart={d} roll={d} now={d} hash=0x{x}\n", .{ step, hart, roll, m.now, stateHash(&m, seed, opts.harts) });
        // Deliver IPIs the kernel asked for.
        var kicks = m.k.takeKicks();
        while (kicks != 0) {
            const h: u32 = @ctz(kicks);
            kicks &= kicks - 1;
            if (h < opts.harts) {
                m.k.handle(h, m.now, .ipi);
                m.check() catch |e| return report(seed, step, e);
            }
        }
        // If nothing can ever run again, fold this machine's state into the
        // hash and boot a fresh one.
        var any = false;
        for (0..opts.harts) |h| any = any or m.current(@intCast(h)) != null or arch.timer[h] != std.math.maxInt(u64);
        if (!any) {
            st.reboots += 1;
            epoch_hash = std.hash.Wyhash.hash(epoch_hash, std.mem.asBytes(&stateHash(&m, seed, opts.harts)));
            m.deinit();
            m = try Machine.boot(opts.harts, 16 * 1024 * 1024);
        }
    }
    st.hash = std.hash.Wyhash.hash(epoch_hash, std.mem.asBytes(&stateHash(&m, seed, opts.harts)));
    return st;
}

fn stateHash(m: *Machine, seed: u64, harts: u32) u64 {
    var hasher = std.hash.Wyhash.init(seed);
    hasher.update(std.mem.sliceAsBytes(m.k.table));
    hasher.update(arch.ram);
    for (m.k.harts[0..harts]) |h| hasher.update(std.mem.asBytes(&h.current));
    return hasher.final();
}

fn report(seed: u64, step: u64, e: anyerror) anyerror {
    std.debug.print("@sim result=fail seed={d} step={d} error={s}\n", .{ seed, step, @errorName(e) });
    std.debug.print("replay: zig build sim -Dseed={d}\n", .{seed});
    return e;
}
