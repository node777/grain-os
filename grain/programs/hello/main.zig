//! hello: a task that reads entropy from one service and greets the world
//! through another. Neither address is known in advance; both come from
//! the manifest, by name.
const std = @import("std");
const g = @import("grain");

pub const panic = g.panic;
comptime {
    g.exportStart();
}

pub fn main() !u16 {
    const console = g.use("console") orelse return error.NoConsole;
    const entropy = g.use("entropy") orelse return error.NoEntropy;
    var random: [32]u8 = undefined;
    try g.proto.entropy.fill(entropy, &random);
    const hex = std.fmt.bytesToHex(random[0..8], .lower);
    var line: [96]u8 = undefined;
    const text = try std.fmt.bufPrint(&line, "hello from grain! entropy {s}\n", .{&hex});
    try g.proto.console.print(console, text);
    g.log("hello", .{ .entropy = @as([]const u8, &hex), .console_bytes = text.len });
    return 0;
}
