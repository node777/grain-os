//! The Grain boot image: the manifest plus every program it names, each
//! identified by its BLAKE3 hash, and one closure hash over all of it.
//!
//! The closure hash names the whole system, as a NixOS store path does: the
//! same manifest and the same program bytes give the same hash, and any
//! change gives a different one. `grain-pack` writes images at build time;
//! Steward reads one at boot, recomputes every hash, and refuses to start a
//! program whose bytes do not match.
//!
//! Layout (little-endian):
//!
//!   Header    64 bytes   magic, version, entry count, manifest offset/len, closure hash
//!   Entry[n]  80 bytes   name, offset, size, hash
//!   data                 manifest bytes, then each program, 8-byte aligned
const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

pub const magic: u64 = std.mem.readInt(u64, "GRAINIMG", .little);
pub const version: u32 = 1;
pub const max_entries = 32;
pub const name_len = 24;
pub const Hash = [32]u8;

pub const Header = extern struct {
    magic: u64,
    version: u32,
    count: u32,
    manifest_offset: u64,
    manifest_size: u64,
    closure: Hash,
};

pub const Entry = extern struct {
    name: [name_len]u8,
    offset: u64,
    size: u64,
    hash: Hash,
    _pad: [8]u8 = @splat(0),

    pub fn nameSlice(e: *align(1) const Entry) []const u8 {
        return std.mem.sliceTo(&e.name, 0);
    }
};

comptime {
    std.debug.assert(@sizeOf(Header) == 64);
    std.debug.assert(@sizeOf(Entry) == 80);
}

pub const Error = error{ BadMagic, BadVersion, Truncated, TooManyEntries, HashMismatch, ClosureMismatch, NameTooLong };

