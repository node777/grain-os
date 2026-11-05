//! desktop.v1: the desktop's own settings, for the owner's settings
//! application. Surf serves it beside surf.v1 and scene.v1. Setting a style
//! repaints the desktop and every window's frame, and tells every window
//! (surf.v1's `restyled` event) so applications drawn with the toolkit
//! change with it.
const idl = @import("grain").idl;

pub const name = "desktop";
pub const version = 1;
pub const doc = "The desktop's style: read it, or set it for the desktop, the window frames and every application.";

/// dusk: light text on deep violet (the default); daylight: dark text on
/// warm paper.
pub const Style = enum { dusk, daylight };

pub const style = idl.Method(.{ .label = 1, .effect = .pure, .doc = "The style the desktop is in." }, struct {}, struct {
    style: Style,
});

pub const set_style = idl.Method(.{ .label = 2, .effect = .mutates, .doc = "Put the desktop in `style`; every window is told. Returns the style it was in.", .undo = "set_style" }, struct {
    style: Style,
}, struct {
    style: Style,
    pub const docs = .{ .style = "The style it was in (what undo puts back)" };
});
