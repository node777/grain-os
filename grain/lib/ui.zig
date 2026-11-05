//! ui: widgets for applications on the desktop, drawn as brushstrokes.
//!
//! Immediate mode, which suits Surf: a window is a list of strokes rebuilt
//! whole for every frame, so an application describes its window each
//! time from its own state ("a heading, a field, a table of these rows"),
//! and the widgets say what the owner did to them. A frame runs twice per
//! event: once with the event and nothing drawn (the widgets consume it and
//! the application's state changes), then once to draw. Element ids are
//! given out in order, so the same state gives the same ids: a click on
//! the frame shown finds its widget on the next pass.
//!
//! Every widget gives its strokes a role (button, input, row, cell, tab,
//! ...), so whoever reads the screen through scene.v1 (an agent) reads the
//! window as the owner sees it. This file draws through a `Sink` and knows
//! nothing of IPC: proto/surf.zig connects it to a window.
const std = @import("std");
const paint = @import("paint.zig");

pub const Kind = enum { fill, panel, text, outline };

pub const Box = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn contains(b: Box, x: i32, y: i32) bool {
        return x >= b.x and y >= b.y and x < b.x + b.w and y < b.y + b.h;
    }
};

/// Where strokes go: a window (proto/surf.zig), or a test's list.
pub const Sink = struct {
    ctx: *anyopaque,
    add: *const fn (ctx: *anyopaque, kind: Kind, b: Box, color: u32, id: u16, role: []const u8, text: []const u8) void,
};

pub const Theme = struct {
    background: u32,
    text: u32,
    muted: u32,
    accent: u32,
    button: u32,
    button_hot: u32,
    field: u32,
    border: u32,
    selected: u32,
    danger: u32,
    ok: u32,
};

pub const dark: Theme = .{
    .background = 0x221d30,
    .text = 0xe9dfcf,
    .muted = 0x9d93b3,
    .accent = 0x8fd1b5,
    .button = 0x3d355a,
    .button_hot = 0x7a6aa8,
    .field = 0x2b2540,
    .border = 0x4a4166,
    .selected = 0x3d355a,
    .danger = 0xf0a07a,
    .ok = 0x8fd1b5,
};

pub const light: Theme = .{
    .background = 0xf6f1e8,
    .text = 0x2b2433,
    .muted = 0x7a7088,
    .accent = 0x2f6b4f,
    .button = 0xe2d9cc,
    .button_hot = 0xb8a6e0,
    .field = 0xfffaf2,
    .border = 0xcfc4b4,
    .selected = 0xe7dcf5,
    .danger = 0xa12d2d,
    .ok = 0x2f6b4f,
};

/// What the owner did since the last frame (at most one thing).
pub const Input = struct {
    click: ?struct { x: i32, y: i32, id: u16 } = null,
    key: ?struct { char: u8, code: u16 } = null,
};

pub const char_w = paint.font.w;
pub const char_h = paint.font.h;
pub const pad = 12;
pub const gap = 8;
pub const line_h = 22;
pub const button_h = 26;

pub const key_up: u16 = 103;
pub const key_down: u16 = 108;
pub const key_page_up: u16 = 104;
pub const key_page_down: u16 = 109;
pub const key_tab: u16 = 15;

/// A line of text the owner edits.
pub const Field = struct {
    buf: [96]u8 = undefined,
    len: u8 = 0,
    /// Shown as dots (a passphrase).
    secret: bool = false,

    pub fn text(f: *const Field) []const u8 {
        return f.buf[0..f.len];
    }

    pub fn set(f: *Field, s: []const u8) void {
        f.len = @intCast(@min(s.len, f.buf.len));
        @memcpy(f.buf[0..f.len], s[0..f.len]);
    }

    pub fn clear(f: *Field) void {
        f.len = 0;
    }
};

pub const FieldResult = enum { none, edited, submitted };

pub const Column = struct {
    title: []const u8,
    /// Width in characters.
    chars: u16,
    right: bool = false,
};

pub const TableState = struct {
    selected: ?usize = null,
    /// The first row shown.
    scroll: usize = 0,
};

