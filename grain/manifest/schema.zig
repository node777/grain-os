//! The Grain system manifest: what a system is, as plain data.
//!
//! A manifest (`system/*.zon`) lists domains: each is one program with its
//! own memory, its own CPU budget, the services it provides, the services it
//! uses, and the devices it drives. Steward builds exactly this at boot.
//!
//! `validate` checks a manifest and explains the first problem in a sentence.
//! It runs at compile time inside Steward, so a miswired system does not
//! build, and at run time in host tests and tools.
const std = @import("std");

pub const Manifest = struct {
    /// A name for this system, reported at boot.
    name: []const u8,
    /// Power off once every task has finished (development and test systems).
    halt_when_tasks_finish: bool = false,
    domains: []const Domain,
    /// What an AI agent (or any client of Envoy) may do on this system.
    agent: ?Agent = null,
};

/// The agent's authority. It is never root: it holds exactly these services,
/// each as a kernel lease with optional limits, and may ask for the askable
/// ones. Steward approves asks on the owner's behalf within this policy.
pub const Agent = struct {
    /// The domain that speaks the Envoy protocol for the agent.
    envoy: []const u8,
    /// Services the agent holds from boot.
    grants: []const Grant = &.{},
    /// Services the agent may request, once each.
    askable: []const Grant = &.{},
};

pub const Grant = struct {
    /// The name the agent knows it by.
    name: []const u8,
    /// "<domain>.<service>"
    from: []const u8,
    protocol: []const u8,
    /// Calls allowed (0 = unlimited).
    uses: u32 = 0,
    /// Lifetime from boot or from approval, in milliseconds (0 = forever).
    duration_ms: u32 = 0,
};

pub const Kind = enum {
    /// Runs until stopped; may provide services.
    service,
    /// Runs to completion and reports an exit code.
    task,
};

pub const Restart = enum {
    never,
    /// Rebuild the domain from its image when it faults (up to max_restarts).
    on_fault,
};

pub const Domain = struct {
    name: []const u8,
    /// A program in the image (grain/programs/<program>/main.zig).
    program: []const u8,
    kind: Kind = .service,
    /// 1..254 (Steward runs at 255).
    priority: u8 = 100,
    hart: u8 = 0,
    /// CPU time per period; the default is a tenth of a hart.
    budget_us: u32 = 1_000,
    period_us: u32 = 10_000,
    /// Memory the domain may allocate from itself (a power of two, 4..65536 KiB).
    memory_kib: u32 = 64,
    restart: Restart = .never,
    max_restarts: u8 = 3,
    /// A write-only console for `@grain` records (development systems).
    debug_console: bool = false,
    provides: []const Provide = &.{},
    uses: []const Use = &.{},
    devices: []const Device = &.{},
};

pub const Provide = struct {
    name: []const u8,
    /// Interface name and version, e.g. "console.v1".
    protocol: []const u8,
};

pub const Use = struct {
    /// The name this domain knows the service by.
    name: []const u8,
    /// "<domain>.<service>"
    from: []const u8,
    /// Must equal the provider's protocol.
    protocol: []const u8,
};

pub const Device = struct {
    name: []const u8,
    /// virtio device id: 3 = console, 4 = entropy source.
    virtio: u32,
    /// Which device of that kind, counting from 0 in device-tree order.
    instance: u8 = 0,
    /// If the machine lacks it, the domain is skipped (`domain_skipped`), not
    /// failed: for hardware that is often absent, like a host agent port.
    optional: bool = false,
};

pub const max_domains = 16;
pub const max_provides = 8;
pub const max_uses = 8;
pub const max_devices = 4;
pub const max_name = 23;
pub const max_agent_caps = 16;
/// Steward keeps a tenth of every hart for itself and the kernel.
pub const max_hart_load_ppm = 900_000;

pub const known_virtio = [_]struct { id: u32, what: []const u8 }{
    .{ .id = 3, .what = "console" },
    .{ .id = 4, .what = "entropy source" },
};

