//! checker: a task that calls the flaky service. Its call waits in the
//! endpoint's queue while the service crashes and restarts, then succeeds.
const std = @import("std");
const g = @import("grain");

pub const panic = g.panic;
comptime {
    g.exportStart();
}

pub fn main() !u16 {
    const echo = g.use("echo") orelse return error.NoEcho;
    const console = g.use("console") orelse return error.NoConsole;
    const r = g.call(echo, .{ .label = g.proto.echo.ping, .length = 1 }, .{41});
    if (r.status != .ok or r.tag.label != g.proto.ok or r.w[0] != 42) {
        g.log("echo_failed", .{ .status = @tagName(r.status), .answer = r.w[0] });
        return 1;
    }
    // The server sees our badge: Steward's number for this domain.
    g.log("echo_ok", .{ .answer = r.w[0], .badge_seen_by_server = r.w[1] });
    try g.proto.console.print(console, "checker: flaky.echo answered 42\n");
    return 0;
}