pub const Ui = struct {
    sink: ?Sink,
    theme: *const Theme,
    width: i32,
    height: i32,
    input: Input,
    /// The focused field's id, kept by the application between frames.
    focus: *u16,
    /// Strokes the window takes in all.
    max_strokes: u16,

    strokes: u16 = 0,
    overflow: bool = false,
    next_id: u16 = 1,
    /// The input was taken by a widget.
    handled: bool = false,
    /// Layout: the next widget goes at (left, y), or beside the last one.
    left: i32 = pad,
    right: i32 = 0,
    y: i32 = pad,
    last: Box = .{},
    same_line: bool = false,
    /// The next widget goes exactly here (moveTo).
    next_at: ?struct { x: i32, y: i32 } = null,
    /// Fields seen this frame, for Tab to move between.
    fields: [16]u16 = undefined,
    n_fields: u8 = 0,

    pub fn init(sink: ?Sink, theme: *const Theme, width: i32, height: i32, input: Input, focus: *u16, max_strokes: u16) Ui {
        var ui: Ui = .{ .sink = sink, .theme = theme, .width = width, .height = height, .input = input, .focus = focus, .max_strokes = max_strokes };
        ui.right = width - pad;
        return ui;
    }

    pub fn drawing(ui: *const Ui) bool {
        return ui.sink != null;
    }

    // --- Strokes and ids

    pub fn emit(ui: *Ui, kind: Kind, b: Box, color: u32, id: u16, role: []const u8, text: []const u8) void {
        const s = ui.sink orelse return;
        if (ui.strokes == ui.max_strokes) {
            ui.overflow = true;
            return;
        }
        s.add(s.ctx, kind, b, color, id, role, text);
        ui.strokes += 1;
    }

    fn newId(ui: *Ui) u16 {
        const id = ui.next_id;
        ui.next_id +%= 1;
        return id;
    }

    fn clicked(ui: *Ui, id: u16) bool {
        const c = ui.input.click orelse return false;
        if (c.id != id or ui.handled) return false;
        ui.handled = true;
        return true;
    }

    /// The key typed, if no widget took it (the application's to use).
    pub fn key(ui: *const Ui) ?@TypeOf(ui.input.key.?) {
        if (ui.handled) return null;
        return ui.input.key;
    }

    /// Finish a frame: Tab moves focus to the next field.
    pub fn end(ui: *Ui) void {
        const k = ui.key() orelse return;
        if (k.code != key_tab or ui.n_fields == 0) return;
        var next: u16 = ui.fields[0];
        for (ui.fields[0..ui.n_fields], 0..) |id, i| if (id == ui.focus.*) {
            next = ui.fields[(i + 1) % ui.n_fields];
        };
        ui.focus.* = next;
        ui.handled = true;
    }

    // --- Layout

    /// Room for a widget `w` by `h`, beside the last one after sameLine().
    pub fn place(ui: *Ui, w: i32, h: i32) Box {
        if (ui.next_at) |p| {
            ui.next_at = null;
            ui.same_line = false;
            const b: Box = .{ .x = p.x, .y = p.y, .w = w, .h = h };
            ui.last = b;
            return b;
        }
        const b: Box = if (ui.same_line)
            .{ .x = ui.last.x + ui.last.w + gap, .y = ui.last.y, .w = w, .h = h }
        else
            .{ .x = ui.left, .y = ui.y, .w = w, .h = h };
        ui.same_line = false;
        ui.last = b;
        ui.y = @max(ui.y, b.y + b.h + gap);
        return b;
    }

    /// The next widget goes at (x, y), outside the flow (the flow goes on
    /// where it was).
    pub fn moveTo(ui: *Ui, x: i32, y: i32) void {
        ui.next_at = .{ .x = x, .y = y };
    }

    /// The next field has the keyboard (an application with one line to
    /// type into, like a shell, keeps it there).
    pub fn focusNext(ui: *Ui) void {
        ui.focus.* = ui.next_id;
    }

    /// The next widget goes to the right of the last one.
    pub fn sameLine(ui: *Ui) void {
        ui.same_line = true;
    }

    /// The width left on this line (after sameLine), or the full width.
    pub fn room(ui: *const Ui) i32 {
        const from = if (ui.same_line) ui.last.x + ui.last.w + gap else ui.left;
        return ui.right - from;
    }

    pub fn space(ui: *Ui, px: i32) void {
        ui.y += px;
    }

    // --- Widgets

    pub fn background(ui: *Ui) void {
        ui.emit(.fill, .{ .w = ui.width, .h = ui.height }, ui.theme.background, 0, "background", "");
    }

    pub fn heading(ui: *Ui, text: []const u8) void {
        const b = ui.place(textW(text), char_h + 4);
        ui.emit(.text, .{ .x = b.x, .y = b.y }, ui.theme.accent, 0, "heading", text);
    }

    pub fn label(ui: *Ui, text: []const u8) void {
        ui.labelAs(text, ui.theme.text, "label");
    }

    pub fn muted(ui: *Ui, text: []const u8) void {
        ui.labelAs(text, ui.theme.muted, "label");
    }

    pub fn labelAs(ui: *Ui, text: []const u8, color: u32, role: []const u8) void {
        const t = fit(text, ui.room());
        const b = ui.place(textW(t), char_h);
        ui.emit(.text, .{ .x = b.x, .y = b.y }, color, 0, role, t);
    }

    pub fn labelf(ui: *Ui, comptime fmt: []const u8, args: anytype) void {
        var buf: [160]u8 = undefined;
        ui.label(std.fmt.bufPrint(&buf, fmt, args) catch buf[0..]);
    }

    /// A row of label and value, the value lined up at `at` characters in.
    pub fn pair(ui: *Ui, name: []const u8, value: []const u8, at: i32) void {
        const b = ui.place(ui.right - ui.left, char_h);
        ui.emit(.text, .{ .x = b.x, .y = b.y }, ui.theme.muted, 0, "label", name);
        const vx = b.x + at * char_w;
        ui.emit(.text, .{ .x = vx, .y = b.y }, ui.theme.text, 0, "value", fit(value, ui.right - vx));
    }

    pub fn separator(ui: *Ui) void {
        const b = ui.place(ui.right - ui.left, 1);
        ui.emit(.fill, b, ui.theme.border, 0, "separator", "");
    }

    /// A button; true when it was clicked.
    pub fn button(ui: *Ui, text: []const u8) bool {
        return ui.buttonAs(text, ui.theme.button);
    }

    pub fn buttonAs(ui: *Ui, text: []const u8, color: u32) bool {
        const id = ui.newId();
        const b = ui.place(textW(text) + 2 * pad, button_h);
        ui.emit(.panel, b, color, id, "button", text);
        return ui.clicked(id);
    }

    /// A line of text to edit. Click it to give it the keyboard; Enter
    /// submits; Tab moves to the next field.
    pub fn field(ui: *Ui, f: *Field, width: i32, placeholder: []const u8) FieldResult {
        const id = ui.newId();
        if (ui.n_fields < ui.fields.len) {
            ui.fields[ui.n_fields] = id;
            ui.n_fields += 1;
        }
        const b = ui.place(@min(width, ui.room()), button_h);
        if (ui.clicked(id)) ui.focus.* = id;
        const focused = ui.focus.* == id;
        var result: FieldResult = .none;
        if (focused and !ui.handled) if (ui.input.key) |k| switch (k.char) {
            '\n' => {
                result = .submitted;
                ui.handled = true;
            },
            0x08 => {
                if (f.len > 0) f.len -= 1;
                result = .edited;
                ui.handled = true;
            },
            else => |c| if (c >= ' ' and c < 127 and f.len < f.buf.len) {
                f.buf[f.len] = c;
                f.len += 1;
                result = .edited;
                ui.handled = true;
            },
        };
        if (ui.drawing()) {
            ui.emit(.fill, b, ui.theme.field, id, "input", "");
            ui.emit(.outline, b, if (focused) ui.theme.accent else ui.theme.border, 0, "border", "");
            const shown_max: usize = @intCast(@max(0, @divTrunc(b.w - 2 * gap - 4, char_w)));
            var dots: [96]u8 = @splat('*');
            const full = if (f.secret) dots[0..f.len] else f.text();
            // Keep the end in view while typing.
            const shown = full[full.len -| shown_max..];
            const ty = b.y + @divTrunc(b.h - char_h, 2);
            if (shown.len == 0 and !focused) {
                ui.emit(.text, .{ .x = b.x + gap, .y = ty }, ui.theme.muted, 0, "placeholder", fit(placeholder, b.w - 2 * gap));
            } else {
                ui.emit(.text, .{ .x = b.x + gap, .y = ty }, ui.theme.text, 0, if (f.secret) "secret" else "value", shown);
            }
            if (focused) ui.emit(.fill, .{ .x = b.x + gap + textW(shown) + 1, .y = ty + 2, .w = 2, .h = char_h - 4 }, ui.theme.accent, 0, "cursor", "");
        }
        return result;
    }

    /// Tabs across the window; true when the owner chose another.
    pub fn tabs(ui: *Ui, names: []const []const u8, current: *usize) bool {
        var changed = false;
        for (names, 0..) |name, i| {
            const id = ui.newId();
            if (i > 0) ui.sameLine();
            const b = ui.place(textW(name) + 2 * pad, button_h);
            const on = current.* == i;
            ui.emit(.panel, b, if (on) ui.theme.button_hot else ui.theme.button, id, if (on) "tab_selected" else "tab", name);
            if (ui.clicked(id) and !on) {
                current.* = i;
                changed = true;
            }
        }
        ui.separator();
        return changed;
    }

    /// A box to tick; true when it changed.
    pub fn toggle(ui: *Ui, text: []const u8, on: *bool) bool {
        const id = ui.newId();
        const b = ui.place(16 + gap + textW(text), char_h + 2);
        const boxr: Box = .{ .x = b.x, .y = b.y + 1, .w = 16, .h = 16 };
        // The whole line answers clicks: an invisible fill under it.
        ui.emit(.fill, b, ui.theme.background, id, if (on.*) "toggle_on" else "toggle_off", "");
        ui.emit(.outline, boxr, ui.theme.border, 0, "border", "");
        if (on.*) ui.emit(.fill, .{ .x = boxr.x + 4, .y = boxr.y + 4, .w = 8, .h = 8 }, ui.theme.accent, 0, "tick", "");
        ui.emit(.text, .{ .x = b.x + 16 + gap, .y = b.y }, ui.theme.text, 0, "label", text);
        if (ui.clicked(id)) {
            on.* = !on.*;
            return true;
        }
        return false;
    }

    /// A bar filled to `permille` of its width, with a label on it.
    pub fn meter(ui: *Ui, permille: u32, width: i32, text: []const u8) void {
        const b = ui.place(@min(width, ui.room()), char_h + 4);
        const fill_w = @divTrunc(b.w * @as(i32, @intCast(@min(permille, 1000))), 1000);
        ui.emit(.fill, b, ui.theme.field, 0, "meter", "");
        if (fill_w > 0) ui.emit(.fill, .{ .x = b.x, .y = b.y, .w = fill_w, .h = b.h }, ui.theme.button_hot, 0, "meter_fill", "");
        ui.emit(.text, .{ .x = b.x + gap, .y = b.y + 2 }, ui.theme.text, 0, "label", fit(text, b.w - 2 * gap));
    }

    /// Rows of cells under column titles, `visible` at a time. A click
    /// selects a row (returned); with no field focused, Up and Down move the
    /// selection and Page Up and Page Down the view. `cells` has
    /// `fn cell(self, row: usize, col: usize, buf: []u8) []const u8`.
    pub fn table(ui: *Ui, cols: []const Column, rows: usize, visible: usize, st: *TableState, cells: anytype) ?usize {
        var picked: ?usize = null;
        // Keys first, so this frame shows where they lead.
        if (!ui.handled and rows > 0) if (ui.input.key) |k| {
            const sel = st.selected orelse 0;
            const moved: ?usize = switch (k.code) {
                key_up => if (st.selected == null) 0 else sel -| 1,
                key_down => if (st.selected == null) 0 else @min(sel + 1, rows - 1),
                key_page_up => sel -| visible,
                key_page_down => @min(sel + visible, rows - 1),
                else => null,
            };
            if (moved) |m| {
                st.selected = m;
                picked = m;
                ui.handled = true;
                // The view follows the selection when the selection moves
                // (not when the owner pages the view away from it).
                if (m < st.scroll) st.scroll = m;
                if (m >= st.scroll + visible) st.scroll = m + 1 - visible;
            }
        };
        if (st.selected) |s| {
            if (s >= rows) st.selected = if (rows > 0) rows - 1 else null;
        }
        st.scroll = @min(st.scroll, rows -| visible);

        var width: i32 = 0;
        for (cols) |c| width += @as(i32, c.chars) * char_w + 2 * gap;
        width = @min(width, ui.right - ui.left);
        const head = ui.place(width, line_h);
        var x = head.x;
        for (cols) |c| {
            const cw = @as(i32, c.chars) * char_w;
            ui.emit(.text, .{ .x = if (c.right) x + gap + cw - textW(c.title) else x + gap, .y = head.y + 2 }, ui.theme.muted, 0, "column", fit(c.title, cw));
            x += cw + 2 * gap;
        }
        ui.emit(.fill, .{ .x = head.x, .y = head.y + line_h - 2, .w = width, .h = 1 }, ui.theme.border, 0, "separator", "");
        ui.y = head.y + line_h;
        const shown = @min(visible, rows - st.scroll);
        for (0..visible) |k| {
            const id = ui.newId();
            const row = st.scroll + k;
            const rb: Box = .{ .x = head.x, .y = ui.y + @as(i32, @intCast(k)) * line_h, .w = width, .h = line_h };
            if (k >= shown) continue;
            const sel = st.selected == row;
            if (ui.clicked(id)) {
                st.selected = row;
                picked = row;
            }
            if (!ui.drawing()) continue;
            ui.emit(.fill, rb, if (sel) ui.theme.selected else ui.theme.background, id, if (sel) "row_selected" else "row", "");
            x = rb.x;
            for (cols, 0..) |c, ci| {
                var buf: [120]u8 = undefined;
                const cw = @as(i32, c.chars) * char_w;
                const t = fit(cells.cell(row, ci, &buf), cw);
                ui.emit(.text, .{ .x = if (c.right) x + gap + cw - textW(t) else x + gap, .y = rb.y + 2 }, ui.theme.text, 0, "cell", t);
                x += cw + 2 * gap;
            }
        }
        ui.y += @as(i32, @intCast(visible)) * line_h + gap;
        ui.last = .{ .x = head.x, .y = head.y, .w = width, .h = ui.y - head.y };
        if (rows > visible) {
            var buf: [48]u8 = undefined;
            ui.muted(std.fmt.bufPrint(&buf, "rows {d}-{d} of {d}", .{ st.scroll + 1, st.scroll + shown, rows }) catch "");
            ui.sameLine();
            if (ui.button("up")) st.scroll -|= visible;
            ui.sameLine();
            if (ui.button("down")) st.scroll = @min(st.scroll + visible, rows - visible);
        }
        return picked;
    }
};

