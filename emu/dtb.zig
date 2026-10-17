//! A flattened device tree writer (DTSpec v17), for the tree the machine
//! hands the kernel. Big-endian throughout; property names deduplicated.
const std = @import("std");

pub const Writer = struct {
    gpa: std.mem.Allocator,
    structs: std.ArrayList(u8) = .empty,
    strings: std.ArrayList(u8) = .empty,
    depth: usize = 0,

    const begin_node: u32 = 1;
    const end_node: u32 = 2;
    const prop_token: u32 = 3;
    const end_token: u32 = 9;

    pub fn init(gpa: std.mem.Allocator) Writer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(w: *Writer) void {
        w.structs.deinit(w.gpa);
        w.strings.deinit(w.gpa);
    }

    fn u32be(w: *Writer, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        try w.structs.appendSlice(w.gpa, &b);
    }

    fn pad(w: *Writer) !void {
        while (w.structs.items.len % 4 != 0) try w.structs.append(w.gpa, 0);
    }

    fn nameOffset(w: *Writer, name: []const u8) !u32 {
        var i: usize = 0;
        while (i < w.strings.items.len) {
            const end = std.mem.indexOfScalarPos(u8, w.strings.items, i, 0).?;
            if (std.mem.eql(u8, w.strings.items[i..end], name)) return @intCast(i);
            i = end + 1;
        }
        const off: u32 = @intCast(w.strings.items.len);
        try w.strings.appendSlice(w.gpa, name);
        try w.strings.append(w.gpa, 0);
        return off;
    }

    pub fn beginNode(w: *Writer, name: []const u8) !void {
        try w.u32be(begin_node);
        try w.structs.appendSlice(w.gpa, name);
        try w.structs.append(w.gpa, 0);
        try w.pad();
        w.depth += 1;
    }

    pub fn endNode(w: *Writer) !void {
        try w.u32be(end_node);
        w.depth -= 1;
    }

    pub fn prop(w: *Writer, name: []const u8, value: []const u8) !void {
        try w.u32be(prop_token);
        try w.u32be(@intCast(value.len));
        try w.u32be(try w.nameOffset(name));
        try w.structs.appendSlice(w.gpa, value);
        try w.pad();
    }

    pub fn empty(w: *Writer, name: []const u8) !void {
        try w.prop(name, "");
    }

    pub fn string(w: *Writer, name: []const u8, s: []const u8) !void {
        var buf: [256]u8 = undefined;
        @memcpy(buf[0..s.len], s);
        buf[s.len] = 0;
        try w.prop(name, buf[0 .. s.len + 1]);
    }

    /// A string list: the strings, each NUL-terminated.
    pub fn strings_(w: *Writer, name: []const u8, list: []const []const u8) !void {
        var buf: [256]u8 = undefined;
        var n: usize = 0;
        for (list) |s| {
            @memcpy(buf[n..][0..s.len], s);
            n += s.len;
            buf[n] = 0;
            n += 1;
        }
        try w.prop(name, buf[0..n]);
    }

    pub fn cells(w: *Writer, name: []const u8, values: []const u32) !void {
        var buf: [64 * 4]u8 = undefined;
        for (values, 0..) |v, i| std.mem.writeInt(u32, buf[4 * i ..][0..4], v, .big);
        try w.prop(name, buf[0 .. 4 * values.len]);
    }

    pub fn cell(w: *Writer, name: []const u8, v: u32) !void {
        try w.cells(name, &.{v});
    }

    /// `reg` with two address and two size cells.
    pub fn reg64(w: *Writer, base: u64, size: u64) !void {
        try w.cells("reg", &.{ @truncate(base >> 32), @truncate(base), @truncate(size >> 32), @truncate(size) });
    }

    /// The finished blob.
    pub fn finish(w: *Writer, gpa: std.mem.Allocator, boot_cpuid: u32) ![]u8 {
        std.debug.assert(w.depth == 0);
        try w.u32be(end_token);
        const header_size = 40;
        const rsvmap_off = header_size;
        const rsvmap_size = 16; // just the terminating entry
        const struct_off = rsvmap_off + rsvmap_size;
        const strings_off = struct_off + w.structs.items.len;
        const total = strings_off + w.strings.items.len;
        const out = try gpa.alloc(u8, std.mem.alignForward(usize, total, 8));
        @memset(out, 0);
        const fields = [_]u32{
            0xd00dfeed,                        @intCast(out.len),
            @intCast(struct_off),              @intCast(strings_off),
            rsvmap_off,                        17,
            16,                                boot_cpuid,
            @intCast(w.strings.items.len), @intCast(w.structs.items.len),
        };
        for (fields, 0..) |f, i| std.mem.writeInt(u32, out[4 * i ..][0..4], f, .big);
        @memcpy(out[struct_off..][0..w.structs.items.len], w.structs.items);
        @memcpy(out[strings_off..][0..w.strings.items.len], w.strings.items);
        return out;
    }
};
