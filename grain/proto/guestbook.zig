//! guestbook.v1: the first hosted application. Whoever its owner shares it
//! with can leave a line; the owner reads them.
const idl = @import("grain").idl;

pub const name = "guestbook";
pub const version = 1;
pub const doc = "A guestbook: visitors sign it with a line, anyone holding it can read the lines back.";

pub const sign = idl.Method(.{ .label = 1, .effect = .mutates, .doc = "Leave a line in the guestbook. Returns its number." }, struct {
    text: idl.Text(120),
}, struct {
    entry: u32,
});

pub const count = idl.Method(.{ .label = 2, .effect = .pure, .doc = "How many lines the guestbook holds." }, struct {}, struct {
    count: u32,
});

pub const read = idl.Method(.{ .label = 3, .effect = .pure, .doc = "Line `entry`, and who passed it on (a local domain's name: comlink for visitors from other instances)." }, struct {
    entry: u32,
}, struct {
    text: idl.Text(120),
    by: idl.Text(23),
});