pub fn textW(s: []const u8) i32 {
    return @as(i32, @intCast(s.len)) * char_w;
}

/// As much of `s` as fits in `px` pixels, ending in "~" when cut.
pub fn fit(s: []const u8, px: i32) []const u8 {
    const n: usize = @intCast(@max(0, @divTrunc(px, char_w)));
    if (s.len <= n) return s;
    if (n == 0) return s[0..0];
    return s[0 .. n - 1];
}

// ---------------------------------------------------------------------------
// Tests: a sink that keeps the strokes.

const Kept = struct {
    kind: Kind,
    box: Box,
    color: u32,
    id: u16,
    role: [16]u8,
    role_len: u8,
    text: [120]u8,
    text_len: u8,

    fn roleS(k: *const Kept) []const u8 {
        return k.role[0..k.role_len];
    }
    fn textS(k: *const Kept) []const u8 {
        return k.text[0..k.text_len];
    }
};

const Rec = struct {
    kept: [256]Kept = undefined,
    n: usize = 0,

    fn add(ctx: *anyopaque, kind: Kind, b: Box, color: u32, id: u16, role: []const u8, text: []const u8) void {
        const r: *Rec = @ptrCast(@alignCast(ctx));
        var k: Kept = .{ .kind = kind, .box = b, .color = color, .id = id, .role = undefined, .role_len = @intCast(role.len), .text = undefined, .text_len = @intCast(text.len) };
        @memcpy(k.role[0..role.len], role);
        @memcpy(k.text[0..text.len], text);
        r.kept[r.n] = k;
        r.n += 1;
    }

    fn sink(r: *Rec) Sink {
        return .{ .ctx = r, .add = add };
    }

    fn find(r: *const Rec, role: []const u8, text: []const u8) ?*const Kept {
        for (r.kept[0..r.n]) |*k| if (std.mem.eql(u8, k.roleS(), role) and std.mem.eql(u8, k.textS(), text)) return k;
        return null;
    }

    fn count(r: *const Rec, role: []const u8) usize {
        var n: usize = 0;
        for (r.kept[0..r.n]) |*k| n += @intFromBool(std.mem.eql(u8, k.roleS(), role));
        return n;
    }
};

