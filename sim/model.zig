//! caravan-model: an exhaustive check of IPC and revocation on the real
//! kernel core.
//!
//! A scenario sets up a few objects and threads, one thread per hart, each
//! with a short script of system calls (the root task is one of them, on
//! hart 0). The kernel runs every system call atomically under its lock,
//! so a run of the scenario is an order of those calls. The checker tries
//! every order: depth first, snapshotting the whole machine (kernel state
//! and RAM) at each branch and restoring it to try the next, and skipping
//! states it has already seen (by a hash of kernel state, RAM and the
//! scripts' progress).
//!
//! In every state reached it checks the kernel's invariants and the
//! scenario's safety property (for example: a call made after a revoke
//! finished fails). In every final state (no thread can act) it checks
//! liveness: every thread finished its script, except those allowed to
//! wait forever (a server in `recv`) or to be destroyed. A violation prints
//! the order of calls that led to it.
//!
//!   caravan-model [--scenario NAME] [--verbose]
const std = @import("std");
const abi = @import("abi");
const core = @import("core");
const machine = @import("machine.zig");
const arch = machine.arch;
const Machine = machine.Machine;
const Thread = machine.Thread;
const S = abi.RootSlot;

const max_actors = 4;
const max_depth = 48;
const ram_size = 4 << 20;

// ---------------------------------------------------------------------------
// Scenarios

const Op = struct {
    call: abi.Syscall,
    slot: u64,
    /// For `.invoke`: the method; else the tag.
    method: u32 = 0,
    args: [3]u64 = @splat(0),
    /// Statuses this operation may end with; any other is a violation.
    allowed: []const abi.Status = &.{.ok},
    name: []const u8,
};

const Actor = struct {
    name: []const u8,
    /// The thread's slot in the root's CSpace (0: the root task itself).
    slot: u64 = 0,
    script: []const Op,
    /// May end blocked in a receive (a server waiting for more).
    may_wait: bool = false,
    /// May be destroyed by another actor.
    may_die: bool = false,
};

const Scenario = struct {
    name: []const u8,
    doc: []const u8,
    setup: *const fn (*Machine) anyerror!void,
    actors: []const Actor,
    /// Called after every completed operation, with the history so far.
    safety: ?*const fn (*const World) ?[]const u8 = null,
};

const E = 100; // an endpoint
const E_copy = 101; // a send-only, badged copy of it
const Sig = 102; // a signal
const L = 103; // a lease on the endpoint
const L_copy = 104; // a copy of the lease
const U = 105; // a small untyped region things die with
const E_mortal = 106; // an endpoint made from U
const E_mortal_copy = 107;

const send_only: abi.Rights = .{ .send = true };
const tag1: u64 = @bitCast(abi.Tag{ .label = 1, .length = 1 });
const any_end = &[_]abi.Status{ .ok, .invalid_cap, .aborted };

fn op(call: abi.Syscall, slot: u64, allowed: []const abi.Status, name: []const u8) Op {
    return .{ .call = call, .slot = slot, .method = @truncate(tag1), .allowed = allowed, .name = name };
}

fn invoke(slot: u64, method: anytype, args: [3]u64, allowed: []const abi.Status, name: []const u8) Op {
    return .{ .call = .invoke, .slot = slot, .method = @backingInt(method), .args = args, .allowed = allowed, .name = name };
}

/// A server on its own hart: receive, then reply-and-receive `n` times.
fn server(comptime ep: u64, comptime n: usize) []const Op {
    comptime {
        var ops: [n + 1]Op = undefined;
        // A revoke wakes a thread waiting on the endpoint with `aborted` (§2.3).
        ops[0] = op(.recv, ep, any_end, "recv");
        for (1..n + 1) |i| ops[i] = op(.reply_recv, ep, any_end, "reply_recv");
        const out = ops;
        return &out;
    }
}

