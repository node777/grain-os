//! crasher: a service that faults every time it starts. Steward restarts it
//! up to its manifest limit, then stops it and revokes its service.
const g = @import("grain");

pub const panic = g.panic;
comptime {
    g.exportStart();
}

pub fn main() !u16 {
    g.log("crashing", .{ .restart_count = g.env().restart_count });
    @as(*volatile u8, @ptrFromInt(0x20)).* = 1;
    return 0;
}
