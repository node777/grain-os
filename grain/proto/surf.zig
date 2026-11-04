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
//!
//! Surf owns the frame around a window: the owner drags it by its title
//! bar, puts it away with the "-" button, closes it with "x" (the app hears
//! `close`, and may tidy up), and, when the app gave a minimum size, resizes
//! it from the corner (the app hears `resized` and lays itself out again).
const idl = @import("grain").idl;

pub const name = "surf";
pub const version = 1;
pub const doc = "A window on the screen, described as typed brushstrokes; keys and clicks come back as events.";

pub const Kind = enum { fill, panel, text, outline };
pub const Role = idl.Text(16);
pub const max_text = 120;
pub const max_strokes = 192;

pub const open = idl.Method(.{ .label = 1, .effect = .mutates, .doc = "Open your window, or retitle and resize it. It stays hidden until the owner opens it from the dock, unless `shown`. With a minimum size, the owner may resize it." }, struct {
    title: idl.Text(32),
    width: u16,
    height: u16,
    shown: bool,
    min_width: u16,
    min_height: u16,
    pub const docs = .{
        .width = "The content's width, inside Surf's frame",
        .min_width = "The smallest width the owner may resize it to; 0 for a window of fixed size",
    };
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

pub const EventKind = enum { none, key, click, shown, hidden, close, resized };

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
        .x = "click: window coordinates; resized: the new width (and y the new height)",
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

// ---------------------------------------------------------------------------
// Applications: a window drawn with grain/lib/ui.zig, and its event loop.

const ui = grain.ui;
const D = grain.domain;

fn sinkAdd(ctx: *anyopaque, kind: ui.Kind, b: ui.Box, color: u32, id: u16, role: []const u8, words: []const u8) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (app.failed != null) return;
    app.frame.add(@enumFromInt(@intFromEnum(kind)), .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h }, color, id, role, words) catch |e| {
        app.failed = e;
    };
}

pub const AppOptions = struct {
    shown: bool = false,
    /// Resizable down to this size (0: fixed).
    min_width: u16 = 0,
    min_height: u16 = 0,
    theme: *const ui.Theme = &ui.dark,
};

/// What woke the application.
pub const Wake = enum { events, tick };

/// A window and its loop. The application keeps its state in a value with
/// `fn draw(self, *ui.Ui) void`, and may have `fn tick(self) void` (called
/// on `every`), `fn closed(self) void` and `fn resized(self) void`.
pub const App = struct {
    surf: grain.CPtr,
    /// Waited on: Surf raises it with badge 1, the alarm with badge 2.
    sig: grain.CPtr,
    timer: grain.CPtr,
    width: u16,
    height: u16,
    shown: bool,
    theme: *const ui.Theme,
    focus: u16 = 0,
    frame: Frame,
    failed: ?idl.CallError = null,
    period_ticks: u64 = 0,

    pub fn open(space: *grain.Space, title: []const u8, width: u16, height: u16, opts: AppOptions) !App {
        const surf = grain.use("surf") orelse return error.NoService;
        _ = try idl.call(open_method, surf, .{
            .title = idl.Text(32).from(title),
            .width = width,
            .height = height,
            .shown = opts.shown,
            .min_width = opts.min_width,
            .min_height = opts.min_height,
        });
        const sig = try space.retype(.signal, 0);
        const raise = try space.slot();
        if (!grain.invoke(D.Slot.cnode, grain.abi.CNodeMethod.mint, .{ raise, sig, (grain.abi.Rights{ .send = true }).bits(), 1, 0 }).ok()) return error.MintFailed;
        const timer = try space.slot();
        if (!grain.invoke(D.Slot.cnode, grain.abi.CNodeMethod.mint, .{ timer, sig, (grain.abi.Rights{ .send = true }).bits(), 2, 0 }).ok()) return error.MintFailed;
        _ = try idl.call(listen, surf, .{ .signal = .{ .slot = raise } });
        return .{ .surf = surf, .sig = sig, .timer = timer, .width = width, .height = height, .shown = opts.shown, .theme = opts.theme, .frame = .{ .ep = surf } };
    }

    /// Call `tick` every `ms` milliseconds (0 stops).
    pub fn every(app: *App, ms: u64) void {
        app.period_ticks = ms * @max(grain.env().timebase_hz / 1000, 1);
        _ = grain.alarm(app.timer, app.period_ticks);
    }

    /// Draw the window from `state` and show it.
    pub fn redraw(app: *App, state: anytype) !void {
        var u = ui.Ui.init(.{ .ctx = app, .add = sinkAdd }, app.theme, app.width, app.height, .{}, &app.focus, max_strokes);
        state.draw(&u);
        if (app.failed) |e| {
            app.failed = null;
            app.frame.n = 0;
            return e;
        }
        try app.frame.present();
    }

    /// One event through the widgets (nothing drawn): `state` changes.
    pub fn handle(app: *App, state: anytype, input: ui.Input) void {
        var u = ui.Ui.init(null, app.theme, app.width, app.height, input, &app.focus, max_strokes);
        state.draw(&u);
    }

    /// Serve the window forever: wait, hand events to the widgets (and to
    /// `state`'s hooks), draw once for everything that came.
    pub fn run(app: *App, state: anytype) !noreturn {
        const T = @TypeOf(state.*);
        try app.redraw(state);
        while (true) {
            const bits = grain.wait(app.sig).w[0];
            var changed = false;
            if (bits & 2 != 0) {
                if (app.period_ticks != 0) _ = grain.alarm(app.timer, app.period_ticks);
                if (@hasDecl(T, "tick")) state.tick();
                changed = app.shown;
            }
            while (true) {
                const e = try idl.call(next_event, app.surf, .{});
                switch (e.kind) {
                    .none => break,
                    .key => app.handle(state, .{ .key = .{ .char = e.char, .code = e.code } }),
                    .click => app.handle(state, .{ .click = .{ .x = e.x, .y = e.y, .id = e.element } }),
                    .shown => app.shown = true,
                    .hidden => app.shown = false,
                    .close => {
                        app.shown = false;
                        if (@hasDecl(T, "closed")) state.closed();
                    },
                    .resized => {
                        app.width = @intCast(@max(1, e.x));
                        app.height = @intCast(@max(1, e.y));
                        if (@hasDecl(T, "resized")) state.resized();
                    },
                }
                changed = true;
            }
            if (changed) try app.redraw(state);
        }
    }
};

const open_method = open;
