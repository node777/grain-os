//! flaky: a service that crashes the first time it runs, to show Steward's
//! restart policy. Its clients keep their endpoint across the restart.
const std = @import("std");
const g = @import("grain");

pub const panic = g.panic;
comptime {
    g.exportStart();
}

pub fn main() !u16 {
    if (g.env().restart_count == 0) {
        g.log("crashing_on_purpose", .{ .restart_count = 0 });
        @as(*volatile u8, @ptrFromInt(0x10)).* = 1; // store page fault
    }
    g.log("serving", .{ .restart_count = g.env().restart_count });
    g.serve(g.provided("echo") orelse return error.NoService, {}, handle);
}

fn handle(_: void, m: g.Message) g.Reply {
    if (m.label != g.proto.echo.ping) return .{ .label = g.proto.failed };
    return .{ .length = 2, .w = .{ m.w[0] + 1, m.badge, 0, 0, 0 } };
}
