//! surf: the compositor. It drives the screen (virtio-gpu) and the owner's
//! keyboard and pointer (virtio-input) itself, keeps every window as a list
//! of typed strokes, paints them, and routes keys and clicks back.
//!
//! The desktop is window 0, owned by Surf: its background, top bar, dock and
//! one launcher per application window are strokes like any other, so
//! scene.v1 reads back the whole screen. One thread serves surf.v1 (apps),
//! scene.v1 (inspection) and the input devices: their interrupts arrive on
//! a signal bound to the thread (Thread.bind_signal), so a receive returns
//! for a client or for a key, whichever comes first.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");
const P = proto.surf;
const SceneP = proto.scene;
const idl = g.idl;
const D = g.domain;
const paint = g.paint;
const Rect = paint.Rect;
const vin = g.virtio_input;

pub const panic = g.panic;
pub const std_options = g.std_options;
comptime {
    g.exportStart();
}

// ---------------------------------------------------------------------------
// The look: warm and quiet.

const theme = struct {
    const background: u32 = 0x1d1a2b;
    const bar: u32 = 0x15131f;
    const bar_text: u32 = 0xe9dfcf;
    const dock: u32 = 0x2b2540;
    const launcher: u32 = 0x3d355a;
    const launcher_open: u32 = 0x7a6aa8;
    const frame: u32 = 0xf3ece2;
    const frame_focused: u32 = 0xfaf4ea;
    const title: u32 = 0x3b3049;
    const shadow: u32 = 0x000000;
    const cursor: u32 = 0xfaf4ea;
    const cursor_edge: u32 = 0x15131f;
};
const bar_h = 28;
const title_h = 30;
/// The frame's paper around the content, on the sides and below.
const border = 6;
const dock_h = 44;
const launcher_w = 112;

// ---------------------------------------------------------------------------
// The scene

const Stroke = struct {
    kind: P.Kind = .fill,
    x: i16 = 0,
    y: i16 = 0,
    w: u16 = 0,
    h: u16 = 0,
    color: u32 = 0,
    element: u16 = 0,
    role: [16]u8 = @splat(0),
    role_len: u8 = 0,
    text: [P.max_text]u8 = @splat(0),
    text_len: u8 = 0,

    fn rect(s: *const Stroke) Rect {
        if (s.kind == .text) return .{ .x = s.x, .y = s.y, .w = @as(i32, s.text_len) * paint.font.w, .h = paint.font.h };
        return .{ .x = s.x, .y = s.y, .w = s.w, .h = s.h };
    }

    fn textSlice(s: *const Stroke) []const u8 {
        return s.text[0..s.text_len];
    }

    fn make(kind: P.Kind, r: Rect, color: u32, element: u16, role: []const u8, text: []const u8) Stroke {
        var s: Stroke = .{ .kind = kind, .x = @intCast(r.x), .y = @intCast(r.y), .w = @intCast(r.w), .h = @intCast(r.h), .color = color, .element = element };
        s.role_len = @intCast(@min(role.len, s.role.len));
        @memcpy(s.role[0..s.role_len], role[0..s.role_len]);
        s.text_len = @intCast(@min(text.len, s.text.len));
        @memcpy(s.text[0..s.text_len], text[0..s.text_len]);
        return s;
    }
};

const Event = struct { kind: P.EventKind, char: u8 = 0, code: u16 = 0, x: i16 = 0, y: i16 = 0, element: u16 = 0 };

const max_windows = 6;

