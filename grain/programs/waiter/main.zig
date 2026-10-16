//! waiter: calls a service that never comes up. Once Steward gives up on
//! the provider and revokes its endpoint, the call must end (aborted, or
//! invalid if the endpoint was already gone), not hang forever.
const g = @import("grain");

pub const panic = g.panic;
comptime {
    g.exportStart();
}

pub fn main() !u16 {
    const ep = g.use("service") orelse return error.NoService;
    const r = g.call(ep, .{ .label = g.proto.echo.ping, .length = 1 }, .{1});
    g.log("call_ended", .{ .status = @tagName(r.status) });
    // A second call on the revoked endpoint fails at once.
    const again = g.call(ep, .{ .label = g.proto.echo.ping, .length = 1 }, .{1});
    g.log("call_again", .{ .status = @tagName(again.status) });
    const ended_ok = r.status == .aborted or r.status == .invalid_cap;
    return if (ended_ok and again.status == .invalid_cap) 0 else 1;
}