const Demo = struct {
    name: Field = .{},
    focus: u16 = 0,
    saved: usize = 0,
    tab: usize = 0,
    flag: bool = false,
    table: TableState = .{},

    fn draw(d: *Demo, ui: *Ui) void {
        ui.background();
        ui.heading("demo");
        _ = ui.tabs(&.{ "one", "two" }, &d.tab);
        if (ui.field(&d.name, 200, "your name") == .submitted) d.saved += 1;
        ui.sameLine();
        if (ui.button("save")) d.saved += 1;
        _ = ui.toggle("loud", &d.flag);
        _ = ui.table(&.{ .{ .title = "n", .chars = 3, .right = true }, .{ .title = "square", .chars = 8 } }, 10, 4, &d.table, d);
        ui.end();
    }

    pub fn cell(_: *Demo, row: usize, col: usize, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}", .{if (col == 0) row else row * row}) catch "";
    }
};

/// One event through both passes, as an application does it; the strokes drawn after.
fn step(d: *Demo, rec: *Rec, input: Input) void {
    var handle = Ui.init(null, &dark, 400, 300, input, &d.focus, 192);
    d.draw(&handle);
    rec.n = 0;
    var draw = Ui.init(rec.sink(), &dark, 400, 300, .{}, &d.focus, 192);
    d.draw(&draw);
}