const Window = struct {
    used: bool = false,
    badge: usize = 0,
    owner: [24]u8 = @splat(0),
    owner_len: u8 = 0,
    title: [32]u8 = @splat(0),
    title_len: u8 = 0,
    /// Content size; the frame adds a title bar.
    w: u16 = 0,
    h: u16 = 0,
    x: i32 = 0,
    y: i32 = 0,
    shown: bool = false,
    strokes: [P.max_strokes]Stroke = undefined,
    n: u16 = 0,
    staged: [P.max_strokes]Stroke = undefined,
    events: [32]Event = undefined,
    ev_head: u8 = 0,
    ev_len: u8 = 0,
    /// The signal to raise when events wait (0 = the app polls).
    listener: g.CPtr = 0,

    fn frame(w: *const Window) Rect {
        if (w.badge == desktop_badge) return screen;
        return .{ .x = w.x, .y = w.y, .w = @as(i32, w.w) + 2 * border, .h = @as(i32, w.h) + title_h + border };
    }

    fn content(w: *const Window) Rect {
        if (w.badge == desktop_badge) return screen;
        return .{ .x = w.x + border, .y = w.y + title_h, .w = w.w, .h = w.h };
    }

    fn push(w: *Window, e: Event) void {
        if (w.ev_len == w.events.len) return; // full: the oldest stay
        w.events[(w.ev_head + w.ev_len) % w.events.len] = e;
        w.ev_len += 1;
        if (w.listener != 0) _ = g.signal(w.listener);
    }

    fn titleSlice(w: *const Window) []const u8 {
        return w.title[0..w.title_len];
    }
};

/// Window 0, the desktop, has no client behind it.
const desktop_badge = std.math.maxInt(usize);

var wins: [max_windows]Window = @splat(.{});
/// Window indices, bottom to top (the desktop is always first).
var order: [max_windows]u8 = undefined;
var n_order: usize = 0;
var focused: u8 = 0;
var screen: Rect = .{};
var pointer: struct { x: i32 = 0, y: i32 = 0, shift: bool = false } = .{};

// ---------------------------------------------------------------------------
// Devices

/// The screen: virtio-gpu (draw into memory we own, then have the host
/// show it) or a Bochs display (draw straight into its framebuffer).
const Display = union(enum) {
    virtio: g.virtio_gpu.Gpu,
    bochs: g.bochs.Bochs,

    fn flush(d: *Display, r: Rect) void {
        switch (d.*) {
            .virtio => |*v| v.flush(.{ .x = @intCast(r.x), .y = @intCast(r.y), .width = @intCast(r.w), .height = @intCast(r.h) }) catch |e| g.log("surf_flush_failed", .{ .err = @errorName(e) }),
            .bochs => {},
        }
    }
};
var display: Display = undefined;
var fb: []u32 = &.{};
var keys: ?vin.Input = null;
var mouse: ?vin.Input = null;
/// USB keyboards and tablets, through an xHCI controller.
var usb: ?g.xhci.Xhci = null;
var usb_irq: g.CPtr = 0;
var usb_buttons: u8 = 0;
var key_irq: g.CPtr = 0;
var mouse_irq: g.CPtr = 0;
const bit_keys: u64 = 1;
const bit_mouse: u64 = 2;
const bit_usb: u64 = 4;

fn canvas() paint.Canvas {
    return paint.Canvas.init(fb, @intCast(screen.w), @intCast(screen.h));
}

// ---------------------------------------------------------------------------
// Painting

/// Text drawn on a filled stroke goes in the middle, light or dark to
/// stand out from it.
fn onColor(bg: u32) u32 {
    const r = (bg >> 16) & 0xff;
    const gg = (bg >> 8) & 0xff;
    const b = bg & 0xff;
    return if (r * 3 + gg * 6 + b > 1280) theme.title else theme.bar_text;
}

fn drawStroke(c: *paint.Canvas, s: *const Stroke, dx: i32, dy: i32) void {
    const r = s.rect().offset(dx, dy);
    switch (s.kind) {
        .fill => c.fill(r, s.color),
        .panel => c.panel(r, 8, s.color),
        .outline => c.outline(r, s.color),
        .text => _ = c.text(r.x, r.y, s.textSlice(), s.color),
    }
    if (s.kind != .text and s.text_len > 0) {
        const t = s.textSlice();
        const tx = r.x + @divTrunc(r.w - paint.textWidth(t), 2);
        const ty = r.y + @divTrunc(r.h - paint.font.h, 2);
        _ = c.text(tx, ty, t, onColor(s.color));
    }
}

