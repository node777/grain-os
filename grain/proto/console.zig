//! console.v1: text output to the system console.
const std = @import("std");
const idl = @import("grain").idl;

pub const name = "console";
pub const version = 1;
pub const doc = "Text output to the system console. Lines from different callers never interleave.";

pub const write = idl.Method(.{ .label = 1, .effect = .external, .doc = "Append up to 256 bytes of text; output appears line by line." }, struct {
    text: idl.Text(256),
    pub const docs = .{ .text = "UTF-8 text; end a line with \\n" };
}, struct {});

/// Write any amount of text, 256 bytes at a time.
pub fn print(ep: @import("grain").CPtr, text: []const u8) idl.CallError!void {
    var rest = text;
    while (rest.len > 0) {
        const n = @min(rest.len, 256);
        _ = try idl.call(write, ep, .{ .text = idl.Text(256).from(rest[0..n]) });
        rest = rest[n..];
    }
}
