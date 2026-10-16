//! virtio over MMIO (virtio 1.x, "modern" transport) with split virtqueues.
//!
//! A driver maps the device's MMIO page, calls `Device.init` with the
//! features it wants, sets up its queues in DMA memory it owns, and then
//! submits buffers. Completion is noticed through the device interrupt
//! (delivered as a signal) or by polling the used ring.
const std = @import("std");
const grain = @import("grain.zig");

pub const magic: u32 = 0x7472_6976; // "virt"

pub const Reg = enum(usize) {
    magic = 0x000,
    version = 0x004,
    device_id = 0x008,
    vendor_id = 0x00c,
    device_features = 0x010,
    device_features_sel = 0x014,
    driver_features = 0x020,
    driver_features_sel = 0x024,
    queue_sel = 0x030,
    queue_num_max = 0x034,
    queue_num = 0x038,
    queue_ready = 0x044,
    queue_notify = 0x050,
    interrupt_status = 0x060,
    interrupt_ack = 0x064,
    status = 0x070,
    queue_desc_low = 0x080,
    queue_desc_high = 0x084,
    queue_driver_low = 0x090,
    queue_driver_high = 0x094,
    queue_device_low = 0x0a0,
    queue_device_high = 0x0a4,
    config_generation = 0x0fc,
};

pub const Status = struct {
    pub const acknowledge: u32 = 1;
    pub const driver: u32 = 2;
    pub const driver_ok: u32 = 4;
    pub const features_ok: u32 = 8;
    pub const failed: u32 = 128;
};

/// VIRTIO_F_VERSION_1 (feature bit 32).
pub const feature_version_1: u64 = 1 << 32;

pub const Error = error{ NotVirtio, LegacyDevice, WrongDevice, FeaturesRejected, QueueUnavailable, QueueFull };

pub const Device = struct {
    base: usize,

    pub fn read(d: Device, r: Reg) u32 {
        return @as(*volatile u32, @ptrFromInt(d.base + @backingInt(r))).*;
    }

    pub fn write(d: Device, r: Reg, v: u32) void {
        @as(*volatile u32, @ptrFromInt(d.base + @backingInt(r))).* = v;
    }

    pub fn deviceId(d: Device) u32 {
        return d.read(.device_id);
    }

    /// Probe without touching device state.
    pub fn identify(base: usize) ?u32 {
        const d: Device = .{ .base = base };
        if (d.read(.magic) != magic) return null;
        return d.read(.device_id);
    }

    /// Reset, negotiate `wanted` features (VERSION_1 is always required),
    /// leaving the device ready for queue setup.
    pub fn init(d: Device, expect_id: u32, wanted: u64) Error!u64 {
        if (d.read(.magic) != magic) return error.NotVirtio;
        if (d.read(.version) != 2) return error.LegacyDevice;
        if (d.read(.device_id) != expect_id) return error.WrongDevice;
        d.write(.status, 0);
        d.write(.status, Status.acknowledge);
        d.write(.status, Status.acknowledge | Status.driver);
        d.write(.device_features_sel, 0);
        var offered: u64 = d.read(.device_features);
        d.write(.device_features_sel, 1);
        offered |= @as(u64, d.read(.device_features)) << 32;
        const chosen = (wanted | feature_version_1) & offered;
        if (chosen & feature_version_1 == 0) return error.FeaturesRejected;
        d.write(.driver_features_sel, 0);
        d.write(.driver_features, @truncate(chosen));
        d.write(.driver_features_sel, 1);
        d.write(.driver_features, @truncate(chosen >> 32));
        d.write(.status, Status.acknowledge | Status.driver | Status.features_ok);
        if (d.read(.status) & Status.features_ok == 0) return error.FeaturesRejected;
        return chosen;
    }

    pub fn ready(d: Device) void {
        d.write(.status, Status.acknowledge | Status.driver | Status.features_ok | Status.driver_ok);
    }

    /// Acknowledge all pending interrupt causes.
    pub fn ackInterrupt(d: Device) u32 {
        const s = d.read(.interrupt_status);
        d.write(.interrupt_ack, s);
        return s;
    }

    pub fn configByte(d: Device, off: usize) u8 {
        return @as(*volatile u8, @ptrFromInt(d.base + 0x100 + off)).*;
    }
};

pub const queue_size = 16;

pub const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,

    pub const flag_next: u16 = 1;
    pub const flag_write: u16 = 2;
};

