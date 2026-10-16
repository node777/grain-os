//! Minimal ELF64 reader: just enough to load a static executable's PT_LOAD
//! segments. Used for the root task the kernel builds at boot.
const std = @import("std");

pub const Error = error{ BadMagic, Unsupported, Truncated };

pub const Segment = struct {
    vaddr: u64,
    mem_size: u64,
    /// Bytes from the file; the rest of mem_size is zero-filled.
    data: []const u8,
    read: bool,
    write: bool,
    execute: bool,
};

pub const Image = struct {
    bytes: []const u8,
    entry: u64,
    phoff: u64,
    phentsize: u16,
    phnum: u16,

    pub fn parse(bytes: []const u8, machine: u16) Error!Image {
        if (bytes.len < 64) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..4], "\x7fELF")) return error.BadMagic;
        if (bytes[4] != 2 or bytes[5] != 1) return error.Unsupported; // 64-bit, little-endian
        const e_type = rd(u16, bytes, 16);
        if (e_type != 2) return error.Unsupported; // ET_EXEC
        if (rd(u16, bytes, 18) != machine) return error.Unsupported;
        const img: Image = .{
            .bytes = bytes,
            .entry = rd(u64, bytes, 24),
            .phoff = rd(u64, bytes, 32),
            .phentsize = rd(u16, bytes, 54),
            .phnum = rd(u16, bytes, 56),
        };
        if (img.phentsize < 56) return error.Unsupported;
        if (img.phoff + @as(u64, img.phentsize) * img.phnum > bytes.len) return error.Truncated;
        return img;
    }

    pub fn segments(self: Image) SegmentIterator {
        return .{ .img = self };
    }
};

pub const SegmentIterator = struct {
    img: Image,
    i: u16 = 0,

    pub fn next(self: *SegmentIterator) Error!?Segment {
        const b = self.img.bytes;
        while (self.i < self.img.phnum) {
            const off: usize = @intCast(self.img.phoff + @as(u64, self.img.phentsize) * self.i);
            self.i += 1;
            if (rd(u32, b, off) != 1) continue; // PT_LOAD
            const flags = rd(u32, b, off + 4);
            const file_off = rd(u64, b, off + 8);
            const vaddr = rd(u64, b, off + 16);
            const file_size = rd(u64, b, off + 32);
            const mem_size = rd(u64, b, off + 40);
            if (file_off + file_size > b.len or file_size > mem_size) return error.Truncated;
            return .{
                .vaddr = vaddr,
                .mem_size = mem_size,
                .data = b[@intCast(file_off)..][0..@intCast(file_size)],
                .execute = flags & 1 != 0,
                .write = flags & 2 != 0,
                .read = flags & 4 != 0,
            };
        }
        return null;
    }
};

pub const machine_riscv: u16 = 243;

fn rd(comptime T: type, b: []const u8, off: usize) T {
    return std.mem.readInt(T, b[off..][0..@sizeOf(T)], .little);
}

test "parse a hand-built ELF with one PT_LOAD" {
    var buf: [64 + 56 + 8]u8 = @splat(0);
    @memcpy(buf[0..4], "\x7fELF");
    buf[4] = 2;
    buf[5] = 1;
    std.mem.writeInt(u16, buf[16..18], 2, .little);
    std.mem.writeInt(u16, buf[18..20], machine_riscv, .little);
    std.mem.writeInt(u64, buf[24..32], 0x10000, .little);
    std.mem.writeInt(u64, buf[32..40], 64, .little);
    std.mem.writeInt(u16, buf[54..56], 56, .little);
    std.mem.writeInt(u16, buf[56..58], 1, .little);
    const ph = buf[64..];
    std.mem.writeInt(u32, ph[0..4], 1, .little);
    std.mem.writeInt(u32, ph[4..8], 5, .little); // R+X
    std.mem.writeInt(u64, ph[8..16], 120, .little);
    std.mem.writeInt(u64, ph[16..24], 0x10000, .little);
    std.mem.writeInt(u64, ph[32..40], 8, .little);
    std.mem.writeInt(u64, ph[40..48], 4096, .little);
    @memcpy(buf[120..128], "grainos!");

    const img = try Image.parse(&buf, machine_riscv);
    try std.testing.expectEqual(@as(u64, 0x10000), img.entry);
    var it = img.segments();
    const seg = (try it.next()).?;
    try std.testing.expectEqual(@as(u64, 4096), seg.mem_size);
    try std.testing.expectEqualStrings("grainos!", seg.data);
    try std.testing.expect(seg.read and seg.execute and !seg.write);
    try std.testing.expectEqual(@as(?Segment, null), try it.next());
}