const Fail = struct {
    buf: []u8,
    fn msg(f: Fail, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.bufPrint(f.buf, fmt, args) catch "manifest error (message too long)";
    }
};

fn isName(s: []const u8) bool {
    if (s.len == 0 or s.len > max_name) return false;
    for (s) |c| switch (c) {
        'a'...'z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

pub fn findDomain(m: Manifest, name: []const u8) ?usize {
    for (m.domains, 0..) |d, i| if (std.mem.eql(u8, d.name, name)) return i;
    return null;
}

pub const Target = struct { domain: usize, service: usize };

/// Resolve "<domain>.<service>".
pub fn resolveUse(m: Manifest, from: []const u8) ?Target {
    const dot = std.mem.indexOfScalar(u8, from, '.') orelse return null;
    const di = findDomain(m, from[0..dot]) orelse return null;
    for (m.domains[di].provides, 0..) |p, pi| if (std.mem.eql(u8, p.name, from[dot + 1 ..])) return .{ .domain = di, .service = pi };
    return null;
}

/// Check a manifest. Returns null if it is sound, else one sentence (in
/// `buf`) that names the problem and how to fix it.
pub fn validate(m: Manifest, buf: []u8) ?[]const u8 {
    @setEvalBranchQuota(1_000_000);
    const f: Fail = .{ .buf = buf };
    if (m.name.len == 0) return f.msg("the manifest needs a name", .{});
    if (m.domains.len == 0) return f.msg("the manifest declares no domains", .{});
    if (m.domains.len > max_domains) return f.msg("{d} domains declared; at most {d} are supported", .{ m.domains.len, max_domains });

    var tasks: usize = 0;
    for (m.domains, 0..) |d, i| {
        if (!isName(d.name)) return f.msg("domain name '{s}' must be 1-{d} characters of a-z, 0-9 and _", .{ d.name, max_name });
        for (m.domains[0..i]) |e| if (std.mem.eql(u8, e.name, d.name)) return f.msg("two domains are named '{s}'", .{d.name});
        if (!isName(d.program)) return f.msg("domain '{s}': program name '{s}' must be 1-{d} characters of a-z, 0-9 and _", .{ d.name, d.program, max_name });
        if (d.priority == 0 or d.priority == 255) return f.msg("domain '{s}': priority {d} is outside 1..254 (255 is Steward's)", .{ d.name, d.priority });
        if (d.hart >= 16) return f.msg("domain '{s}': hart {d} does not exist (at most 16 harts)", .{ d.name, d.hart });
        if (d.budget_us == 0 or d.period_us == 0) return f.msg("domain '{s}': budget_us and period_us must be positive", .{d.name});
        if (d.budget_us > d.period_us) return f.msg("domain '{s}': budget_us ({d}) is larger than period_us ({d})", .{ d.name, d.budget_us, d.period_us });
        if (d.period_us > 10_000_000) return f.msg("domain '{s}': period_us {d} is longer than 10 s", .{ d.name, d.period_us });
        if (d.memory_kib < 4 or d.memory_kib > 65536 or !std.math.isPowerOfTwo(d.memory_kib))
            return f.msg("domain '{s}': memory_kib {d} must be a power of two from 4 to 65536", .{ d.name, d.memory_kib });
        if (d.kind == .task) tasks += 1;

        if (d.provides.len > max_provides) return f.msg("domain '{s}' provides {d} services; at most {d}", .{ d.name, d.provides.len, max_provides });
        for (d.provides, 0..) |p, pi| {
            if (!isName(p.name)) return f.msg("domain '{s}': service name '{s}' must be 1-{d} characters of a-z, 0-9 and _", .{ d.name, p.name, max_name });
            for (d.provides[0..pi]) |q| if (std.mem.eql(u8, q.name, p.name)) return f.msg("domain '{s}' provides '{s}' twice", .{ d.name, p.name });
            if (p.protocol.len == 0 or p.protocol.len > max_name) return f.msg("domain '{s}': service '{s}' needs a protocol name of 1-{d} characters", .{ d.name, p.name, max_name });
        }

        if (d.uses.len > max_uses) return f.msg("domain '{s}' uses {d} services; at most {d}", .{ d.name, d.uses.len, max_uses });
        for (d.uses, 0..) |u, ui| {
            if (!isName(u.name)) return f.msg("domain '{s}': use name '{s}' must be 1-{d} characters of a-z, 0-9 and _", .{ d.name, u.name, max_name });
            for (d.uses[0..ui]) |v| if (std.mem.eql(u8, v.name, u.name)) return f.msg("domain '{s}' uses the name '{s}' twice", .{ d.name, u.name });
            const target = resolveUse(m, u.from) orelse
                return f.msg("domain '{s}' uses '{s}', but no domain provides it (write it as \"<domain>.<service>\")", .{ d.name, u.from });
            if (target.domain == i) return f.msg("domain '{s}' uses its own service '{s}'", .{ d.name, u.from });
            const provided = m.domains[target.domain].provides[target.service];
            if (!std.mem.eql(u8, provided.protocol, u.protocol))
                return f.msg("domain '{s}' expects '{s}' to speak {s}, but it speaks {s}", .{ d.name, u.from, u.protocol, provided.protocol });
        }

        if (d.devices.len > max_devices) return f.msg("domain '{s}' asks for {d} devices; at most {d}", .{ d.name, d.devices.len, max_devices });
        for (d.devices, 0..) |dev, di| {
            if (!isName(dev.name)) return f.msg("domain '{s}': device name '{s}' must be 1-{d} characters of a-z, 0-9 and _", .{ d.name, dev.name, max_name });
            for (d.devices[0..di]) |e| if (std.mem.eql(u8, e.name, dev.name)) return f.msg("domain '{s}' names two devices '{s}'", .{ d.name, dev.name });
            const known = for (known_virtio) |kv| {
                if (kv.id == dev.virtio) break true;
            } else false;
            if (!known) return f.msg("domain '{s}': device '{s}' asks for virtio id {d}, which no driver here supports (known: 3 console, 4 entropy source)", .{ d.name, dev.name, dev.virtio });
        }
    }

    // Each hart must keep a tenth of its time for Steward and the kernel.
    var load: [16]u64 = @splat(0);
    for (m.domains) |d| load[d.hart] += @as(u64, d.budget_us) * 1_000_000 / d.period_us;
    for (load, 0..) |l, h| if (l > max_hart_load_ppm)
        return f.msg("hart {d} is overcommitted: its domains ask for {d}.{d}% of it, and at most 90% can be promised", .{ h, l / 10_000, (l / 1000) % 10 });

    // Calls are synchronous, so a cycle of uses can deadlock.
    for (m.domains, 0..) |_, start| {
        var path: [max_domains]usize = undefined;
        if (findCycle(m, start, &path, 0)) |len| {
            var w: std.Io.Writer = .fixed(buf);
            w.print("services call each other in a cycle: ", .{}) catch {};
            for (path[0..len]) |p| w.print("{s} -> ", .{m.domains[p].name}) catch {};
            w.print("{s}; calls are synchronous, so this can deadlock", .{m.domains[start].name}) catch {};
            return w.buffered();
        }
    }

    // Two domains cannot drive the same device.
    for (m.domains, 0..) |d, i| for (d.devices, 0..) |dev, di| {
        for (m.domains[0 .. i + 1], 0..) |e, j| for (e.devices, 0..) |other, k| {
            if (j == i and k >= di) break;
            if (other.virtio == dev.virtio and other.instance == dev.instance)
                return f.msg("domains '{s}' and '{s}' both claim virtio device {d} instance {d}", .{ e.name, d.name, dev.virtio, dev.instance });
        };
    };

    if (m.agent) |a| {
        if (findDomain(m, a.envoy) == null) return f.msg("agent.envoy names '{s}', which is not a domain", .{a.envoy});
        if (a.grants.len + a.askable.len > max_agent_caps) return f.msg("the agent has {d} grants and askable services; at most {d}", .{ a.grants.len + a.askable.len, max_agent_caps });
        const lists = [_][]const Grant{ a.grants, a.askable };
        for (lists, 0..) |list, li| for (list, 0..) |g, gi| {
            const what = if (li == 0) "grant" else "askable service";
            if (!isName(g.name)) return f.msg("agent {s} name '{s}' must be 1-{d} characters of a-z, 0-9 and _", .{ what, g.name, max_name });
            for (lists[0 .. li + 1], 0..) |earlier, ej| for (earlier, 0..) |h, hi| {
                if (ej == li and hi >= gi) break;
                if (std.mem.eql(u8, h.name, g.name)) return f.msg("the agent has two services named '{s}'", .{g.name});
            };
            const t = resolveUse(m, g.from) orelse return f.msg("agent {s} '{s}' comes from '{s}', but no domain provides it", .{ what, g.name, g.from });
            const provided = m.domains[t.domain].provides[t.service];
            if (!std.mem.eql(u8, provided.protocol, g.protocol))
                return f.msg("agent {s} '{s}' expects {s}, but '{s}' speaks {s}", .{ what, g.name, g.protocol, g.from, provided.protocol });
        };
    }

    if (m.halt_when_tasks_finish and tasks == 0) return f.msg("halt_when_tasks_finish is set but no domain is a task", .{});
    return null;
}

fn findCycle(m: Manifest, at: usize, path: *[max_domains]usize, depth: usize) ?usize {
    if (depth == max_domains) return null;
    path[depth] = at;
    for (m.domains[at].uses) |u| {
        const t = resolveUse(m, u.from) orelse continue;
        if (t.domain == path[0]) return depth + 1;
        const seen = for (path[0 .. depth + 1]) |p| {
            if (p == t.domain) break true;
        } else false;
        if (!seen) if (findCycle(m, t.domain, path, depth + 1)) |n| return n;
    }
    return null;
}

/// Compile-time check for Steward: a bad manifest is a compile error.
pub fn check(comptime m: Manifest, comptime file: []const u8) void {
    comptime {
        var buf: [512]u8 = undefined;
        if (validate(m, &buf)) |e| @compileError(file ++ ": " ++ e);
    }
}

// ---------------------------------------------------------------------------

fn expectError(m: Manifest, want: []const u8) !void {
    var buf: [512]u8 = undefined;
    const got = validate(m, &buf) orelse {
        std.debug.print("expected an error containing \"{s}\", got none\n", .{want});
        return error.TestExpectedError;
    };
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("expected an error containing \"{s}\", got \"{s}\"\n", .{ want, got });
        return error.TestUnexpectedError;
    }
}

const console: Domain = .{ .name = "console", .program = "virtio_console", .provides = &.{.{ .name = "console", .protocol = "console.v1" }} };

test "a sound manifest passes" {
    var buf: [512]u8 = undefined;
    const m: Manifest = .{ .name = "t", .domains = &.{
        console,
        .{ .name = "hello", .program = "hello", .kind = .task, .uses = &.{.{ .name = "out", .from = "console.console", .protocol = "console.v1" }} },
    } };
    try std.testing.expectEqual(@as(?[]const u8, null), validate(m, &buf));
}

test "each mistake gets its own explanation" {
    try expectError(.{ .name = "t", .domains = &.{} }, "no domains");
    try expectError(.{ .name = "t", .domains = &.{ console, console } }, "two domains are named 'console'");
    try expectError(.{ .name = "t", .domains = &.{.{ .name = "Bad Name", .program = "x" }} }, "domain name 'Bad Name'");
    try expectError(.{ .name = "t", .domains = &.{.{ .name = "a", .program = "x", .priority = 255 }} }, "priority 255 is outside 1..254");
    try expectError(.{ .name = "t", .domains = &.{.{ .name = "a", .program = "x", .budget_us = 20, .period_us = 10 }} }, "budget_us (20) is larger than period_us (10)");
    try expectError(.{ .name = "t", .domains = &.{.{ .name = "a", .program = "x", .memory_kib = 48 }} }, "memory_kib 48 must be a power of two");
    try expectError(.{ .name = "t", .domains = &.{ console, .{ .name = "a", .program = "x", .uses = &.{.{ .name = "out", .from = "console.consol", .protocol = "console.v1" }} } } }, "uses 'console.consol', but no domain provides it");
    try expectError(.{ .name = "t", .domains = &.{ console, .{ .name = "a", .program = "x", .uses = &.{.{ .name = "out", .from = "console.console", .protocol = "console.v2" }} } } }, "expects 'console.console' to speak console.v2, but it speaks console.v1");
    try expectError(.{ .name = "t", .domains = &.{.{ .name = "a", .program = "x", .devices = &.{.{ .name = "gpu", .virtio = 16 }} }} }, "virtio id 16");
    try expectError(.{ .name = "t", .domains = &.{
        .{ .name = "a", .program = "x", .budget_us = 6_000, .period_us = 10_000 },
        .{ .name = "b", .program = "x", .budget_us = 4_000, .period_us = 10_000 },
    } }, "hart 0 is overcommitted: its domains ask for 100.0%");
    try expectError(.{ .name = "t", .halt_when_tasks_finish = true, .domains = &.{console} }, "no domain is a task");
}

test "agent grants and device claims are checked" {
    const rng: Domain = .{ .name = "rng", .program = "virtio_rng", .devices = &.{.{ .name = "source", .virtio = 4 }}, .provides = &.{.{ .name = "entropy", .protocol = "entropy.v1" }} };
    const envoy: Domain = .{ .name = "envoy", .program = "envoy", .devices = &.{.{ .name = "port", .virtio = 3, .instance = 1 }} };
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), validate(.{ .name = "t", .domains = &.{ console, rng, envoy }, .agent = .{
        .envoy = "envoy",
        .grants = &.{.{ .name = "console", .from = "console.console", .protocol = "console.v1", .uses = 5 }},
        .askable = &.{.{ .name = "entropy", .from = "rng.entropy", .protocol = "entropy.v1" }},
    } }, &buf));
    try expectError(.{ .name = "t", .domains = &.{console}, .agent = .{ .envoy = "nobody" } }, "agent.envoy names 'nobody'");
    try expectError(.{ .name = "t", .domains = &.{ console, envoy }, .agent = .{ .envoy = "envoy", .grants = &.{.{ .name = "x", .from = "console.console", .protocol = "echo.v1" }} } }, "agent grant 'x' expects echo.v1, but 'console.console' speaks console.v1");
    try expectError(.{ .name = "t", .domains = &.{ console, envoy }, .agent = .{ .envoy = "envoy", .grants = &.{
        .{ .name = "x", .from = "console.console", .protocol = "console.v1" },
    }, .askable = &.{.{ .name = "x", .from = "console.console", .protocol = "console.v1" }} } }, "two services named 'x'");
    const con_a: Domain = .{ .name = "con_a", .program = "virtio_console", .devices = &.{.{ .name = "port", .virtio = 3 }} };
    const con_b: Domain = .{ .name = "con_b", .program = "virtio_console", .devices = &.{.{ .name = "port", .virtio = 3 }} };
    try expectError(.{ .name = "t", .domains = &.{ con_a, con_b } }, "domains 'con_a' and 'con_b' both claim virtio device 3 instance 0");
}

test "call cycles are found and spelled out" {
    try expectError(.{ .name = "t", .domains = &.{
        .{ .name = "a", .program = "x", .provides = &.{.{ .name = "s", .protocol = "p.v1" }}, .uses = &.{.{ .name = "b", .from = "b.s", .protocol = "p.v1" }} },
        .{ .name = "b", .program = "x", .provides = &.{.{ .name = "s", .protocol = "p.v1" }}, .uses = &.{.{ .name = "c", .from = "c.s", .protocol = "p.v1" }} },
        .{ .name = "c", .program = "x", .provides = &.{.{ .name = "s", .protocol = "p.v1" }}, .uses = &.{.{ .name = "a", .from = "a.s", .protocol = "p.v1" }} },
    } }, "a -> b -> c -> a");
}
