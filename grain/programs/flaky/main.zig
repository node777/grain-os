//! flaky: a service that crashes the first time it runs, to show Steward's
//! restart policy. Its clients keep their endpoint across the restart.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");

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
    var server: Echo = .{};
    g.idl.serve(proto.echo, g.provided("echo") orelse return error.NoService, &server);
}

const Echo = struct {
    pub fn ping(_: *Echo, p: proto.echo.ping.Params, caller: g.idl.Caller) !proto.echo.ping.Results {
        return .{ .value = p.value +% 1, .badge = caller.badge };
    }
};
