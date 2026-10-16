//! checker: a task that calls the flaky service. Its call waits in the
//! endpoint's queue while the service crashes and restarts, then succeeds.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");

pub const panic = g.panic;
comptime {
    g.exportStart();
}

pub fn main() !u16 {
    const echo = g.use("echo") orelse return error.NoEcho;
    const console = g.use("console") orelse return error.NoConsole;
    const r = g.idl.call(proto.echo.ping, echo, .{ .value = 41 }) catch |e| {
        g.log("echo_failed", .{ .err = @errorName(e) });
        return 1;
    };
    if (r.value != 42) {
        g.log("echo_failed", .{ .answer = r.value });
        return 1;
    }
    // The server sees our badge: Steward's number for this domain.
    g.log("echo_ok", .{ .answer = r.value, .badge_seen_by_server = r.badge });
    try proto.console.print(console, "checker: flaky.echo answered 42\n");
    return 0;
}
