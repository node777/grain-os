//! Painting: rectangles, rounded panels and text into a 32-bit framebuffer.
//! Pure (no system calls), so the host tests what the screen will show.
//!
//! Pixels are 0x00RRGGBB in a u32: in memory B, G, R, X, the layout
//! virtio-gpu calls B8G8R8X8. Text is Grain Mono (font/LICENSE), one alpha
//! byte per pixel, blended over what is there.
const std = @import("std");

pub const font = struct {
    pub const w = 9;
    pub const h = 18;
    pub const baseline = 14;
    const atlas = @embedFile("font/mono.bin");

    /// The alpha mask of a printable ASCII character (others draw as '?').
    pub fn glyph(c: u8) *const [w * h]u8 {
        const i: usize = if (c >= 32 and c < 127) c - 32 else '?' - 32;
        return atlas[i * w * h ..][0 .. w * h];
    }

    comptime {
        std.debug.assert(atlas.len == 95 * w * h);
    }
};

pub const Color = u32;

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return @as(u32, r) << 16 | @as(u32, g) << 8 | b;
}

/// `a` over `b` with alpha `t` (0..255).
pub fn mix(a: Color, b: Color, t: u8) Color {
    var out: Color = 0;
    inline for (.{ 0, 8, 16 }) |s| {
        const ca: u32 = (a >> s) & 0xff;
        const cb: u32 = (b >> s) & 0xff;
        out |= ((ca * t + cb * (255 - t) + 127) / 255) << s;
    }
    return out;
}

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn empty(r: Rect) bool {
        return r.w <= 0 or r.h <= 0;
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }

    /// The smallest rectangle holding both (an empty one adds nothing).
    pub fn join(a: Rect, b: Rect) Rect {
        if (a.empty()) return b;
        if (b.empty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        return .{ .x = x0, .y = y0, .w = @max(a.x + a.w, b.x + b.w) - x0, .h = @max(a.y + a.h, b.y + b.h) - y0 };
    }

    pub fn contains(r: Rect, x: i32, y: i32) bool {
        return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
    }

    pub fn offset(r: Rect, dx: i32, dy: i32) Rect {
        return .{ .x = r.x + dx, .y = r.y + dy, .w = r.w, .h = r.h };
    }

    pub fn inset(r: Rect, d: i32) Rect {
        return .{ .x = r.x + d, .y = r.y + d, .w = r.w - 2 * d, .h = r.h - 2 * d };
    }
};

