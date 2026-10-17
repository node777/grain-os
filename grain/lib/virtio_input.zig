//! virtio-input: keyboards, mice and tablets, as Linux input events.
//!
//! The device writes 8-byte events into buffers the driver lends it: all
//! sixteen descriptors of the event queue point into one DMA page, and each
//! is handed back as soon as its event is read.
const std = @import("std");
const virtio = @import("virtio.zig");

pub const device_id: u32 = 18;

pub const Event = extern struct { kind: u16, code: u16, value: u32 };

/// Event kinds (Linux EV_*).
pub const ev_syn: u16 = 0;
pub const ev_key: u16 = 1;
pub const ev_abs: u16 = 3;
pub const abs_x: u16 = 0;
pub const abs_y: u16 = 1;
pub const btn_left: u16 = 0x110;

const cfg_ev_bits: u8 = 0x11;
const cfg_abs_info: u8 = 0x12;

pub const Page = struct { va: usize, pa: u64 };

pub const Input = struct {
    dev: virtio.Device,
    q: virtio.Queue,
    buf: Page,
    /// A pointing device reporting absolute positions (a tablet), and the
    /// largest value it reports on each axis.
    absolute: bool,
    abs_max: [2]u32,

    pub fn init(base: usize, queue: Page, buf: Page) virtio.Error!Input {
        const dev: virtio.Device = .{ .base = base };
        _ = try dev.init(device_id, 0);
        const q = try virtio.Queue.init(dev, 0, queue.va, queue.pa);
        var in: Input = .{ .dev = dev, .q = q, .buf = buf, .absolute = false, .abs_max = .{ 0, 0 } };
        // Does it report absolute axes? (EV_BITS for EV_ABS is non-empty.)
        dev.setConfigByte(0, cfg_ev_bits);
        dev.setConfigByte(1, @intCast(ev_abs));
        in.absolute = dev.configByte(2) > 0;
        if (in.absolute) for (0..2) |axis| {
            dev.setConfigByte(0, cfg_abs_info);
            dev.setConfigByte(1, @intCast(axis));
            in.abs_max[axis] = dev.config32(8 + 4); // struct { min, max, fuzz, flat, res }
        };
        dev.ready();
        for (0..virtio.queue_size) |i| in.lend(@intCast(i));
        return in;
    }

    fn lend(in: *Input, id: u16) void {
        in.q.submitDesc(id, in.buf.pa + @as(u64, id) * @sizeOf(Event), @sizeOf(Event), true);
    }

    /// The next event, if the device has written one.
    pub fn next(in: *Input) ?Event {
        const u = in.q.poll() orelse return null;
        const id: u16 = @intCast(u.id);
        const e = @as(*volatile Event, @ptrFromInt(in.buf.va + @as(usize, id) * @sizeOf(Event))).*;
        in.lend(id);
        return e;
    }
};

/// A key as text, US layout: the character a key code types, or 0.
pub fn char(code: u16, shift: bool) u8 {
    const plain = "\x00\x1b1234567890-=\x08\tqwertyuiop[]\n\x00asdfghjkl;'`\x00\\zxcvbnm,./\x00*\x00 ";
    const shifted = "\x00\x1b!@#$%^&*()_+\x08\tQWERTYUIOP{}\n\x00ASDFGHJKL:\"~\x00|ZXCVBNM<>?\x00*\x00 ";
    if (code >= plain.len) return 0;
    return if (shift) shifted[code] else plain[code];
}

pub const key_left_shift: u16 = 42;
pub const key_right_shift: u16 = 54;

test "key codes type US characters" {
    try std.testing.expectEqual(@as(u8, 'a'), char(30, false));
    try std.testing.expectEqual(@as(u8, 'A'), char(30, true));
    try std.testing.expectEqual(@as(u8, '\n'), char(28, false));
    try std.testing.expectEqual(@as(u8, ' '), char(57, false));
    try std.testing.expectEqual(@as(u8, '1'), char(2, false));
    try std.testing.expectEqual(@as(u8, '!'), char(2, true));
    try std.testing.expectEqual(@as(u8, 'z'), char(44, false));
    try std.testing.expectEqual(@as(u8, 0x08), char(14, false));
}