const scenarios = [_]Scenario{
    .{
        .name = "call_reply_revoke",
        .doc = "A client calls twice through a badged copy while the root revokes the copies. Calls made after the revoke fail; no call hangs.",
        .setup = setupEndpoint,
        .actors = &.{
            .{ .name = "root", .script = &.{invoke(S.cnode, abi.CNodeMethod.revoke, .{ E, 0, 0 }, &.{.ok}, "revoke(E)")} },
            .{ .name = "server", .slot = 110, .script = server(E, 2), .may_wait = true },
            .{ .name = "client", .slot = 111, .script = &.{ op(.call, E_copy, any_end, "call"), op(.call, E_copy, any_end, "call") } },
        },
        .safety = afterRevokeCallsFail,
    },
    .{
        .name = "server_destroyed",
        .doc = "A server and its endpoint, made from a region the root resets (as Steward does when a domain stops), at any point of a call. Every call ends, with an answer or an error; none hangs.",
        .setup = setupMortalServer,
        .actors = &.{
            .{ .name = "root", .script = &.{invoke(U, abi.UntypedMethod.reset, .{ 0, 0, 0 }, &.{.ok}, "reset(U)")} },
            .{ .name = "server", .slot = 110, .script = server(E_mortal, 2), .may_wait = true, .may_die = true },
            .{ .name = "client", .slot = 111, .script = &.{ op(.call, E_mortal_copy, any_end, "call"), op(.call, E_mortal_copy, any_end, "call") } },
        },
    },
    .{
        .name = "endpoint_destroyed",
        .doc = "Clients queued on an endpoint nobody serves while the root destroys the endpoint: every queued call is released with an error.",
        .setup = setupMortalEndpoint,
        .actors = &.{
            .{ .name = "root", .script = &.{invoke(U, abi.UntypedMethod.reset, .{ 0, 0, 0 }, &.{.ok}, "reset(U)")} },
            .{ .name = "client_a", .slot = 110, .script = &.{op(.call, E_mortal_copy, &.{ .invalid_cap, .aborted }, "call")} },
            .{ .name = "client_b", .slot = 111, .script = &.{op(.call, E_mortal_copy, &.{ .invalid_cap, .aborted }, "call")} },
        },
    },
    .{
        .name = "lease_uses",
        .doc = "Two clients race to use a lease good for two uses. At most two calls get through; the rest are refused; nobody hangs.",
        .setup = setupLease,
        .actors = &.{
            .{ .name = "root", .script = &.{} },
            .{ .name = "server", .slot = 110, .script = server(E, 4), .may_wait = true },
            .{ .name = "client_a", .slot = 111, .script = &.{ op(.call, L_copy, &.{ .ok, .lease_exhausted }, "call"), op(.call, L_copy, &.{ .ok, .lease_exhausted }, "call") } },
            .{ .name = "client_b", .slot = 112, .script = &.{ op(.call, L_copy, &.{ .ok, .lease_exhausted }, "call"), op(.call, L_copy, &.{ .ok, .lease_exhausted }, "call") } },
        },
        .safety = leaseUsesBounded,
    },
    .{
        .name = "lease_revoked",
        .doc = "The root revokes a lease while a client uses it. Uses that start after the revoke fail; nobody hangs.",
        .setup = setupLeaseOneClient,
        .actors = &.{
            .{ .name = "root", .script = &.{invoke(S.cnode, abi.CNodeMethod.revoke, .{ L, 0, 0 }, &.{.ok}, "revoke(L)")} },
            .{ .name = "server", .slot = 110, .script = server(E, 2), .may_wait = true },
            .{ .name = "client", .slot = 111, .script = &.{ op(.call, L_copy, any_end, "call"), op(.call, L_copy, any_end, "call") } },
        },
        .safety = afterRevokeCallsFail,
    },
    .{
        .name = "revoke_then_reset",
        .doc = "Two clients call a server while the root first revokes the server's endpoint, then destroys the server and the endpoint with their region. No call issued after the revoke succeeds; every call ends.",
        .setup = setupMortalServerTwoClients,
        .actors = &.{
            .{ .name = "root", .script = &.{ invoke(S.cnode, abi.CNodeMethod.revoke, .{ E_mortal, 0, 0 }, &.{.ok}, "revoke(E)"), invoke(U, abi.UntypedMethod.reset, .{ 0, 0, 0 }, &.{.ok}, "reset(U)") } },
            .{ .name = "server", .slot = 110, .script = server(E_mortal, 4), .may_wait = true, .may_die = true },
            .{ .name = "client_a", .slot = 111, .script = &.{ op(.call, E_mortal_copy, any_end, "call"), op(.call, E_mortal_copy, any_end, "call") } },
            .{ .name = "client_b", .slot = 112, .script = &.{ op(.call, E_mortal_copy, any_end, "call"), op(.call, E_mortal_copy, any_end, "call") } },
        },
        .safety = afterRevokeCallsFail,
    },
    .{
        .name = "signal_and_message",
        .doc = "A server with a bound signal receives while the root signals and a client calls. It gets both, in either order; the client is answered.",
        .setup = setupBound,
        .actors = &.{
            .{ .name = "root", .script = &.{op(.signal, Sig, &.{.ok}, "signal")} },
            .{ .name = "server", .slot = 110, .script = &.{ op(.recv, E, &.{.ok}, "recv"), op(.recv, E, &.{.ok}, "recv"), op(.reply_recv, E, &.{.ok}, "reply_recv") }, .may_wait = true },
            .{ .name = "client", .slot = 111, .script = &.{op(.call, E_copy, &.{.ok}, "call")} },
        },
    },
};

