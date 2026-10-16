//! echo.v1: a liveness check.
const idl = @import("grain").idl;

pub const name = "echo";
pub const version = 1;
pub const doc = "A liveness check: answers immediately, and says who called.";

pub const ping = idl.Method(.{ .label = 1, .effect = .pure, .doc = "Answer value + 1, and the caller's badge as the server sees it." }, struct {
    value: u64,
    pub const docs = .{ .value = "Any number" };
}, struct {
    value: u64,
    badge: u64,
    pub const docs = .{ .value = "The number plus one", .badge = "The caller's identity as Steward badged it" };
});
