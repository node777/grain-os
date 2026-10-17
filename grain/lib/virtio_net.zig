//! virtio-net: Ethernet frames in and out.
//!
//! Receive: all sixteen descriptors of the receive queue are lent to the
//! device, two 2 KiB buffers per page, and each is lent again as soon as its
//! frame is copied out. Transmit: eight 2 KiB slots; a frame goes in the slot
//! its descriptor maps to, and finished sends are collected before a slot is
//! reused. Every buffer starts with the 12-byte virtio-net header, which
//! asks for nothing (no offloads).
const std = @import("std");
const virtio = @import("virtio.zig");
const grain = @import("grain.zig");

pub const device_id: u32 = 1;
const feature_mac: u64 = 1 << 5;
const header = 12;
const buffer = 2048;
pub const max_frame = buffer - header;

pub const Page = struct { va: usize, pa: u64 };

pub const Error = virtio.Error || error{TooLarge};

pub const Net = struct {
    dev: virtio.Device,
    rxq: virtio.Queue,
    txq: virtio.Queue,
    rx: [8]Page,
    tx: [4]Page,
    mac: [6]u8,
    in_flight: u8 = 0,

    pub fn init(base: usize, rxq: Page, txq: Page, rx: [8]Page, tx: [4]Page) Error!Net {
        const dev: virtio.Device = .{ .base = base };
        const chosen = try dev.init(device_id, feature_mac);
        var n: Net = .{
            .dev = dev,
            .rxq = try virtio.Queue.init(dev, 0, rxq.va, rxq.pa),
            .txq = try virtio.Queue.init(dev, 1, txq.va, txq.pa),
            .rx = rx,
            .tx = tx,
            .mac = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 },
        };
        if (chosen & feature_mac != 0) for (&n.mac, 0..) |*b, i| {
            b.* = dev.configByte(i);
        };
        dev.ready();
        for (0..virtio.queue_size) |i| n.lend(@intCast(i));
        return n;
    }

    fn rxBuffer(n: *const Net, id: u16) struct { va: usize, pa: u64 } {
        const p = n.rx[id / 2];
        const off: usize = (id % 2) * buffer;
        return .{ .va = p.va + off, .pa = p.pa + off };
    }

    fn lend(n: *Net, id: u16) void {
        const b = n.rxBuffer(id);
        n.rxq.submitDesc(id, b.pa, buffer, true);
    }

    /// The next frame the device received, copied into `out`, if any.
    pub fn recv(n: *Net, out: []u8) ?[]u8 {
        const u = n.rxq.poll() orelse return null;
        const id: u16 = @intCast(u.id);
        const b = n.rxBuffer(id);
        const len = @min(@as(usize, u.len) -| header, out.len);
        @memcpy(out[0..len], @as([*]const u8, @ptrFromInt(b.va + header))[0..len]);
        n.lend(id);
        return out[0..len];
    }

    /// Collect sends the device has finished with.
    fn collect(n: *Net) void {
        while (n.txq.poll()) |_| n.in_flight -= 1;
    }

    /// Send a frame. Waits (yielding) only if all eight slots are in flight.
    pub fn send(n: *Net, frame: []const u8) Error!void {
        if (frame.len > max_frame) return error.TooLarge;
        n.collect();
        while (n.in_flight == 8) {
            grain.yield();
            n.collect();
        }
        // The slot that the next descriptor maps to is free: at most eight
        // sends are in flight, and descriptors are used in turn.
        const id = n.txq.next_desc;
        const p = n.tx[(id % 8) / 2];
        const off: usize = (id % 2) * buffer;
        const dst: [*]u8 = @ptrFromInt(p.va + off);
        @memset(dst[0..header], 0);
        @memcpy(dst[header..][0..frame.len], frame);
        _ = try n.txq.submit(p.pa + off, @intCast(header + frame.len), false);
        n.in_flight += 1;
    }
};