// ---------------------------------------------------------------------------
// Setup

fn ok(r: machine.Result) !void {
    if (r.status != .ok) return error.SetupFailed;
}

fn retype(m: *Machine, from: u64, kind: abi.Kind, bits: u64, dest: u64) !void {
    try ok(try m.invoke(0, from, abi.UntypedMethod.retype, &.{ @backingInt(kind), bits, dest }));
}

/// A thread sharing the root's spaces, alone on `hart` with a full budget.
fn spawn(m: *Machine, from: u64, slot: u64, hart: u64) !void {
    try retype(m, from, .thread, 0, slot);
    try ok(try m.invoke(0, slot, abi.ThreadMethod.configure, &.{ S.cnode, S.vspace, 0 }));
    try ok(try m.invoke(0, slot, abi.ThreadMethod.set_priority, &.{200}));
    try retype(m, from, .sched_context, 0, slot + 10);
    try ok(try m.invoke(0, S.sched_control, abi.SchedControlMethod.configure, &.{ slot + 10, 10_000, 10_000, hart }));
    try ok(try m.invoke(0, slot, abi.ThreadMethod.bind_sched, &.{slot + 10}));
    try ok(try m.invoke(0, slot, abi.ThreadMethod.resume_thread, &.{}));
}

fn setupEndpoint(m: *Machine) !void {
    try retype(m, S.first_untyped, .endpoint, 0, E);
    try ok(try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ E_copy, E, send_only.bits(), 7 }));
    try spawn(m, S.first_untyped, 110, 1);
    try spawn(m, S.first_untyped, 111, 2);
}

fn setupMortalServer(m: *Machine) !void {
    try retype(m, S.first_untyped, .untyped, 16, U);
    try retype(m, U, .endpoint, 0, E_mortal);
    try ok(try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ E_mortal_copy, E_mortal, send_only.bits(), 7 }));
    try spawn(m, U, 110, 1);
    try spawn(m, S.first_untyped, 111, 2);
}

fn setupMortalServerTwoClients(m: *Machine) !void {
    try setupMortalServer(m);
    try spawn(m, S.first_untyped, 112, 3);
}

fn setupMortalEndpoint(m: *Machine) !void {
    try retype(m, S.first_untyped, .untyped, 16, U);
    try retype(m, U, .endpoint, 0, E_mortal);
    try ok(try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ E_mortal_copy, E_mortal, send_only.bits(), 7 }));
    try spawn(m, S.first_untyped, 110, 1);
    try spawn(m, S.first_untyped, 111, 2);
}

fn setupLease(m: *Machine) !void {
    try retype(m, S.first_untyped, .endpoint, 0, E);
    try retype(m, S.first_untyped, .lease, 0, L);
    try ok(try m.invoke(0, L, abi.LeaseMethod.arm, &.{ E, send_only.bits(), 0, 2 }));
    try ok(try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ L_copy, L, send_only.bits(), 0 }));
    try spawn(m, S.first_untyped, 110, 1);
    try spawn(m, S.first_untyped, 111, 2);
    try spawn(m, S.first_untyped, 112, 3);
}

