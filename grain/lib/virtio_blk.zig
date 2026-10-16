//! virtio-blk: 4 KiB blocks over 512-byte sectors, one request at a time.
//!
//! Used by the Tablecloth domain (waiting on the device interrupt) and by
//! Aurora before any kernel runs (polling, physical addresses). All it needs
//! is three DMA pages: the queue, a request page (header and status) and a
//! data page.
const std = @import("std");
const virtio = @import("virtio.zig");
const grain = @import("grain.zig");

pub const device_id: u32 = 2;
pub const block_size = 4096;
const sectors_per_block = block_size / 512;
const feature_flush: u64 = 1 << 9;

const req_in: u32 = 0;
const req_out: u32 = 1;
const req_flush: u32 = 4;

const Header = extern struct { kind: u32, reserved: u32, sector: u64 };

pub const Page = struct { va: usize, pa: u64 };

pub const Error = virtio.Error || error{ DeviceError, OutOfRange };

pub const Blk = struct {
    dev: virtio.Device,
    q: virtio.Queue,
    req: Page,
    data: Page,
    /// The device interrupt (as a signal) and its Irq; 0 = poll.
    signal: grain.CPtr,
    irq: grain.CPtr,
    blocks: u64,
    can_flush: bool,

    pub fn init(base: usize, queue: Page, req: Page, data: Page, signal: grain.CPtr, irq: grain.CPtr) Error!Blk {
        const dev: virtio.Device = .{ .base = base };
        const chosen = try dev.init(device_id, feature_flush);
        const q = try virtio.Queue.init(dev, 0, queue.va, queue.pa);
        dev.ready();
        const sectors = @as(u64, dev.config32(0)) | (@as(u64, dev.config32(4)) << 32);
        return .{
            .dev = dev,
            .q = q,
            .req = req,
            .data = data,
            .signal = signal,
            .irq = irq,
            .blocks = sectors / sectors_per_block,
            .can_flush = chosen & feature_flush != 0,
        };
    }

    fn header(b: *Blk) *volatile Header {
        return @ptrFromInt(b.req.va);
    }

    fn status(b: *Blk) *volatile u8 {
        return @ptrFromInt(b.req.va + 16);
    }

    fn dataPage(b: *Blk) *[block_size]u8 {
        return @ptrFromInt(b.data.va);
    }

    fn run(b: *Blk, kind: u32, block: u64, device_writes: bool) Error!void {
        b.header().* = .{ .kind = kind, .reserved = 0, .sector = block * sectors_per_block };
        b.status().* = 0xff;
        const h: virtio.Queue.Part = .{ .pa = b.req.pa, .len = @sizeOf(Header), .device_writes = false };
        const st: virtio.Queue.Part = .{ .pa = b.req.pa + 16, .len = 1, .device_writes = true };
        if (kind == req_flush) {
            _ = b.q.submitChain(&.{ h, st });
        } else {
            _ = b.q.submitChain(&.{ h, .{ .pa = b.data.pa, .len = block_size, .device_writes = device_writes }, st });
        }
        if (b.signal != 0) {
            _ = b.q.wait(b.signal, b.irq);
        } else {
            while (b.q.poll() == null) std.atomic.spinLoopHint();
        }
        grain.fence();
        if (b.status().* != 0) return error.DeviceError;
    }

    pub fn read(b: *Blk, block: u64, out: *[block_size]u8) Error!void {
        if (block >= b.blocks) return error.OutOfRange;
        try b.run(req_in, block, true);
        out.* = b.dataPage().*;
    }

    pub fn write(b: *Blk, block: u64, in: *const [block_size]u8) Error!void {
        if (block >= b.blocks) return error.OutOfRange;
        b.dataPage().* = in.*;
        grain.fence();
        try b.run(req_out, block, false);
    }

    /// Everything written so far is on stable storage when this returns.
    pub fn flush(b: *Blk) Error!void {
        // Without the flush feature virtio leaves durability to the device;
        // QEMU and real disks with a cache offer it.
        if (!b.can_flush) return;
        try b.run(req_flush, 0, false);
    }
};
