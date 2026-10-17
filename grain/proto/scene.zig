//! scene.v1: what is on the screen, as typed data.
//!
//! Everything Surf shows is a stroke in some window's list, its own desktop
//! (background, dock, launchers) included, so reading the scene is reading
//! the screen: positions, colours, text and roles, with nothing to guess
//! from pixels. Read-only.
const idl = @import("grain").idl;
const surf = @import("surf.zig");

pub const name = "scene";
pub const version = 1;
pub const doc = "What is on the screen, read back as typed data: windows, their elements, and what is under a point.";

pub const windows = idl.Method(.{ .label = 1, .effect = .pure, .doc = "The screen's size, how many windows there are (the desktop is window 0), which has the keyboard, and where the pointer is." }, struct {}, struct {
    width: u16,
    height: u16,
    count: u16,
    focused: u16,
    pointer_x: i16,
    pointer_y: i16,
    pub const docs = .{ .pointer_x = "The pointer's tip; it is drawn on top of everything, 12 by 18 pixels" };
});

pub const window = idl.Method(.{ .label = 2, .effect = .pure, .doc = "Window `index`: its owner, title, place on the screen, whether it is shown, and how many elements it has." }, struct {
    index: u16,
}, struct {
    owner: idl.Text(24),
    title: idl.Text(32),
    x: i16,
    y: i16,
    w: u16,
    h: u16,
    shown: bool,
    elements: u16,
});

pub const element = idl.Method(.{ .label = 3, .effect = .pure, .doc = "Element `index` of window `window`, in screen coordinates." }, struct {
    window: u16,
    index: u16,
}, struct {
    kind: surf.Kind,
    x: i16,
    y: i16,
    w: u16,
    h: u16,
    color: u32,
    id: u16,
    role: surf.Role,
    text: idl.Text(surf.max_text),
});

pub const at = idl.Method(.{ .label = 4, .effect = .pure, .doc = "What is at a screen point: the topmost shown window there and its topmost element (-1 if none)." }, struct {
    x: i16,
    y: i16,
}, struct {
    window: i16,
    element: i16,
});