fn setupLeaseOneClient(m: *Machine) !void {
    try retype(m, S.first_untyped, .endpoint, 0, E);
    try retype(m, S.first_untyped, .lease, 0, L);
    try ok(try m.invoke(0, L, abi.LeaseMethod.arm, &.{ E, send_only.bits(), 0, 0 }));
    try ok(try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ L_copy, L, send_only.bits(), 0 }));
    try spawn(m, S.first_untyped, 110, 1);
    try spawn(m, S.first_untyped, 111, 2);
}

fn setupBound(m: *Machine) !void {
    try retype(m, S.first_untyped, .endpoint, 0, E);
    try ok(try m.invoke(0, S.cnode, abi.CNodeMethod.mint, &.{ E_copy, E, send_only.bits(), 7 }));
    try retype(m, S.first_untyped, .signal, 0, Sig);
    try spawn(m, S.first_untyped, 110, 1);
    try spawn(m, S.first_untyped, 111, 2);
    // The server binds the signal to itself, then the scripts start.
    try ok(try m.invoke(0, 110, abi.ThreadMethod.bind_signal, &.{Sig}));
}

// ---------------------------------------------------------------------------
// Properties

/// Every call issued after the root's revoke finished fails.
fn afterRevokeCallsFail(w: *const World) ?[]const u8 {
    var revoked_at: ?usize = null;
    for (w.history[0..w.history_len], 0..) |e, i| {
        if (e.actor == 0 and e.completed and e.status == .ok and std.mem.startsWith(u8, e.name, "revoke") and revoked_at == null) revoked_at = i;
    }
    const at = revoked_at orelse return null;
    for (w.history[0..w.history_len]) |e| {
        if (e.actor == 0 or !e.completed or e.status != .ok) continue;
        if (std.mem.eql(u8, e.name, "call") and e.issued_seq > w.history[at].seq) return "a call issued after the revoke finished succeeded";
    }
    return null;
}

/// A lease good for two uses lets at most two calls through.
fn leaseUsesBounded(w: *const World) ?[]const u8 {
    var used: usize = 0;
    for (w.history[0..w.history_len]) |e| {
        if (e.completed and e.status == .ok and std.mem.eql(u8, e.name, "call")) used += 1;
    }
    return if (used > 2) "more calls got through a lease than it has uses" else null;
}

// ---------------------------------------------------------------------------
// The checker

const Event = struct {
    actor: u8,
    name: []const u8,
    completed: bool,
    status: abi.Status = .ok,
    /// Order of the event, and (for completions) of the issue it completes.
    seq: usize,
    issued_seq: usize,
};

