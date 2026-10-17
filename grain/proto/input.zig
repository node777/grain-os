//! input.v1: what the owner types.
const idl = @import("grain").idl;

pub const name = "input";
pub const version = 1;
pub const doc = "The owner's typed input, a line at a time. Only domains the manifest wires to it can read it (the disk's passphrase is typed here).";

pub const read_line = idl.Method(.{ .label = 1, .effect = .mutates, .doc = "Take the next line the owner typed, if a whole one is waiting." }, struct {}, struct {
    text: idl.Text(128),
    ready: bool,
    pub const docs = .{ .text = "The line, without its newline", .ready = "Whether a line was waiting" };
});