fn drawWindow(c: *paint.Canvas, i: u8, clip: Rect) void {
    const w = &wins[i];
    if (w.badge == desktop_badge) {
        for (w.strokes[0..w.n]) |*s| drawStroke(c, s, 0, 0);
        return;
    }
    const f = w.frame();
    if (f.intersect(clip).empty()) return;
    c.tint(.{ .x = f.x + 3, .y = f.y + 5, .w = f.w, .h = f.h }, theme.shadow, 60);
    c.panel(f, 10, if (i == focused) theme.frame_focused else theme.frame);
    const t = w.titleSlice();
    _ = c.text(f.x + @divTrunc(f.w - paint.textWidth(t), 2), f.y + 6, t, theme.title);
    const inner = w.content();
    const saved = c.clip;
    c.clip = c.clip.intersect(inner);
    for (w.strokes[0..w.n]) |*s| drawStroke(c, s, inner.x, inner.y);
    c.clip = saved;
}

fn cursorRect() Rect {
    return .{ .x = pointer.x, .y = pointer.y, .w = 12, .h = 18 };
}

fn drawCursor(c: *paint.Canvas) void {
    // An arrow: rows of growing width, outlined.
    var row: i32 = 0;
    while (row < 16) : (row += 1) {
        const width = @min(row + 1, 11 - @max(0, row - 10) * 2);
        if (width <= 0) break;
        c.fill(.{ .x = pointer.x, .y = pointer.y + row, .w = width + 1, .h = 1 }, theme.cursor_edge);
        if (width > 1) c.fill(.{ .x = pointer.x + 1, .y = pointer.y + row, .w = width - 1, .h = 1 }, theme.cursor);
    }
}

/// Repaint what lies in `damage` and show it.
fn repaint(damage: Rect) void {
    const d = damage.intersect(screen);
    if (d.empty()) return;
    var c = canvas();
    c.clip = d;
    for (order[0..n_order]) |i| if (wins[i].shown) drawWindow(&c, i, d);
    if (keys != null or mouse != null or usb != null) drawCursor(&c);
    display.flush(d);
}

// ---------------------------------------------------------------------------
// The desktop's own strokes

fn layoutDesktop() void {
    const d = &wins[0];
    var n: u16 = 0;
    const add = struct {
        fn f(win: *Window, i: *u16, s: Stroke) void {
            win.strokes[i.*] = s;
            i.* += 1;
        }
    }.f;
    add(d, &n, Stroke.make(.fill, screen, theme.background, 0, "background", ""));
    add(d, &n, Stroke.make(.fill, .{ .w = screen.w, .h = bar_h }, theme.bar, 0, "bar", ""));
    add(d, &n, Stroke.make(.text, .{ .x = 14, .y = 5 }, theme.bar_text, 0, "label", "grain"));
    const ft = if (focused != 0 and wins[focused].shown) wins[focused].titleSlice() else "";
    add(d, &n, Stroke.make(.text, .{ .x = @divTrunc(screen.w - paint.textWidth(ft), 2), .y = 5 }, theme.bar_text, 0, "focus", ft));
    var apps: i32 = 0;
    for (wins[1..]) |*w| apps += @intFromBool(w.used);
    if (apps > 0) {
        const dw = 12 + apps * (launcher_w + 8) - 8 + 12;
        const dock: Rect = .{ .x = @divTrunc(screen.w - dw, 2), .y = screen.h - dock_h - 10, .w = dw, .h = dock_h };
        add(d, &n, Stroke.make(.panel, dock, theme.dock, 0, "dock", ""));
        var x = dock.x + 12;
        for (wins[1..], 1..) |*w, i| if (w.used) {
            const r: Rect = .{ .x = x, .y = dock.y + 7, .w = launcher_w, .h = dock_h - 14 };
            add(d, &n, Stroke.make(.panel, r, if (w.shown) theme.launcher_open else theme.launcher, launcherId(@intCast(i)), "launcher", w.titleSlice()));
            x += launcher_w + 8;
        };
    }
    d.n = n;
}