pub const Avail = extern struct {
    flags: u16,
    idx: u16,
    ring: [queue_size]u16,
    used_event: u16,
};

pub const UsedElem = extern struct { id: u32, len: u32 };

pub const Used = extern struct {
    flags: u16,
    idx: u16,
    ring: [queue_size]UsedElem,
    avail_event: u16,
};

/// One split virtqueue in a single 4 KiB DMA page:
/// descriptors at 0, the available ring at 256, the used ring at 512.
pub const Queue = struct {
    dev: Device,
    index: u32,
    desc: *volatile [queue_size]Desc,
    avail: *volatile Avail,
    used: *volatile Used,
    next_desc: u16 = 0,
    last_used: u16 = 0,

    /// `va`/`pa`: the queue page, mapped in this domain and its physical address.
    pub fn init(dev: Device, index: u32, va: usize, pa: u64) Error!Queue {
        dev.write(.queue_sel, index);
        const max = dev.read(.queue_num_max);
        if (max == 0) return error.QueueUnavailable;
        if (max < queue_size) return error.QueueUnavailable;
        @memset(@as([*]u8, @ptrFromInt(va))[0..4096], 0);
        dev.write(.queue_num, queue_size);
        dev.write(.queue_desc_low, @truncate(pa));
        dev.write(.queue_desc_high, @truncate(pa >> 32));
        dev.write(.queue_driver_low, @truncate(pa + 256));
        dev.write(.queue_driver_high, @truncate((pa + 256) >> 32));
        dev.write(.queue_device_low, @truncate(pa + 512));
        dev.write(.queue_device_high, @truncate((pa + 512) >> 32));
        dev.write(.queue_ready, 1);
        return .{
            .dev = dev,
            .index = index,
            .desc = @ptrFromInt(va),
            .avail = @ptrFromInt(va + 256),
            .used = @ptrFromInt(va + 512),
        };
    }

    /// Offer one buffer to the device (device-writable if `device_writes`).
    pub fn submit(q: *Queue, pa: u64, len: u32, device_writes: bool) Error!u16 {
        const id = q.next_desc;
        q.next_desc = (q.next_desc + 1) % queue_size;
        q.desc[id] = .{ .addr = pa, .len = len, .flags = if (device_writes) Desc.flag_write else 0, .next = 0 };
        const slot = q.avail.idx % queue_size;
        q.avail.ring[slot] = id;
        grain.fence();
        q.avail.idx +%= 1;
        grain.fence();
        q.dev.write(.queue_notify, q.index);
        return id;
    }

    /// Offer a buffer on a specific descriptor (for fixed receive buffers
    /// that are handed back to the device as soon as they are read).
    pub fn submitDesc(q: *Queue, id: u16, pa: u64, len: u32, device_writes: bool) void {
        q.desc[id] = .{ .addr = pa, .len = len, .flags = if (device_writes) Desc.flag_write else 0, .next = 0 };
        const slot = q.avail.idx % queue_size;
        q.avail.ring[slot] = id;
        grain.fence();
        q.avail.idx +%= 1;
        grain.fence();
        q.dev.write(.queue_notify, q.index);
    }

    /// A completed buffer, if the device has returned one.
    pub fn poll(q: *Queue) ?UsedElem {
        grain.fence();
        if (q.used.idx == q.last_used) return null;
        const e = q.used.ring[q.last_used % queue_size];
        q.last_used +%= 1;
        return e;
    }

    /// Wait for a completion: block on the device's interrupt signal, or
    /// spin if `irq_signal` is 0.
    pub fn wait(q: *Queue, irq_signal: grain.CPtr, irq: grain.CPtr) UsedElem {
        while (true) {
            if (q.poll()) |e| return e;
            if (irq_signal != 0) {
                _ = grain.wait(irq_signal);
                _ = q.dev.ackInterrupt();
                _ = grain.invoke(irq, grain.abi.IrqMethod.ack, .{});
            } else {
                grain.yield();
            }
        }
    }
};

/// DMA memory for a driver: one page for each queue plus buffer pages,
/// from the domain's own memory, mapped at `va`.
pub const Dma = struct {
    va: usize,
    pa: u64,

    pub fn alloc(space: *grain.Space, va: usize) !Dma {
        const f = try space.mapNew(va, 1, .{ .read = true, .write = true });
        return .{ .va = va, .pa = try grain.physOf(f) };
    }

    pub fn bytes(d: Dma) *[4096]u8 {
        return @ptrFromInt(d.va);
    }
};