const World = struct {
    m: Machine,
    sc: *const Scenario,
    threads: [max_actors]*Thread = undefined,
    harts: u32 = 1,
    pos: [max_actors]u8 = @splat(0),
    pending: [max_actors]bool = @splat(false),
    issued_seq: [max_actors]usize = @splat(0),
    history: [2 * max_depth]Event = undefined,
    history_len: usize = 0,
    seq: usize = 0,
    /// The actor chosen at each step, for printing a counterexample.
    path: [max_depth]u8 = undefined,
    depth: usize = 0,

    fn thread(w: *const World, a: usize) *Thread {
        return w.threads[a];
    }

    fn alive(w: *const World, a: usize) bool {
        const t = w.thread(a);
        const e = w.m.k.table[t.id];
        return e.kind == .thread;
    }

    fn running(w: *const World, a: usize) bool {
        return w.alive(a) and w.m.current(@intCast(a)) == w.thread(a);
    }

    fn enabled(w: *const World, a: usize) bool {
        return !w.pending[a] and w.pos[a] < w.sc.actors[a].script.len and w.running(a);
    }

    fn record(w: *World, e: Event) void {
        w.history[w.history_len] = e;
        w.history_len += 1;
    }

    /// Issue actor `a`'s next operation, deliver the IPIs it caused, and
    /// collect every operation that completed.
    fn step(w: *World, a: usize) !void {
        const o = w.sc.actors[a].script[w.pos[a]];
        w.seq += 1;
        w.issued_seq[a] = w.seq;
        w.record(.{ .actor = @intCast(a), .name = o.name, .completed = false, .seq = w.seq, .issued_seq = w.seq });
        w.pending[a] = true;
        const a1: u64 = if (o.call == .invoke) o.method else tag1;
        _ = try w.m.sys(@intCast(a), o.call, o.slot, a1, &o.args);
        var kicks = w.m.k.takeKicks();
        while (kicks != 0) {
            const h: u32 = @ctz(kicks);
            kicks &= kicks - 1;
            if (h < w.harts) {
                w.m.k.handle(h, w.m.now, .ipi);
                try w.m.check();
            }
        }
        try w.collect();
    }

    fn collect(w: *World) !void {
        for (0..w.sc.actors.len) |b| {
            if (!w.pending[b] or !w.running(b)) continue;
            const r = Machine.result(w.thread(b));
            const o = w.sc.actors[b].script[w.pos[b]];
            w.seq += 1;
            w.record(.{ .actor = @intCast(b), .name = o.name, .completed = true, .status = r.status, .seq = w.seq, .issued_seq = w.issued_seq[b] });
            w.pending[b] = false;
            w.pos[b] += 1;
            if (std.mem.indexOfScalar(abi.Status, o.allowed, r.status) == null) return w.fail("an operation ended with a status it may not have");
        }
        if (w.sc.safety) |f| if (f(w)) |msg| return w.fail(msg);
    }

    fn final(w: *World) !void {
        for (w.sc.actors, 0..) |ac, a| {
            if (w.pos[a] == ac.script.len) continue;
            if (!w.alive(a)) {
                if (ac.may_die) continue;
                return w.fail("a thread was destroyed that should not have been");
            }
            // A server may wait forever in any receive once nobody calls.
            const waiting = ac.script[w.pos[a]].call;
            if (w.pending[a] and ac.may_wait and (waiting == .recv or waiting == .reply_recv or waiting == .wait)) continue;
            return w.fail("a thread is stuck (no thread can act and it has not finished)");
        }
    }

    var failure: ?[]const u8 = null;

    fn fail(w: *World, msg: []const u8) error{PropertyViolated} {
        failure = msg;
        w.printTrace();
        return error.PropertyViolated;
    }

    fn printTrace(w: *const World) void {
        std.debug.print("@model violation scenario={s}\n", .{w.sc.name});
        for (w.history[0..w.history_len]) |e| {
            const who = w.sc.actors[e.actor].name;
            if (e.completed)
                std.debug.print("  {s}: {s} -> {s}\n", .{ who, e.name, @tagName(e.status) })
            else
                std.debug.print("  {s}: {s} ...\n", .{ who, e.name });
        }
    }

    fn hash(w: *const World) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.sliceAsBytes(w.m.k.table));
        h.update(arch.ram);
        for (w.m.k.harts[0..w.harts]) |hart| {
            h.update(std.mem.asBytes(&hart.current));
            h.update(std.mem.sliceAsBytes(&hart.run_head));
            h.update(std.mem.sliceAsBytes(&hart.run_tail));
            h.update(std.mem.sliceAsBytes(&hart.bitmap));
            h.update(std.mem.asBytes(&hart.release_head));
            h.update(std.mem.asBytes(&hart.timer_deadline));
            h.update(&.{@intFromBool(hart.rotate)});
        }
        h.update(std.mem.sliceAsBytes(&w.pos));
        h.update(std.mem.sliceAsBytes(&w.pending));
        return h.final();
    }
};

/// Everything a step can change, to go back after exploring a branch.
const Snapshot = struct {
    kernel: []u8,
    ram: []u8,
    timer: [arch.max_harts]u64,
    irq_masked: [core.kernel.max_irqs]bool,
    world: World,

    fn init(gpa: std.mem.Allocator) !Snapshot {
        return .{ .kernel = try gpa.alloc(u8, @sizeOf(machine.K)), .ram = try gpa.alloc(u8, ram_size), .timer = undefined, .irq_masked = undefined, .world = undefined };
    }

    fn save(s: *Snapshot, w: *const World) void {
        @memcpy(s.kernel, std.mem.asBytes(w.m.k));
        @memcpy(s.ram, arch.ram);
        s.timer = arch.timer;
        s.irq_masked = arch.irq_masked;
        s.world = w.*;
    }

    fn restore(s: *const Snapshot, w: *World) void {
        @memcpy(std.mem.asBytes(w.m.k), s.kernel);
        @memcpy(arch.ram, s.ram);
        arch.timer = s.timer;
        arch.irq_masked = s.irq_masked;
        w.* = s.world;
    }
};

