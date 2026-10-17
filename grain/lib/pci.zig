//! PCI Express, as Steward sees it: configuration space through ECAM, the
//! functions on a bus, their memory BARs, and where to put them.
//!
//! Steward owns the bus. It finds every function, sizes its BARs, places
//! them in the host bridge's memory window (largest first, so each lands
//! aligned with no padding), turns on memory decoding and bus mastering, and
//! hands each function to the domain the manifest names, its BARs mapped and
//! its interrupt routed. Drivers never touch configuration space.
const std = @import("std");

/// Function classes a manifest can ask for, by name.
pub const Class = struct { name: []const u8, code: u32, mask: u32, what: []const u8 };
pub const classes = [_]Class{
    .{ .name = "nvme", .code = 0x01_08_02, .mask = 0xff_ff_ff, .what = "NVMe storage" },
    .{ .name = "ethernet", .code = 0x02_00_00, .mask = 0xff_ff_00, .what = "Ethernet controller" },
    .{ .name = "display", .code = 0x03_00_00, .mask = 0xff_00_00, .what = "display controller" },
    .{ .name = "xhci", .code = 0x0c_03_30, .mask = 0xff_ff_ff, .what = "USB 3 (xHCI) host controller" },
};

pub fn classByName(name: []const u8) ?Class {
    for (classes) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

pub fn matches(c: Class, code: u32) bool {
    return code & c.mask == c.code;
}

/// Configuration space of one function: 4 KiB at ECAM base + (bus << 20 |
/// device << 15 | function << 12).
pub const Config = struct {
    base: usize,

    pub fn at(ecam: usize, bus: u8, device: u5, function: u3) Config {
        return .{ .base = ecam + (@as(usize, bus) << 20) + (@as(usize, device) << 15) + (@as(usize, function) << 12) };
    }

    pub fn read32(c: Config, off: usize) u32 {
        return @as(*volatile u32, @ptrFromInt(c.base + off)).*;
    }
    pub fn write32(c: Config, off: usize, v: u32) void {
        @as(*volatile u32, @ptrFromInt(c.base + off)).* = v;
    }
    pub fn read16(c: Config, off: usize) u16 {
        return @as(*volatile u16, @ptrFromInt(c.base + off)).*;
    }
    pub fn write16(c: Config, off: usize, v: u16) void {
        @as(*volatile u16, @ptrFromInt(c.base + off)).* = v;
    }
    pub fn read8(c: Config, off: usize) u8 {
        return @as(*volatile u8, @ptrFromInt(c.base + off)).*;
    }

    pub fn vendor(c: Config) u16 {
        return c.read16(0x00);
    }
    pub fn deviceId(c: Config) u16 {
        return c.read16(0x02);
    }
    /// Class, subclass, programming interface.
    pub fn class(c: Config) u32 {
        return c.read32(0x08) >> 8;
    }
    pub fn headerType(c: Config) u8 {
        return c.read8(0x0e);
    }
    /// The interrupt pin, 1..4 for INTA..INTD, 0 for none.
    pub fn pin(c: Config) u8 {
        return c.read8(0x3d);
    }

    pub const command_memory: u16 = 1 << 1;
    pub const command_master: u16 = 1 << 2;
    pub const command_no_intx: u16 = 1 << 10;

    /// Decode memory BARs, master the bus (DMA), raise INTx.
    pub fn enable(c: Config) void {
        c.write16(0x04, (c.read16(0x04) | command_memory | command_master) & ~command_no_intx);
    }

    /// The function's memory BARs, sized by writing all ones and reading
    /// back (with decoding off meanwhile, so nothing answers the probe).
    pub fn bars(c: Config, out: *[6]Bar) []Bar {
        const cmd = c.read16(0x04);
        c.write16(0x04, cmd & ~command_memory);
        defer c.write16(0x04, cmd);
        var n: usize = 0;
        var i: u8 = 0;
        while (i < 6) : (i += 1) {
            const off = 0x10 + @as(usize, i) * 4;
            const orig = c.read32(off);
            if (orig & 1 != 0) continue; // I/O space: not used here
            const wide = (orig >> 1) & 3 == 2;
            c.write32(off, 0xffff_ffff);
            var mask: u64 = c.read32(off) & 0xffff_fff0;
            c.write32(off, orig);
            if (wide and i < 5) {
                const hi_orig = c.read32(off + 4);
                c.write32(off + 4, 0xffff_ffff);
                mask |= @as(u64, c.read32(off + 4)) << 32;
                c.write32(off + 4, hi_orig);
            } else if (mask != 0) mask |= 0xffff_ffff_0000_0000;
            if (mask != 0) {
                out[n] = .{ .index = i, .size = ~mask +% 1, .wide = wide, .prefetchable = orig & 8 != 0 };
                n += 1;
            }
            if (wide) i += 1;
        }
        return out[0..n];
    }

    pub fn setBar(c: Config, b: Bar, addr: u64) void {
        const off = 0x10 + @as(usize, b.index) * 4;
        c.write32(off, @truncate(addr | (if (b.wide) @as(u64, 4) else 0) | (if (b.prefetchable) @as(u64, 8) else 0)));
        if (b.wide) c.write32(off + 4, @truncate(addr >> 32));
    }
};

pub const Bar = struct {
    index: u8,
    size: u64,
    wide: bool,
    prefetchable: bool,
    /// Where it was placed (bus address).
    addr: u64 = 0,
};

/// Smallest piece of address space a BAR is given: a page, so each can be
/// mapped on its own.
pub const min_bar = 4096;

/// Place BARs in a window: largest first, each aligned to its own (power of
/// two) size, which leaves no gaps when the window base is aligned. Returns
/// the order they were placed in (Steward makes frames in that order).
pub fn place(bars: []*Bar, window_base: u64, window_size: u64) error{NoSpace}!void {
    std.mem.sort(*Bar, bars, {}, struct {
        fn larger(_: void, a: *Bar, b: *Bar) bool {
            return a.size > b.size;
        }
    }.larger);
    var cursor = window_base;
    for (bars) |b| {
        const size = @max(b.size, min_bar);
        cursor = std.mem.alignForward(u64, cursor, size);
        if (cursor + size > window_base + window_size) return error.NoSpace;
        b.addr = cursor;
        cursor += size;
    }
}

const testing = std.testing;

test "classes match by code and mask" {
    try testing.expect(matches(classByName("nvme").?, 0x010802));
    try testing.expect(!matches(classByName("nvme").?, 0x010601)); // AHCI
    try testing.expect(matches(classByName("ethernet").?, 0x020000));
    try testing.expect(matches(classByName("display").?, 0x038000)); // "other display"
    try testing.expect(classByName("sound") == null);
}

test "BARs are placed largest first, aligned, without gaps" {
    var bars = [_]Bar{
        .{ .index = 0, .size = 16 * 1024, .wide = true, .prefetchable = false },
        .{ .index = 2, .size = 16, .wide = false, .prefetchable = false },
        .{ .index = 3, .size = 16 << 20, .wide = false, .prefetchable = true },
    };
    var ptrs = [_]*Bar{ &bars[0], &bars[1], &bars[2] };
    try place(&ptrs, 0x4000_0000, 0x4000_0000);
    try testing.expectEqual(@as(u64, 0x4000_0000), bars[2].addr);
    try testing.expectEqual(@as(u64, 0x4100_0000), bars[0].addr);
    try testing.expectEqual(@as(u64, 0x4100_4000), bars[1].addr); // a tiny BAR still gets a page
    try testing.expectEqual(@as(u8, 3), ptrs[0].index);
    var big: [3]Bar = @splat(.{ .index = 0, .size = 0x2000_0000, .wide = false, .prefetchable = false });
    var bp = [_]*Bar{ &big[0], &big[1], &big[2] };
    try testing.expectError(error.NoSpace, place(&bp, 0x4000_0000, 0x4000_0000));
}
