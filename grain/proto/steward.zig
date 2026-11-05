//! steward.v1: what Steward runs. The system's domains as the manifest
//! declares them and as they stand now (running, exited, failed, stopped),
//! the CPU time each has been charged (the kernel's count on its
//! scheduling context), and the owner's two levers: restart a domain, or
//! stop it. Steward serves it itself: a manifest names it `steward.domains`.
const idl = @import("grain").idl;

pub const name = "steward";
pub const version = 1;
pub const doc = "The system's domains, how they stand and the time they have used; restart or stop one.";

pub const Kind = enum { service, task };
pub const Status = enum { not_started, running, exited, failed, skipped, stopped };

pub const system = idl.Method(.{ .label = 1, .effect = .pure, .doc = "The system: its name and closure, its harts, how many domains it has, and how long it has run." }, struct {}, struct {
    name: idl.Text(32),
    closure: idl.Bytes(32),
    harts: u8,
    domains: u16,
    uptime_us: u64,
});

pub const domain = idl.Method(.{ .label = 2, .effect = .pure, .doc = "Domain `index` (from 0): what it runs, how it stands, its budget and memory, and the CPU time charged to it." }, struct {
    index: u16,
}, struct {
    name: idl.Text(24),
    program: idl.Text(24),
    kind: Kind,
    status: Status,
    restarts: u32,
    exit_code: u16,
    priority: u8,
    hart: u8,
    budget_us: u32,
    period_us: u32,
    memory_kib: u32,
    cpu_us: u64,
    pub const docs = .{
        .restarts = "Rebuilt after a fault or by the owner since boot",
        .budget_us = "CPU time it may use in each period, on its hart",
        .memory_kib = "Its region: program, stack, objects and memory",
        .cpu_us = "CPU time charged to it since it was last built (its threads', and servers' it called)",
    };
});

pub const restart = idl.Method(.{ .label = 3, .effect = .external, .doc = "Tear domain `index` down and build it again from its program, as after a fault. A stopped domain comes back, and its clients' capabilities with it." }, struct {
    index: u16,
}, struct {});

pub const stop = idl.Method(.{ .label = 4, .effect = .external, .doc = "Tear domain `index` down until it is restarted. Calls to its services fail meanwhile; the agent's leases on them end for good." }, struct {
    index: u16,
}, struct {});