const Stats = struct { states: u64 = 0, transitions: u64 = 0, finals: u64 = 0, max_depth: usize = 0 };

const Checker = struct {
    w: World,
    visited: std.AutoHashMap(u64, void),
    gpa: std.mem.Allocator,
    /// One per depth, made when first reached.
    snaps: [max_depth]?Snapshot = @splat(null),
    stats: Stats = .{},

    fn snap(c: *Checker, depth: usize) !*Snapshot {
        if (c.snaps[depth] == null) c.snaps[depth] = try Snapshot.init(c.gpa);
        return &c.snaps[depth].?;
    }

    fn explore(c: *Checker) !void {
        const w = &c.w;
        const h = w.hash();
        if ((try c.visited.getOrPut(h)).found_existing) return;
        c.stats.states += 1;
        c.stats.max_depth = @max(c.stats.max_depth, w.depth);
        var any = false;
        for (0..w.sc.actors.len) |a| {
            if (!w.enabled(a)) continue;
            any = true;
            if (w.depth == max_depth) return error.TooDeep;
            (try c.snap(w.depth)).save(w);
            w.path[w.depth] = @intCast(a);
            w.depth += 1;
            c.stats.transitions += 1;
            try w.step(a);
            try c.explore();
            c.snaps[w.depth - 1].?.restore(w);
        }
        if (!any) {
            c.stats.finals += 1;
            try w.final();
        }
    }
};

fn checkScenario(gpa: std.mem.Allocator, sc: *const Scenario, verbose: bool) !Stats {
    const harts: u32 = @intCast(sc.actors.len);
    var m = try Machine.boot(harts, ram_size);
    defer m.deinit();
    try sc.setup(&m);
    var c: Checker = .{ .w = .{ .m = m, .sc = sc, .harts = harts }, .visited = .init(gpa), .gpa = gpa };
    defer c.visited.deinit();
    defer for (&c.snaps) |*s| if (s.*) |x| {
        gpa.free(x.kernel);
        gpa.free(x.ram);
    };
    c.w.threads[0] = m.root;
    for (sc.actors[1..], 1..) |ac, a| {
        const id = (try m.invoke(0, S.cnode, abi.CNodeMethod.identify, &.{ac.slot})).words[4];
        c.w.threads[a] = m.k.thread(@intCast(id));
    }
    // Let the spawned threads take their harts.
    for (1..harts) |h| m.k.handle(@intCast(h), m.now, .ipi);
    try m.check();
    c.explore() catch |e| {
        if (verbose) std.debug.print("@model scenario={s} error={s}\n", .{ sc.name, @errorName(e) });
        return e;
    };
    return c.stats;
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var only: ?[]const u8 = null;
    var verbose = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--scenario") and i + 1 < args.len) {
            only = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--verbose")) {
            verbose = true;
        } else {
            std.debug.print("usage: caravan-model [--scenario NAME] [--verbose]\n", .{});
            return error.InvalidArgument;
        }
    }
    var total: Stats = .{};
    var n: usize = 0;
    for (&scenarios) |*sc| {
        if (only) |o| if (!std.mem.eql(u8, o, sc.name)) continue;
        const st = checkScenario(gpa, sc, verbose) catch |e| {
            std.debug.print("@model result=fail scenario={s} error={s} reason=\"{s}\"\n", .{ sc.name, @errorName(e), World.failure orelse "" });
            std.process.exit(1);
        };
        std.debug.print("@model scenario={s} result=pass states={d} transitions={d} finals={d} depth={d}\n", .{ sc.name, st.states, st.transitions, st.finals, st.max_depth });
        total.states += st.states;
        n += 1;
    }
    std.debug.print("@model result=pass scenarios={d} states={d}\n", .{ n, total.states });
}