fn launcherId(window: u8) u16 {
    return 1000 + @as(u16, window);
}

/// Lay the desktop out again and repaint everything.
fn refreshDesktop() void {
    layoutDesktop();
    repaint(screen);
}

// ---------------------------------------------------------------------------
// Windows

fn raise(i: u8) void {
    var k: usize = 0;
    for (order[0..n_order]) |o| if (o != i) {
        order[k] = o;
        k += 1;
    };
    order[k] = i;
    n_order = k + 1;
}

fn setShown(i: u8, shown: bool) void {
    const w = &wins[i];
    if (w.shown == shown) {
        if (shown and focused != i) focus(i);
        return;
    }
    w.shown = shown;
    w.push(.{ .kind = if (shown) .shown else .hidden });
    const what = .{ .window = i, .owner = w.owner[0..w.owner_len], .title = w.titleSlice() };
    if (shown) g.log("surf_window_shown", what) else g.log("surf_window_hidden", what);
    if (shown) {
        raise(i);
        focused = i;
    } else if (focused == i) {
        focused = 0;
        var k = n_order;
        while (k > 1) : (k -= 1) if (wins[order[k - 1]].shown and order[k - 1] != i) {
            focused = order[k - 1];
            break;
        };
    }
    refreshDesktop();
}

fn focus(i: u8) void {
    if (focused == i) return;
    focused = i;
    raise(i);
    refreshDesktop();
}

/// The window a client owns, opened if `create`.
fn windowOf(c: idl.Caller, create: bool) !u8 {
    for (wins[1..], 1..) |*w, i| if (w.used and w.badge == c.badge) return @intCast(i);
    if (!create) return error.NotFound;
    const owner = if (c.badge == D.agent_badge) "agent" else g.env().clientName(c.badge) orelse return error.Unavailable;
    for (wins[1..], 1..) |*w, i| if (!w.used) {
        w.* = .{ .used = true, .badge = c.badge };
        w.owner_len = @intCast(@min(owner.len, w.owner.len));
        @memcpy(w.owner[0..w.owner_len], owner[0..w.owner_len]);
        order[n_order] = @intCast(i);
        n_order += 1;
        return @intCast(i);
    };
    return error.Unavailable;
}

/// Topmost shown window at a point.
fn windowAt(x: i32, y: i32) ?u8 {
    var k = n_order;
    while (k > 0) : (k -= 1) {
        const i = order[k - 1];
        if (wins[i].shown and wins[i].frame().contains(x, y)) return i;
    }
    return null;
}

