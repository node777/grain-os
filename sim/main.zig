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
const driver = @import("driver.zig");

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
    d: driver.Stats = .{},
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
                seed, a.d.steps, a.d.syscalls, a.d.ok, a.d.failed, a.d.faults, a.d.irqs, a.d.timers, a.reboots, a.hash,
            });
        total.d.steps += a.d.steps;
        total.d.syscalls += a.d.syscalls;
        total.d.ok += a.d.ok;
    }
    std.debug.print("@sim result=pass seeds={d} steps={d} syscalls={d} ok={d} harts={d}\n", .{ last - first + 1, total.d.steps, total.d.syscalls, total.d.ok, opts.harts });
}

fn runSeed(seed: u64, opts: Options) !RunStats {
    var prng = std.Random.DefaultPrng.init(seed);
    const g: driver.Gen(std.Random) = .{ .rng = prng.random() };
    var m = try Machine.boot(opts.harts, 16 * 1024 * 1024);
    defer m.deinit();
    var st: RunStats = .{};
    var epoch_hash: u64 = 0;

    var step: u64 = 0;
    while (step < opts.steps) : (step += 1) {
        const done = driver.step(&m, g, opts.harts, &st.d) catch |e| return report(seed, step, e);
        if (opts.trace) std.debug.print("step={d} hart={d} roll={d} status={s} now={d} hash=0x{x}\n", .{ step, done.hart, done.roll, if (done.status) |x| @tagName(x) else "-", m.now, stateHash(&m, seed, opts.harts) });
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
