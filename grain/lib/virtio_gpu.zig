//! virtio-gpu, two-dimensional: one resource the size of the screen, backed
//! by memory the driver owns, shown on the first display. Drawing is plain
//! stores into that memory; `flush` copies a rectangle to the host and has
//! it shown.
//!
//! Each command is a request (device-readable) and a response
//! (device-writable) in one command page, at offsets 0 and 2048.
const std = @import("std");
const virtio = @import("virtio.zig");
const grain = @import("grain.zig");

pub const device_id: u32 = 16;

const Kind = struct {
    const get_display_info: u32 = 0x0100;
    const resource_create_2d: u32 = 0x0101;
    const set_scanout: u32 = 0x0103;
    const resource_flush: u32 = 0x0104;
    const transfer_to_host_2d: u32 = 0x0105;
    const resource_attach_backing: u32 = 0x0106;
    const ok_nodata: u32 = 0x1100;
    const ok_display_info: u32 = 0x1101;
};

/// B, G, R, X in memory: 0x00RRGGBB as a little-endian u32.
const format_b8g8r8x8: u32 = 2;
const resource: u32 = 1;

const Header = extern struct { kind: u32, flags: u32 = 0, fence_id: u64 = 0, ctx_id: u32 = 0, ring_idx: u8 = 0, _pad: [3]u8 = @splat(0) };
pub const Rect = extern struct { x: u32, y: u32, width: u32, height: u32 };
const Display = extern struct { r: Rect, enabled: u32, flags: u32 };
const DisplayInfo = extern struct { hdr: Header, displays: [16]Display };
const Create2d = extern struct { hdr: Header, resource_id: u32, format: u32, width: u32, height: u32 };
const AttachBacking = extern struct { hdr: Header, resource_id: u32, entries: u32 };
const MemEntry = extern struct { addr: u64, length: u32, _pad: u32 = 0 };
const SetScanout = extern struct { hdr: Header, r: Rect, scanout_id: u32, resource_id: u32 };
const Transfer2d = extern struct { hdr: Header, r: Rect, offset: u64, resource_id: u32, _pad: u32 = 0 };
const Flush = extern struct { hdr: Header, r: Rect, resource_id: u32, _pad: u32 = 0 };

pub const Page = struct { va: usize, pa: u64 };
/// Physically contiguous pieces of the framebuffer, in order.
pub const Backing = struct { pa: u64, len: u32 };

pub const Error = virtio.Error || error{ DeviceError, NoDisplay };

pub const Gpu = struct {
    dev: virtio.Device,
    q: virtio.Queue,
    cmd: Page,
    signal: grain.CPtr,
    irq: grain.CPtr,
    width: u32 = 0,
    height: u32 = 0,

    pub fn init(base: usize, queue: Page, cmd: Page, signal: grain.CPtr, irq: grain.CPtr) Error!Gpu {
        const dev: virtio.Device = .{ .base = base };
        _ = try dev.init(device_id, 0);
        const q = try virtio.Queue.init(dev, 0, queue.va, queue.pa);
        dev.ready();
        var g: Gpu = .{ .dev = dev, .q = q, .cmd = cmd, .signal = signal, .irq = irq };
        const info = try g.exec(Header{ .kind = Kind.get_display_info }, &.{}, DisplayInfo, Kind.ok_display_info);
        const d = info.displays[0];
        if (d.enabled == 0 or d.r.width == 0) return error.NoDisplay;
        g.width = d.r.width;
        g.height = d.r.height;
        return g;
    }

    /// Bytes the framebuffer takes.
    pub fn frameBytes(g: *const Gpu) usize {
        return @as(usize, g.width) * g.height * 4;
    }

    /// Make the screen-sized resource, back it with `backing` and show it.
    pub fn attach(g: *Gpu, backing: []const Backing) Error!void {
        _ = try g.exec(Create2d{ .hdr = .{ .kind = Kind.resource_create_2d }, .resource_id = resource, .format = format_b8g8r8x8, .width = g.width, .height = g.height }, &.{}, Header, Kind.ok_nodata);
        var entries: [8]MemEntry = undefined;
        for (backing, 0..) |b, i| entries[i] = .{ .addr = b.pa, .length = b.len };
        _ = try g.exec(AttachBacking{ .hdr = .{ .kind = Kind.resource_attach_backing }, .resource_id = resource, .entries = @intCast(backing.len) }, std.mem.sliceAsBytes(entries[0..backing.len]), Header, Kind.ok_nodata);
        _ = try g.exec(SetScanout{ .hdr = .{ .kind = Kind.set_scanout }, .r = g.whole(), .scanout_id = 0, .resource_id = resource }, &.{}, Header, Kind.ok_nodata);
    }

    pub fn whole(g: *const Gpu) Rect {
        return .{ .x = 0, .y = 0, .width = g.width, .height = g.height };
    }

    /// Show what was drawn inside `r`.
    pub fn flush(g: *Gpu, r: Rect) Error!void {
        const off = (@as(u64, r.y) * g.width + r.x) * 4;
        _ = try g.exec(Transfer2d{ .hdr = .{ .kind = Kind.transfer_to_host_2d }, .r = r, .offset = off, .resource_id = resource }, &.{}, Header, Kind.ok_nodata);
        _ = try g.exec(Flush{ .hdr = .{ .kind = Kind.resource_flush }, .r = r, .resource_id = resource }, &.{}, Header, Kind.ok_nodata);
    }

    /// One command: `req` then `extra` bytes, a response of type `R` whose
    /// header must say `want`.
    fn exec(g: *Gpu, req: anytype, extra: []const u8, comptime R: type, want: u32) Error!R {
        const page: [*]u8 = @ptrFromInt(g.cmd.va);
        const n = @sizeOf(@TypeOf(req));
        @memcpy(page[0..n], std.mem.asBytes(&req));
        @memcpy(page[n..][0..extra.len], extra);
        @memset(page[2048..][0..@sizeOf(R)], 0);
        _ = g.q.submitChain(&.{
            .{ .pa = g.cmd.pa, .len = @intCast(n + extra.len), .device_writes = false },
            .{ .pa = g.cmd.pa + 2048, .len = @sizeOf(R), .device_writes = true },
        });
        if (g.signal != 0) {
            _ = g.q.wait(g.signal, g.irq);
        } else {
            while (g.q.poll() == null) std.atomic.spinLoopHint();
        }
        const resp = std.mem.bytesToValue(R, page[2048..][0..@sizeOf(R)]);
        const kind = std.mem.bytesToValue(Header, page[2048..][0..@sizeOf(Header)]).kind;
        if (kind != want) return error.DeviceError;
        return resp;
    }
};

comptime {
    std.debug.assert(@sizeOf(Header) == 24);
    std.debug.assert(@sizeOf(DisplayInfo) == 24 + 16 * 24);
}
