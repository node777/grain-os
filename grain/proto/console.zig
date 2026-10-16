//! console.v1: text output to the system console.
const std = @import("std");
const idl = @import("grain").idl;

pub const name = "console";
pub const version = 1;
pub const doc = "The system console: text output (lines from different callers never interleave), and the owner's typed input.";

pub const write = idl.Method(.{ .label = 1, .effect = .external, .doc = "Append up to 256 bytes of text; output appears line by line." }, struct {
    text: idl.Text(256),
    pub const docs = .{ .text = "UTF-8 text; end a line with \\n" };
}, struct {});

pub const read_line = idl.Method(.{ .label = 2, .effect = .mutates, .doc = "Take the next line the owner typed, if a whole one is waiting. Never offered to the agent." }, struct {}, struct {
    text: idl.Text(128),
    ready: bool,
    pub const docs = .{ .text = "The line, without its newline", .ready = "Whether a line was waiting" };
});

/// Write any amount of text, 256 bytes at a time.
pub fn print(ep: @import("grain").CPtr, text: []const u8) idl.CallError!void {
    var rest = text;
    while (rest.len > 0) {
        const n = @min(rest.len, 256);
        _ = try idl.call(write, ep, .{ .text = idl.Text(256).from(rest[0..n]) });
        rest = rest[n..];
    }
}
