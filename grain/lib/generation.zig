//! A generation: a whole bootable system (kernel, Steward, every program,
//! the manifest) as Tablecloth objects.
//!
//! The kernel's loadable segments are cut into chunks by content (a gear
//! rolling hash picks the cut points, so an edit moves only nearby cuts and
//! two generations share every chunk they have in common). A *descriptor*
//! lists, per segment, its physical address and sizes and the hashes of its
//! chunks; the descriptor's own hash names the whole system, and Aurora
//! checks every chunk against it before running a byte.
//!
//!     Header   magic "grgen001", entry (physical), segment and chunk counts,
//!              label (the system's name), closure (its manifest closure)
//!     Segment  paddr, memsz, filesz, first chunk, chunk count   (× segments)
//!     Hash     32 bytes                                          (× chunks)
const std = @import("std");

pub const magic = "grgen001".*;
pub const Hash = [32]u8;

pub const Header = extern struct {
    magic: [8]u8 = magic,
    /// Physical address to jump to, with a0 = hart id and a1 = the device tree.
    entry: u64,
    segments: u32,
    chunks: u32,
    label: [32]u8,
    closure: Hash,
};

pub const Segment = extern struct {
    paddr: u64,
    memsz: u64,
    filesz: u64,
    first_chunk: u32,
    chunks: u32,
};

pub const Error = error{ BadDescriptor, TooLarge };

pub const View = struct {
    header: Header,
    segments: []align(1) const Segment,
    hashes: []align(1) const Hash,

    pub fn parse(bytes: []const u8) Error!View {
        if (bytes.len < @sizeOf(Header)) return error.BadDescriptor;
        const h = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
        if (!std.mem.eql(u8, &h.magic, &magic)) return error.BadDescriptor;
        const seg_bytes = @as(usize, h.segments) * @sizeOf(Segment);
        const hash_bytes = @as(usize, h.chunks) * 32;
        if (bytes.len != @sizeOf(Header) + seg_bytes + hash_bytes) return error.BadDescriptor;
        const segs = std.mem.bytesAsSlice(Segment, bytes[@sizeOf(Header)..][0..seg_bytes]);
        for (segs) |s| if (s.filesz > s.memsz or @as(u64, s.first_chunk) + s.chunks > h.chunks) return error.BadDescriptor;
        return .{
            .header = h,
            .segments = segs,
            .hashes = std.mem.bytesAsSlice(Hash, bytes[@sizeOf(Header) + seg_bytes ..][0..hash_bytes]),
        };
    }

    pub fn label(v: *const View) []const u8 {
        return std.mem.sliceTo(&v.header.label, 0);
    }
};

// ---------------------------------------------------------------------------
// Content-defined chunking

pub const min_chunk = 8 * 1024;
pub const max_chunk = 64 * 1024;
/// Cut where the low 15 bits of the rolling hash are zero: ~32 KiB chunks.
const mask: u64 = (1 << 15) - 1;

/// 256 fixed pseudo-random words (splitmix64 from a constant seed). Part of
/// the format: changing them changes every cut point.
const gear = blk: {
    var t: [256]u64 = undefined;
    var x: u64 = 0x6772_6169_6e5f_6765; // "grain_ge"
    for (&t) |*w| {
        x +%= 0x9e37_79b9_7f4a_7c15;
        var z = x;
        z = (z ^ (z >> 30)) *% 0xbf58_476d_1ce4_e5b9;
        z = (z ^ (z >> 27)) *% 0x94d0_49bb_1331_11eb;
        w.* = z ^ (z >> 31);
    }
    break :blk t;
};

/// The length of the next chunk at the start of `data`.
pub fn nextChunk(data: []const u8) usize {
    if (data.len <= min_chunk) return data.len;
    const end = @min(data.len, max_chunk);
    var h: u64 = 0;
    var i: usize = min_chunk;
    while (i < end) : (i += 1) {
        h = (h << 1) +% gear[data[i]];
        if (h & mask == 0) return i + 1;
    }
    return end;
}

test "chunking is deterministic, bounded, and resynchronises after an edit" {
    var data: [600 * 1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(1);
    prng.random().bytes(&data);
    var cuts_a: [64]usize = undefined;
    var na: usize = 0;
    var off: usize = 0;
    while (off < data.len) {
        const n = nextChunk(data[off..]);
        try std.testing.expect(n <= max_chunk and (n >= min_chunk or off + n == data.len));
        off += n;
        cuts_a[na] = off;
        na += 1;
    }
    // Insert bytes near the start: later cut points shift by exactly that.
    var edited: [600 * 1024 + 100]u8 = undefined;
    @memcpy(edited[0..1000], data[0..1000]);
    @memset(edited[1000..1100], 0xAB);
    @memcpy(edited[1100..], data[1000..]);
    var shared: usize = 0;
    off = 0;
    while (off < edited.len) {
        off += nextChunk(edited[off..]);
        for (cuts_a[0..na]) |c| if (c + 100 == off) {
            shared += 1;
        };
    }
    try std.testing.expect(shared + 3 >= na);
}

test "descriptor round trip" {
    const segs = [_]Segment{.{ .paddr = 0x8020_0000, .memsz = 0x2000, .filesz = 0x1800, .first_chunk = 0, .chunks = 2 }};
    const hashes = [_]Hash{ @splat(1), @splat(2) };
    var h: Header = .{ .entry = 0x8020_0000, .segments = 1, .chunks = 2, .label = @splat(0), .closure = @splat(3) };
    @memcpy(h.label[0..4], "test");
    var buf: [@sizeOf(Header) + @sizeOf(Segment) + 64]u8 = undefined;
    @memcpy(buf[0..@sizeOf(Header)], std.mem.asBytes(&h));
    @memcpy(buf[@sizeOf(Header)..][0..@sizeOf(Segment)], std.mem.asBytes(&segs[0]));
    @memcpy(buf[@sizeOf(Header) + @sizeOf(Segment) ..], std.mem.sliceAsBytes(&hashes));
    const v = try View.parse(&buf);
    try std.testing.expectEqualStrings("test", v.label());
    try std.testing.expectEqual(@as(u8, 2), v.hashes[1][0]);
    try std.testing.expectError(error.BadDescriptor, View.parse(buf[0 .. buf.len - 1]));
}