/// Topmost stroke at a point (screen coordinates); with `clickable`, only
/// strokes with an element id.
fn strokeAt(i: u8, x: i32, y: i32, clickable: bool) ?u16 {
    const w = &wins[i];
    const in = w.content();
    if (!in.contains(x, y)) return null;
    var k = w.n;
    while (k > 0) : (k -= 1) {
        const s = &w.strokes[k - 1];
        if (clickable and s.element == 0) continue;
        if (s.rect().offset(in.x, in.y).contains(x, y)) return k - 1;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Input

fn click(x: i32, y: i32) void {
    const i = windowAt(x, y) orelse return;
    if (i == 0) {
        const s = strokeAt(0, x, y, true) orelse return;
        const id = wins[0].strokes[s].element;
        if (id >= 1000 and id < 1000 + max_windows) {
            const target: u8 = @intCast(id - 1000);
            if (!wins[target].used) return;
            // A launcher opens its window, or puts it away if it is in front.
            setShown(target, !(wins[target].shown and focused == target));
        }
        return;
    }
    focus(i);
    const w = &wins[i];
    const in = w.content();
    if (!in.contains(x, y)) return;
    const s = strokeAt(i, x, y, true);
    w.push(.{ .kind = .click, .x = @intCast(x - in.x), .y = @intCast(y - in.y), .element = if (s) |k| w.strokes[k].element else 0 });
}

fn key(code: u16, value: u32) void {
    if (code == vin.key_left_shift or code == vin.key_right_shift) {
        pointer.shift = value != 0;
        return;
    }
    if (value == 0) return; // releases
    if (focused == 0 or !wins[focused].shown) return;
    wins[focused].push(.{ .kind = .key, .char = vin.char(code, pointer.shift), .code = code });
}

fn movePointer(x: u64, y: u64, max_x: u64, max_y: u64) void {
    const before = cursorRect();
    pointer.x = @intCast(x * @as(u64, @intCast(screen.w)) / (max_x + 1));
    pointer.y = @intCast(y * @as(u64, @intCast(screen.h)) / (max_y + 1));
    repaint(before.join(cursorRect()));
}

fn drainInput() void {
    if (usb) |*u| {
        var buf: [32]g.xhci.Event = undefined;
        for (u.poll(&buf)) |e| switch (e) {
            .key => |k| key(k.code, @intFromBool(k.down)),
            .pointer => |p| {
                movePointer(p.x, p.y, g.xhci.pointer_max, g.xhci.pointer_max);
                if (p.buttons & 1 != 0 and usb_buttons & 1 == 0) click(pointer.x, pointer.y);
                usb_buttons = p.buttons;
            },
        };
    }
    if (keys) |*k| while (k.next()) |e| {
        if (e.kind == vin.ev_key) key(e.code, e.value);
    };
    if (mouse) |*m| while (m.next()) |e| switch (e.kind) {
        vin.ev_abs => {
            const before = cursorRect();
            if (e.code == vin.abs_x) pointer.x = @intCast(@as(u64, e.value) * @as(u64, @intCast(screen.w)) / (@as(u64, m.abs_max[0]) + 1));
            if (e.code == vin.abs_y) pointer.y = @intCast(@as(u64, e.value) * @as(u64, @intCast(screen.h)) / (@as(u64, m.abs_max[1]) + 1));
            repaint(before.join(cursorRect()));
        },
        vin.ev_key => if (e.code == vin.btn_left and e.value == 1) click(pointer.x, pointer.y),
        else => {},
    };
}

// ---------------------------------------------------------------------------
// The services

fn setText(dst: []u8, len: *u8, src: []const u8) void {
    len.* = @intCast(@min(dst.len, src.len));
    @memcpy(dst[0..len.*], src[0..len.*]);
}

const Server = struct {
    pub fn onSignal(_: *Server, _: u64) void {
        // Read what came, acknowledge both devices, and read again: an
        // event that landed in between is not left waiting.
        drainInput();
        if (keys) |*k| {
            _ = k.dev.ackInterrupt();
            _ = g.invoke(key_irq, g.abi.IrqMethod.ack, .{});
        }
        if (mouse) |*m| {
            _ = m.dev.ackInterrupt();
            _ = g.invoke(mouse_irq, g.abi.IrqMethod.ack, .{});
        }
        if (usb != null) _ = g.invoke(usb_irq, g.abi.IrqMethod.ack, .{});
        drainInput();
    }

    // --- surf.v1 -----------------------------------------------------------

    pub fn open(_: *Server, p: P.open.Params, c: idl.Caller) !P.open.Results {
        if (p.width == 0 or p.height == 0 or @as(i32, p.width) + 2 * border > screen.w or @as(i32, p.height) + title_h + border + bar_h > screen.h) return error.InvalidArgs;
        const i = try windowOf(c, true);
        const w = &wins[i];
        setText(&w.title, &w.title_len, p.title.slice());
        w.w = p.width;
        w.h = p.height;
        // Centred, a little higher than the middle; later windows step down.
        w.x = @divTrunc(screen.w - w.w, 2) - border + (@as(i32, i) - 1) * 24;
        w.y = bar_h + 24 + (@as(i32, i) - 1) * 24;
        g.log("surf_window_opened", .{ .window = i, .owner = w.owner[0..w.owner_len], .title = w.titleSlice(), .width = w.w, .height = w.h });
        if (p.shown) setShown(i, true) else refreshDesktop();
        return .{};
    }

    pub fn stroke(_: *Server, p: P.stroke.Params, c: idl.Caller) !P.stroke.Results {
        const w = &wins[try windowOf(c, false)];
        if (p.index >= P.max_strokes) return error.InvalidArgs;
        var s: Stroke = .{ .kind = p.kind, .x = p.x, .y = p.y, .w = p.w, .h = p.h, .color = p.color & 0xffffff, .element = p.element };
        setText(&s.role, &s.role_len, p.role.slice());
        setText(&s.text, &s.text_len, p.text.slice());
        w.staged[p.index] = s;
        return .{};
    }

    pub fn present(_: *Server, p: P.present.Params, c: idl.Caller) !P.present.Results {
        const i = try windowOf(c, false);
        const w = &wins[i];
        if (p.count > P.max_strokes) return error.InvalidArgs;
        @memcpy(w.strokes[0..p.count], w.staged[0..p.count]);
        w.n = p.count;
        g.log("surf_presented", .{ .window = i, .owner = w.owner[0..w.owner_len], .strokes = w.n, .shown = w.shown });
        if (w.shown) repaint(w.frame());
        return .{};
    }

    pub fn listen(_: *Server, p: P.listen.Params, c: idl.Caller) !P.listen.Results {
        const w = &wins[try windowOf(c, true)];
        if (p.signal.slot == 0) return error.InvalidArgs;
        // Keep the signal: move it out of the receive slot into our own.
        if (w.listener == 0) w.listener = space.slot() catch return error.Unavailable;
        _ = g.invoke(D.Slot.cnode, g.abi.CNodeMethod.delete, .{w.listener});
        if (!g.invoke(D.Slot.cnode, g.abi.CNodeMethod.move, .{ w.listener, p.signal.slot }).ok()) return error.Failed;
        if (w.ev_len > 0) _ = g.signal(w.listener);
        return .{};
    }

    pub fn next_event(_: *Server, _: P.next_event.Params, c: idl.Caller) !P.next_event.Results {
        const w = &wins[try windowOf(c, false)];
        if (w.ev_len == 0) return .{ .kind = .none, .char = 0, .code = 0, .x = 0, .y = 0, .element = 0 };
        const e = w.events[w.ev_head];
        w.ev_head = @intCast((w.ev_head + 1) % w.events.len);
        w.ev_len -= 1;
        return .{ .kind = e.kind, .char = e.char, .code = e.code, .x = e.x, .y = e.y, .element = e.element };
    }

    // --- scene.v1 ----------------------------------------------------------

    pub fn windows(_: *Server, _: SceneP.windows.Params, _: idl.Caller) !SceneP.windows.Results {
        return .{ .width = @intCast(screen.w), .height = @intCast(screen.h), .count = @intCast(n_order), .focused = focused, .pointer_x = @intCast(pointer.x), .pointer_y = @intCast(pointer.y) };
    }

    fn byIndex(index: u16) !*Window {
        if (index >= max_windows or !wins[index].used) return error.NotFound;
        return &wins[index];
    }

    pub fn window(_: *Server, p: SceneP.window.Params, _: idl.Caller) !SceneP.window.Results {
        const w = try byIndex(p.index);
        const f = w.frame();
        return .{
            .owner = idl.Text(24).from(w.owner[0..w.owner_len]),
            .title = idl.Text(32).from(w.titleSlice()),
            .x = @intCast(f.x),
            .y = @intCast(f.y),
            .w = @intCast(f.w),
            .h = @intCast(f.h),
            .shown = w.shown,
            .elements = w.n,
        };
    }

    pub fn element(_: *Server, p: SceneP.element.Params, _: idl.Caller) !SceneP.element.Results {
        const w = try byIndex(p.window);
        if (p.index >= w.n) return error.NotFound;
        const s = &w.strokes[p.index];
        const in = w.content();
        const r = s.rect().offset(in.x, in.y);
        return .{
            .kind = s.kind,
            .x = @intCast(r.x),
            .y = @intCast(r.y),
            .w = @intCast(r.w),
            .h = @intCast(r.h),
            .color = s.color,
            .id = s.element,
            .role = P.Role.from(s.role[0..s.role_len]),
            .text = idl.Text(P.max_text).from(s.textSlice()),
        };
    }

    pub fn at(_: *Server, p: SceneP.at.Params, _: idl.Caller) !SceneP.at.Results {
        const i = windowAt(p.x, p.y) orelse return .{ .window = -1, .element = -1 };
        const s = strokeAt(i, p.x, p.y, false);
        return .{ .window = i, .element = if (s) |k| @intCast(k) else -1 };
    }
};

var space: g.Space = undefined;

// ---------------------------------------------------------------------------
// Start

fn page(va: usize) !g.virtio_gpu.Page {
    const d = try g.virtio.Dma.alloc(&space, va);
    return .{ .va = d.va, .pa = d.pa };
}

fn inputDevice(name: []const u8, sig: g.CPtr, badge: u64, irq_out: *g.CPtr, va: usize) !?vin.Input {
    const dev = g.device(name) orelse return null;
    const q = try page(va);
    const buf = try page(va + 0x1000);
    const badged = try space.slot();
    if (!g.invoke(D.Slot.cnode, g.abi.CNodeMethod.mint, .{ badged, sig, (g.abi.Rights{ .send = true }).bits(), badge, 0 }).ok()) return error.MintFailed;
    if (!g.invoke(dev.irq_slot, g.abi.IrqMethod.set_signal, .{badged}).ok()) return error.IrqSetup;
    irq_out.* = dev.irq_slot;
    return try vin.Input.init(dev.mmio, .{ .va = q.va, .pa = q.pa }, .{ .va = buf.va, .pa = buf.pa });
}

pub fn main() !u16 {
    space = .{ .untyped = D.Slot.memory, .vspace = D.Slot.vspace, .next_slot = D.Slot.first_free };
    const screen_dev = g.device("screen") orelse return error.NoDevice;
    const dma = D.Layout.heap + 0x0800_0000;
    switch (screen_dev.bus) {
        .virtio => {
            const q = try page(dma);
            const cmd = try page(dma + 0x1000);
            const gpu_sig = try space.retype(.signal, 0);
            if (!g.invoke(screen_dev.irq_slot, g.abi.IrqMethod.set_signal, .{gpu_sig}).ok()) return error.IrqSetup;
            var gpu = try g.virtio_gpu.Gpu.init(screen_dev.mmio, q, cmd, gpu_sig, screen_dev.irq_slot);
            // The framebuffer: 2 MiB frames, each physically contiguous.
            const bytes = gpu.frameBytes();
            const big = 2 * 1024 * 1024;
            var backing: [4]g.virtio_gpu.Backing = undefined;
            const n_big = (bytes + big - 1) / big;
            if (n_big > backing.len) return error.ScreenTooLarge;
            for (0..n_big) |k| {
                const f = try space.retype(.frame, 21);
                try space.map(f, D.Layout.heap + k * big, .{ .read = true, .write = true });
                backing[k] = .{ .pa = try g.physOf(f), .len = big };
            }
            fb = @as([*]u32, @ptrFromInt(D.Layout.heap))[0 .. bytes / 4];
            try gpu.attach(backing[0..n_big]);
            screen = .{ .w = @intCast(gpu.width), .h = @intCast(gpu.height) };
            display = .{ .virtio = gpu };
        },
        .pci => {
            if (!g.bochs.supports(screen_dev.vendor, screen_dev.device_id)) return error.UnsupportedDisplay;
            const vram = screen_dev.bar(0) orelse return error.NoFramebuffer;
            const regs = screen_dev.bar(2) orelse return error.NoRegisters;
            const b = try g.bochs.Bochs.init(vram.va, vram.size, regs.va, 1024, 768);
            fb = b.fb;
            screen = .{ .w = 1024, .h = 768 };
            display = .{ .bochs = b };
        },
        .absent => unreachable,
    }

    // Input: both devices raise one signal, bound to this thread.
    const input_sig = try space.retype(.signal, 0);
    keys = try inputDevice("keys", input_sig, bit_keys, &key_irq, dma + 0x2000);
    mouse = try inputDevice("pointer", input_sig, bit_mouse, &mouse_irq, dma + 0x4000);
    // Either may be the tablet: virtio does not say which is which in order.
    if (keys) |k| if (k.absolute) {
        const t = mouse;
        mouse = keys;
        keys = t;
        const ti = mouse_irq;
        mouse_irq = key_irq;
        key_irq = ti;
    };
    if (g.device("usb")) |dev| {
        // The controller's pages: rings, contexts and report buffers.
        var pages: [28]g.xhci.Page = undefined;
        for (&pages, 0..) |*pg, i| {
            const d = try g.virtio.Dma.alloc(&space, dma + 0x10000 + i * 0x1000);
            pg.* = .{ .va = d.va, .pa = d.pa };
        }
        const badged = try space.slot();
        if (!g.invoke(D.Slot.cnode, g.abi.CNodeMethod.mint, .{ badged, input_sig, (g.abi.Rights{ .send = true }).bits(), bit_usb, 0 }).ok()) return error.MintFailed;
        if (!g.invoke(dev.irq_slot, g.abi.IrqMethod.set_signal, .{badged}).ok()) return error.IrqSetup;
        usb_irq = dev.irq_slot;
        usb = try g.xhci.Xhci.init(dev.mmio, &pages, badged, dev.irq_slot);
        const found = usb.?.probe() catch |e| blk: {
            g.log("surf_usb_failed", .{ .err = @errorName(e) });
            break :blk 0;
        };
        g.log("surf_usb", .{ .devices = found });
    }
    if (g.bindSignal(input_sig) != .ok) return error.BindFailed;
    pointer = .{ .x = @divTrunc(screen.w, 2), .y = @divTrunc(screen.h, 2) };

    wins[0] = .{ .used = true, .badge = desktop_badge, .shown = true };
    setText(&wins[0].owner, &wins[0].owner_len, "surf");
    setText(&wins[0].title, &wins[0].title_len, "desktop");
    order[0] = 0;
    n_order = 1;
    refreshDesktop();
    const usb_has = struct {
        fn f(kind: enum { keyboard, tablet }) bool {
            const u = usb orelse return false;
            for (u.devices[0..u.device_count]) |d| if (@intFromEnum(d.kind) == @intFromEnum(kind)) return true;
            return false;
        }
    }.f;
    g.log("surf_ready", .{ .width = screen.w, .height = screen.h, .screen = @tagName(display), .keyboard = keys != null or usb_has(.keyboard), .pointer = mouse != null or usb_has(.tablet), .usb = usb != null });

    idl.recv_slot = try space.slot();
    var s: Server = .{};
    idl.serveAll(.{ P, SceneP }, g.provided("surf") orelse return error.NoService, &s);
}