fn clickOn(rec: *const Rec, role: []const u8, text: []const u8) Input {
    const k = rec.find(role, text).?;
    return .{ .click = .{ .x = k.box.x + 1, .y = k.box.y + 1, .id = k.id } };
}

test "a button reports the click on the frame that showed it" {
    var d: Demo = .{};
    var rec: Rec = .{};
    step(&d, &rec, .{});
    const save = rec.find("button", "save").?;
    try std.testing.expect(save.id != 0);
    step(&d, &rec, clickOn(&rec, "button", "save"));
    try std.testing.expectEqual(@as(usize, 1), d.saved);
    // The same state gives the same ids.
    try std.testing.expectEqual(save.id, rec.find("button", "save").?.id);
}

test "a field takes keys once clicked, and Enter submits" {
    var d: Demo = .{};
    var rec: Rec = .{};
    step(&d, &rec, .{});
    // Not focused: a key goes nowhere.
    step(&d, &rec, .{ .key = .{ .char = 'x', .code = 45 } });
    try std.testing.expectEqual(@as(u8, 0), d.name.len);
    const field_id = for (rec.kept[0..rec.n]) |*k| {
        if (std.mem.eql(u8, k.roleS(), "input")) break k.id;
    } else unreachable;
    step(&d, &rec, .{ .click = .{ .x = 0, .y = 0, .id = field_id } });
    for ("ada") |c| step(&d, &rec, .{ .key = .{ .char = c, .code = 0 } });
    try std.testing.expectEqualStrings("ada", d.name.text());
    try std.testing.expect(rec.find("value", "ada") != null);
    try std.testing.expect(rec.find("cursor", "") != null);
    step(&d, &rec, .{ .key = .{ .char = 0x08, .code = 14 } });
    try std.testing.expectEqualStrings("ad", d.name.text());
    step(&d, &rec, .{ .key = .{ .char = '\n', .code = 28 } });
    try std.testing.expectEqual(@as(usize, 1), d.saved);
}