/// The closure hash: BLAKE3 over a domain separator, the manifest's hash,
/// then each program's name and hash in entry order.
pub fn closureHash(manifest_hash: Hash, entries: []const Entry) Hash {
    var h = Blake3.init(.{});
    h.update("grain-closure-v1");
    h.update(&manifest_hash);
    for (entries) |e| {
        h.update(&e.name);
        h.update(&e.hash);
    }
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

pub fn hash(bytes: []const u8) Hash {
    var out: Hash = undefined;
    Blake3.hash(bytes, &out, .{});
    return out;
}

pub const Image = struct {
    bytes: []const u8,
    header: Header,
    entries: []align(1) const Entry,

    pub fn parse(bytes: []const u8) Error!Image {
        if (bytes.len < @sizeOf(Header)) return error.Truncated;
        const h = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
        if (h.magic != magic) return error.BadMagic;
        if (h.version != version) return error.BadVersion;
        if (h.count > max_entries) return error.TooManyEntries;
        const table_end = @sizeOf(Header) + @as(usize, h.count) * @sizeOf(Entry);
        if (table_end > bytes.len) return error.Truncated;
        if (h.manifest_offset + h.manifest_size > bytes.len) return error.Truncated;
        const entries = std.mem.bytesAsSlice(Entry, bytes[@sizeOf(Header)..table_end]);
        for (entries) |e| if (e.offset + e.size > bytes.len) return error.Truncated;
        return .{ .bytes = bytes, .header = h, .entries = entries };
    }

    pub fn manifest(img: Image) []const u8 {
        return img.bytes[@intCast(img.header.manifest_offset)..][0..@intCast(img.header.manifest_size)];
    }

    pub fn data(img: Image, e: *align(1) const Entry) []const u8 {
        return img.bytes[@intCast(e.offset)..][0..@intCast(e.size)];
    }

    pub fn find(img: Image, name: []const u8) ?*align(1) const Entry {
        for (img.entries) |*e| if (std.mem.eql(u8, e.nameSlice(), name)) return e;
        return null;
    }

    /// Recompute every hash. On success the image is exactly what its
    /// closure hash names.
    pub fn verify(img: Image) Error!void {
        var copy: [max_entries]Entry = undefined;
        for (img.entries, 0..) |e, i| {
            if (!std.mem.eql(u8, &hash(img.data(&img.entries[i])), &e.hash)) return error.HashMismatch;
            copy[i] = e;
        }
        const c = closureHash(hash(img.manifest()), copy[0..img.entries.len]);
        if (!std.mem.eql(u8, &c, &img.header.closure)) return error.ClosureMismatch;
    }
};

pub const Program = struct { name: []const u8, bytes: []const u8 };

/// Build an image. Programs keep the order given (the manifest's order).
pub fn build(gpa: std.mem.Allocator, manifest_bytes: []const u8, programs: []const Program) ![]u8 {
    if (programs.len > max_entries) return error.TooManyEntries;
    var entries: [max_entries]Entry = undefined;
    var off: u64 = @sizeOf(Header) + programs.len * @sizeOf(Entry);
    const manifest_offset = off;
    off = std.mem.alignForward(u64, off + manifest_bytes.len, 8);
    for (programs, 0..) |p, i| {
        if (p.name.len >= name_len) return error.NameTooLong;
        entries[i] = .{ .name = @splat(0), .offset = off, .size = p.bytes.len, .hash = hash(p.bytes) };
        @memcpy(entries[i].name[0..p.name.len], p.name);
        off = std.mem.alignForward(u64, off + p.bytes.len, 8);
    }
    const out = try gpa.alloc(u8, @intCast(off));
    @memset(out, 0);
    const header: Header = .{
        .magic = magic,
        .version = version,
        .count = @intCast(programs.len),
        .manifest_offset = manifest_offset,
        .manifest_size = manifest_bytes.len,
        .closure = closureHash(hash(manifest_bytes), entries[0..programs.len]),
    };
    @memcpy(out[0..@sizeOf(Header)], std.mem.asBytes(&header));
    for (entries[0..programs.len], 0..) |e, i| {
        const at = @sizeOf(Header) + i * @sizeOf(Entry);
        @memcpy(out[at..][0..@sizeOf(Entry)], std.mem.asBytes(&e));
        @memcpy(out[@intCast(e.offset)..][0..programs[i].bytes.len], programs[i].bytes);
    }
    @memcpy(out[@intCast(manifest_offset)..][0..manifest_bytes.len], manifest_bytes);
    return out;
}

pub fn hexHash(h: Hash) [64]u8 {
    return std.fmt.bytesToHex(h, .lower);
}

test "build, parse, verify, and detect tampering" {
    const gpa = std.testing.allocator;
    const img_bytes = try build(gpa, ".{ .name = \"t\" }", &.{
        .{ .name = "hello", .bytes = "hello program" },
        .{ .name = "virtio_rng", .bytes = "rng driver bytes" },
    });
    defer gpa.free(img_bytes);
    const img = try Image.parse(img_bytes);
    try img.verify();
    try std.testing.expectEqualStrings("hello program", img.data(img.find("hello").?));
    try std.testing.expectEqualStrings(".{ .name = \"t\" }", img.manifest());
    try std.testing.expectEqual(@as(?*align(1) const Entry, null), img.find("nope"));

    // Same inputs, same closure; any change, another closure.
    const again = try build(gpa, ".{ .name = \"t\" }", &.{
        .{ .name = "hello", .bytes = "hello program" },
        .{ .name = "virtio_rng", .bytes = "rng driver bytes" },
    });
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, &img.header.closure, &(try Image.parse(again)).header.closure);
    const other = try build(gpa, ".{ .name = \"t\" }", &.{
        .{ .name = "hello", .bytes = "hello programs" },
        .{ .name = "virtio_rng", .bytes = "rng driver bytes" },
    });
    defer gpa.free(other);
    try std.testing.expect(!std.mem.eql(u8, &img.header.closure, &(try Image.parse(other)).header.closure));

    // Flip one byte of a program: verification fails.
    const tampered = try gpa.dupe(u8, img_bytes);
    defer gpa.free(tampered);
    tampered[@intCast(img.find("hello").?.offset)] ^= 1;
    try std.testing.expectError(error.HashMismatch, (try Image.parse(tampered)).verify());
}
