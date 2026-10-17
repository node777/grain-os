//! surf.v1: a window on the screen, drawn in brushstrokes.
//!
//! An application does not hand Surf pixels. It describes its window as a
//! list of strokes (a filled rectangle, a rounded panel, a line of text, an
//! outline), each with an optional element id and a role, and Surf paints
//! them. So the screen is always typed data: scene.v1 lets anyone holding
//! it (an agent, through Envoy) read every visible element back.
//!
//! Frames are atomic: `stroke` stages the next frame's strokes by index and
//! `present` swaps them in whole. Events (keys, clicks on elements) queue
//! per window; `listen` gives Surf a signal to raise when some are waiting,
//! and `next_event` takes them one at a time.
const idl = @import("grain").idl;

pub const name = "surf";
pub const version = 1;
pub const doc = "A window on the screen, described as typed brushstrokes; keys and clicks come back as events.";

pub const Kind = enum { fill, panel, text, outline };
pub const Role = idl.Text(16);
pub const max_text = 120;
pub const max_strokes = 96;

pub const open = idl.Method(.{ .label = 1, .effect = .mutates, .doc = "Open your window, or retitle and resize it. It stays hidden until the owner opens it from the dock, unless `shown`." }, struct {
    title: idl.Text(32),
    width: u16,
    height: u16,
    shown: bool,
}, struct {});

pub const stroke = idl.Method(.{ .label = 2, .effect = .mutates, .doc = "Stage stroke `index` of your next frame, in window coordinates. A stroke with an `element` id is something the owner can click." }, struct {
    index: u16,
    kind: Kind,
    x: i16,
    y: i16,
    w: u16,
    h: u16,
    color: u32,
    element: u16,
    role: Role,
    text: idl.Text(max_text),
    pub const docs = .{
        .kind = "fill: a rectangle; panel: a rectangle with rounded corners; text: a line of text from (x, y); outline: a one-pixel border",
        .color = "0xRRGGBB",
        .element = "Nonzero: clicks on this stroke are reported with this id",
        .role = "What the stroke is, for whoever reads the scene: label, button, input, output, ...",
    };
}, struct {});

pub const present = idl.Method(.{ .label = 3, .effect = .mutates, .doc = "Show the first `count` staged strokes as your window, all at once." }, struct {
    count: u16,
}, struct {});

pub const listen = idl.Method(.{ .label = 4, .effect = .mutates, .doc = "Give Surf a signal to raise whenever events wait for your window." }, struct {
    signal: idl.Cap,
}, struct {});

pub const EventKind = enum { none, key, click, shown, hidden };

pub const next_event = idl.Method(.{ .label = 5, .effect = .mutates, .doc = "Take the oldest event for your window (kind none if there is none)." }, struct {}, struct {
    kind: EventKind,
    char: u8,
    code: u16,
    x: i16,
    y: i16,
    element: u16,
    pub const docs = .{
        .char = "key: the character typed (0 for keys that type none)",
        .code = "key: the key code (Linux numbering)",
        .x = "click: window coordinates",
        .element = "click: the element id under the pointer, or 0",
    };
});

// ---------------------------------------------------------------------------
// Client helpers: a frame built stroke by stroke, then presented whole.

const grain = @import("grain");

pub const Frame = struct {
    ep: grain.CPtr,
    n: u16 = 0,

    pub const Box = struct { x: i32, y: i32, w: i32 = 0, h: i32 = 0 };

    pub fn add(f: *Frame, kind: Kind, b: Box, color: u32, element_id: u16, role: []const u8, words: []const u8) idl.CallError!void {
        if (f.n == max_strokes) return error.InvalidArgs;
        _ = try idl.call(stroke, f.ep, .{
            .index = f.n,
            .kind = kind,
            .x = @intCast(b.x),
            .y = @intCast(b.y),
            .w = @intCast(@max(0, b.w)),
            .h = @intCast(@max(0, b.h)),
            .color = color,
            .element = element_id,
            .role = Role.from(role),
            .text = idl.Text(max_text).from(words[0..@min(words.len, max_text)]),
        });
        f.n += 1;
    }

    pub fn fill(f: *Frame, b: Box, color: u32, role: []const u8) idl.CallError!void {
        return f.add(.fill, b, color, 0, role, "");
    }

    pub fn text(f: *Frame, x: i32, y: i32, s: []const u8, color: u32, role: []const u8) idl.CallError!void {
        return f.add(.text, .{ .x = x, .y = y }, color, 0, role, s);
    }

    /// A rounded panel with a label in the middle that reports clicks as `id`.
    pub fn button(f: *Frame, b: Box, color: u32, id: u16, label: []const u8) idl.CallError!void {
        return f.add(.panel, b, color, id, "button", label);
    }

    pub fn present(f: *Frame) idl.CallError!void {
        _ = try idl.call(present_method, f.ep, .{ .count = f.n });
        f.n = 0;
    }
};

const present_method = present;