test "a secret field shows dots" {
    var f: Field = .{ .secret = true };
    f.set("hunter2");
    var focus: u16 = 0;
    var rec: Rec = .{};
    var ui = Ui.init(rec.sink(), &dark, 400, 300, .{}, &focus, 64);
    _ = ui.field(&f, 200, "");
    try std.testing.expect(rec.find("secret", "*******") != null);
    try std.testing.expect(rec.find("value", "hunter2") == null);
}

test "tabs, toggles and sameLine" {
    var d: Demo = .{};
    var rec: Rec = .{};
    step(&d, &rec, .{});
    try std.testing.expect(rec.find("tab_selected", "one") != null);
    step(&d, &rec, clickOn(&rec, "tab", "two"));
    try std.testing.expectEqual(@as(usize, 1), d.tab);
    try std.testing.expect(rec.find("tab_selected", "two") != null);
    step(&d, &rec, clickOn(&rec, "toggle_off", ""));
    try std.testing.expect(d.flag);
    // The button sits to the right of the field, on its line.
    const save = rec.find("button", "save").?;
    const input = for (rec.kept[0..rec.n]) |*k| {
        if (std.mem.eql(u8, k.roleS(), "input")) break k;
    } else unreachable;
    try std.testing.expectEqual(input.box.y, save.box.y);
    try std.testing.expect(save.box.x >= input.box.x + input.box.w);
}