pub const Canvas = struct {
    px: []u32,
    w: u32,
    h: u32,
    /// Nothing outside this is touched.
    clip: Rect,

    pub fn init(px: []u32, w: u32, h: u32) Canvas {
        std.debug.assert(px.len >= @as(usize, w) * h);
        return .{ .px = px, .w = w, .h = h, .clip = .{ .w = @intCast(w), .h = @intCast(h) } };
    }

    pub fn at(c: *const Canvas, x: i32, y: i32) Color {
        return c.px[@as(usize, @intCast(y)) * c.w + @as(usize, @intCast(x))];
    }

    fn row(c: *Canvas, y: i32) []u32 {
        return c.px[@as(usize, @intCast(y)) * c.w ..][0..c.w];
    }

    pub fn fill(c: *Canvas, r: Rect, color: Color) void {
        const v = r.intersect(c.clip);
        if (v.empty()) return;
        var y = v.y;
        while (y < v.y + v.h) : (y += 1) @memset(c.row(y)[@intCast(v.x)..][0..@intCast(v.w)], color);
    }

    /// Fill with `color` at alpha `t`.
    pub fn tint(c: *Canvas, r: Rect, color: Color, t: u8) void {
        const v = r.intersect(c.clip);
        if (v.empty()) return;
        var y = v.y;
        while (y < v.y + v.h) : (y += 1) {
            for (c.row(y)[@intCast(v.x)..][0..@intCast(v.w)]) |*p| p.* = mix(color, p.*, t);
        }
    }

    /// A rectangle with corners rounded to `radius`, edges anti-aliased.
    pub fn panel(c: *Canvas, r: Rect, radius: i32, color: Color) void {
        const rad = @min(radius, @divTrunc(@min(r.w, r.h), 2));
        if (rad <= 0) return c.fill(r, color);
        c.fill(.{ .x = r.x, .y = r.y + rad, .w = r.w, .h = r.h - 2 * rad }, color);
        c.fill(.{ .x = r.x + rad, .y = r.y, .w = r.w - 2 * rad, .h = rad }, color);
        c.fill(.{ .x = r.x + rad, .y = r.y + r.h - rad, .w = r.w - 2 * rad, .h = rad }, color);
        // The four corners: coverage of each pixel by the quarter disc,
        // sampled 4x4 (in eighths of a pixel, so integers suffice).
        var dy: i32 = 0;
        while (dy < rad) : (dy += 1) {
            var dx: i32 = 0;
            while (dx < rad) : (dx += 1) {
                var hits: u32 = 0;
                for (0..4) |sy| for (0..4) |sx| {
                    const fx = (rad - dx) * 8 - (2 * @as(i32, @intCast(sx)) + 1);
                    const fy = (rad - dy) * 8 - (2 * @as(i32, @intCast(sy)) + 1);
                    if (fx * fx + fy * fy <= rad * rad * 64) hits += 1;
                };
                if (hits == 0) continue;
                const t: u8 = @intCast(hits * 255 / 16);
                const corners = [_][2]i32{ .{ r.x + dx, r.y + dy }, .{ r.x + r.w - 1 - dx, r.y + dy }, .{ r.x + dx, r.y + r.h - 1 - dy }, .{ r.x + r.w - 1 - dx, r.y + r.h - 1 - dy } };
                for (corners) |p| c.plot(p[0], p[1], color, t);
            }
        }
    }

    pub fn plot(c: *Canvas, x: i32, y: i32, color: Color, t: u8) void {
        if (!c.clip.contains(x, y)) return;
        const p = &c.row(y)[@intCast(x)];
        p.* = if (t == 255) color else mix(color, p.*, t);
    }

    /// A one-pixel outline.
    pub fn outline(c: *Canvas, r: Rect, color: Color) void {
        c.fill(.{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, color);
        c.fill(.{ .x = r.x, .y = r.y + r.h - 1, .w = r.w, .h = 1 }, color);
        c.fill(.{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, color);
        c.fill(.{ .x = r.x + r.w - 1, .y = r.y, .w = 1, .h = r.h }, color);
    }

    /// Text with its cell's top-left at (x, y); returns the width drawn.
    pub fn text(c: *Canvas, x: i32, y: i32, s: []const u8, color: Color) i32 {
        var cx = x;
        for (s) |ch| {
            if (ch != ' ') {
                const g = font.glyph(ch);
                for (0..font.h) |gy| for (0..font.w) |gx| {
                    const a = g[gy * font.w + gx];
                    if (a != 0) c.plot(cx + @as(i32, @intCast(gx)), y + @as(i32, @intCast(gy)), color, a);
                };
            }
            cx += font.w;
        }
        return cx - x;
    }
};

pub fn textWidth(s: []const u8) i32 {
    return @intCast(s.len * font.w);
}

const testing = std.testing;

test "fills clip, panels round their corners, text lands where asked" {
    var px: [64 * 40]u32 = @splat(0);
    var c = Canvas.init(&px, 64, 40);
    c.fill(.{ .x = -10, .y = -10, .w = 20, .h = 20 }, 0xff0000);
    try testing.expectEqual(@as(Color, 0xff0000), c.at(0, 0));
    try testing.expectEqual(@as(Color, 0xff0000), c.at(9, 9));
    try testing.expectEqual(@as(Color, 0), c.at(10, 10));

    @memset(&px, 0);
    c.panel(.{ .x = 10, .y = 10, .w = 30, .h = 20 }, 6, 0xffffff);
    try testing.expectEqual(@as(Color, 0), c.at(10, 10)); // the corner is cut
    try testing.expectEqual(@as(Color, 0xffffff), c.at(25, 20)); // the middle is full
    try testing.expectEqual(@as(Color, 0xffffff), c.at(10, 20)); // the edge is full
    const edge = c.at(11, 12) & 0xff;
    try testing.expect(edge > 0 and edge < 255); // the curve is anti-aliased

    @memset(&px, 0);
    c.clip = .{ .x = 0, .y = 0, .w = 64, .h = 40 };
    try testing.expectEqual(@as(i32, 2 * font.w), c.text(5, 5, "Hi", 0xffffff));
    var lit: usize = 0;
    for (px, 0..) |p, i| if (p != 0) {
        lit += 1;
        const x = i % 64;
        const y = i / 64;
        try testing.expect(x >= 5 and x < 5 + 2 * font.w and y >= 5 and y < 5 + font.h);
    };
    try testing.expect(lit > 20);
}

test "mix and rectangles" {
    try testing.expectEqual(@as(Color, 0x808080), mix(0xffffff, 0, 128));
    try testing.expectEqual(@as(Color, 0x123456), mix(0x123456, 0xabcdef, 255));
    const a: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b: Rect = .{ .x = 5, .y = 5, .w = 10, .h = 10 };
    try testing.expectEqual(Rect{ .x = 5, .y = 5, .w = 5, .h = 5 }, a.intersect(b));
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 15, .h = 15 }, a.join(b));
    try testing.expect(a.intersect(.{ .x = 20, .y = 20, .w = 1, .h = 1 }).empty());
}