test "a table selects by click and by keys, and scrolls to the selection" {
    var d: Demo = .{};
    var rec: Rec = .{};
    step(&d, &rec, .{});
    try std.testing.expectEqual(@as(usize, 4), rec.count("row"));
    try std.testing.expect(rec.find("cell", "9") != null); // row 3, squared
    try std.testing.expect(rec.find("label", "rows 1-4 of 10") != null);
    const third = for (rec.kept[0..rec.n]) |*k| {
        if (std.mem.eql(u8, k.roleS(), "row")) {
            if (k.box.y > rec.find("column", "n").?.box.y + 2 * line_h) break k.id;
        }
    } else unreachable;
    step(&d, &rec, .{ .click = .{ .x = 0, .y = 0, .id = third } });
    try std.testing.expectEqual(@as(?usize, 2), d.table.selected);
    try std.testing.expectEqual(@as(usize, 1), rec.count("row_selected"));
    // Down past the bottom of the view scrolls it.
    for (0..3) |_| step(&d, &rec, .{ .key = .{ .char = 0, .code = key_down } });
    try std.testing.expectEqual(@as(?usize, 5), d.table.selected);
    try std.testing.expectEqual(@as(usize, 2), d.table.scroll);
    try std.testing.expect(rec.find("cell", "25") != null);
    step(&d, &rec, clickOn(&rec, "button", "down"));
    try std.testing.expectEqual(@as(usize, 6), d.table.scroll);
}

test "Tab moves between fields; strokes stop at the window's limit" {
    var a: Field = .{};
    var b: Field = .{};
    var focus: u16 = 0;
    for (0..2) |_| {
        var ui = Ui.init(null, &dark, 400, 300, .{ .key = .{ .char = '\t', .code = key_tab } }, &focus, 64);
        _ = ui.field(&a, 100, "");
        _ = ui.field(&b, 100, "");
        ui.end();
    }
    try std.testing.expectEqual(@as(u16, 2), focus);
    var rec: Rec = .{};
    var ui = Ui.init(rec.sink(), &dark, 400, 300, .{}, &focus, 3);
    for (0..5) |_| ui.label("x");
    try std.testing.expectEqual(@as(usize, 3), rec.n);
    try std.testing.expect(ui.overflow);
}

test "moveTo places one widget outside the flow; focusNext gives a field the keys" {
    var f: Field = .{};
    var focus: u16 = 0;
    for ("hi") |c| {
        var ui = Ui.init(null, &dark, 400, 300, .{ .key = .{ .char = c, .code = 0 } }, &focus, 64);
        ui.moveTo(300, 10);
        _ = ui.button("clear");
        ui.focusNext();
        _ = ui.field(&f, 200, "");
    }
    try std.testing.expectEqualStrings("hi", f.text());
    var rec: Rec = .{};
    var ui = Ui.init(rec.sink(), &dark, 400, 300, .{}, &focus, 64);
    ui.moveTo(300, 10);
    _ = ui.button("clear");
    ui.label("first");
    try std.testing.expectEqual(@as(i32, 300), rec.find("button", "clear").?.box.x);
    try std.testing.expectEqual(@as(i32, pad), rec.find("label", "first").?.box.y);
}

test "fit cuts what does not fit" {
    try std.testing.expectEqualStrings("hello", fit("hello", 5 * char_w));
    try std.testing.expectEqualStrings("hel", fit("hello", 4 * char_w));
    try std.testing.expectEqualStrings("", fit("hello", 0));
}
