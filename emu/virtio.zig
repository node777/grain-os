//! virtio-mmio (version 2, "modern") devices: entropy (4), block (2), a
//! single-port console (3), a 2D GPU (16) and input devices (18: a keyboard
//! and a tablet), as Grain's drivers use them. Split virtqueues, no event
//! index, no indirect descriptors.
//!
//! A device sees guest memory through `Dma` and the outside world through
//! the machine's `Host`; the machine routes register accesses and raises
//! the device's PLIC line while `interrupt_status` is non-zero.
const std = @import("std");

pub const Kind = enum { rng, blk, console, gpu, keyboard, tablet };

/// The tablet's axes run 0..tablet_max (as QEMU's virtio-tablet).
pub const tablet_max: u32 = 0x7fff;

pub const feature_version_1: u64 = 1 << 32;
pub const blk_feature_flush: u64 = 1 << 9;
pub const queue_max = 256;

const status_features_ok: u32 = 8;

pub const Queue = struct {
    num: u32 = 0,
    ready: bool = false,
    desc: u64 = 0,
    driver: u64 = 0,
    device: u64 = 0,
    last_avail: u16 = 0,
};

/// Guest physical memory, for descriptors and buffers.
pub const Dma = struct {
    ram: []u8,
    base: u64,
    /// Told about every range a device may write (the machine drops decoded
    /// instructions there: a disk read can load code).
    ctx: *anyopaque,
    written: *const fn (*anyopaque, u64, u64) void,

    /// Guest memory the device only reads (no code there is invalidated).
    pub fn peek(d: Dma, pa: u64, len: u64) ?[]const u8 {
        if (pa < d.base) return null;
        const off = pa - d.base;
        if (off > d.ram.len or len > d.ram.len - off) return null;
        return d.ram[@intCast(off)..][0..@intCast(len)];
    }

    pub fn slice(d: Dma, pa: u64, len: u64) ?[]u8 {
        if (pa < d.base) return null;
        const off = pa - d.base;
        if (off > d.ram.len or len > d.ram.len - off) return null;
        d.written(d.ctx, pa, len);
        return d.ram[@intCast(off)..][0..@intCast(len)];
    }

    fn int(d: Dma, comptime T: type, pa: u64) ?T {
        const s = d.slice(pa, @sizeOf(T)) orelse return null;
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }

    fn setInt(d: Dma, comptime T: type, pa: u64, v: T) void {
        const s = d.slice(pa, @sizeOf(T)) orelse return;
        std.mem.writeInt(T, s[0..@sizeOf(T)], v, .little);
    }
};

pub const Desc = struct { addr: u64, len: u32, flags: u16, next: u16 };
const flag_next: u16 = 1;
const flag_write: u16 = 2;

pub const Device = struct {
    kind: Kind,
    /// Consoles: which one (0 = the owner's console, 1 = the next, ...).
    port: u8 = 0,
    status: u32 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    driver_features: u64 = 0,
    queue_sel: u32 = 0,
    queues: [2]Queue = @splat(.{}),
    interrupt_status: u32 = 0,
    /// Block devices: capacity in 512-byte sectors.
    sectors: u64 = 0,
    /// Consoles: bytes received and not yet given to the guest. Input
    /// devices: events (8 bytes each) not yet given.
    input: [8192]u8 = undefined,
    input_len: usize = 0,
    /// Input devices: the configuration space's selector.
    select: u8 = 0,
    subsel: u8 = 0,
    /// GPU: the screen (RGBA, `screen_width` pixels a row; the machine owns
    /// it), the one resource and where its backing is.
    screen: []u8 = &.{},
    screen_width: u32 = 0,
    screen_height: u32 = 0,
    resource: u32 = 0,
    resource_format: u32 = 0,
    backing: [16]Backing = undefined,
    backing_len: usize = 0,

    pub fn deviceId(d: *const Device) u32 {
        return switch (d.kind) {
            .blk => 2,
            .console => 3,
            .rng => 4,
            .gpu => 16,
            .keyboard, .tablet => 18,
        };
    }

    pub fn offered(d: *const Device) u64 {
        return feature_version_1 | switch (d.kind) {
            .blk => blk_feature_flush,
            else => 0,
        };
    }

    fn reset(d: *Device) void {
        d.status = 0;
        d.driver_features = 0;
        d.queue_sel = 0;
        d.queues = @splat(.{});
        d.interrupt_status = 0;
    }

    fn queueCount(d: *const Device) u32 {
        return switch (d.kind) {
            .console, .gpu, .keyboard, .tablet => 2,
            else => 1,
        };
    }

    fn selected(d: *Device) ?*Queue {
        return if (d.queue_sel < d.queueCount()) &d.queues[d.queue_sel] else null;
    }

    pub fn read(d: *Device, off: u64) u32 {
        return switch (off) {
            0x000 => 0x74726976,
            0x004 => 2,
            0x008 => d.deviceId(),
            0x00c => 0x554d4551,
            0x010 => @truncate(if (d.device_features_sel == 0) d.offered() else if (d.device_features_sel == 1) d.offered() >> 32 else 0),
            0x034 => if (d.selected() != null) queue_max else 0,
            0x044 => if (d.selected()) |q| @intFromBool(q.ready) else 0,
            0x060 => d.interrupt_status,
            0x070 => d.status,
            0x0fc => 0,
            else => if (off >= 0x100) d.config(off - 0x100) else 0,
        };
    }

    fn config(d: *const Device, off: u64) u32 {
        return switch (d.kind) {
            .blk => switch (off) {
                0 => @truncate(d.sectors),
                4 => @truncate(d.sectors >> 32),
                20 => 512, // blk_size
                else => 0,
            },
            .gpu => switch (off) {
                8 => 1, // num_scanouts
                else => 0, // events_read, events_clear, num_capsets
            },
            .keyboard, .tablet => blk: {
                var w: u32 = 0;
                for (0..4) |i| w |= @as(u32, d.inputConfigByte(off + i)) << @intCast(8 * i);
                break :blk w;
            },
            else => 0,
        };
    }

    /// Input devices' configuration: select (0), subsel (1), size (2), and
    /// the selected data from byte 8.
    fn inputConfigByte(d: *const Device, off: u64) u8 {
        var data: [128]u8 = @splat(0);
        var size: u8 = 0;
        switch (d.select) {
            0x01 => { // ID_NAME
                const name = if (d.kind == .keyboard) "grain-emu keyboard" else "grain-emu tablet";
                @memcpy(data[0..name.len], name);
                size = @intCast(name.len);
            },
            0x11 => switch (d.subsel) { // EV_BITS
                1 => { // EV_KEY
                    if (d.kind == .keyboard) {
                        @memset(data[0..32], 0xff); // codes 0..255
                        data[0] = 0xfe;
                        size = 32;
                    } else {
                        data[0x110 / 8] = 0x07; // BTN_LEFT, BTN_RIGHT, BTN_MIDDLE
                        size = 0x110 / 8 + 1;
                    }
                },
                3 => if (d.kind == .tablet) { // EV_ABS: X and Y
                    data[0] = 0x03;
                    size = 1;
                },
                else => {},
            },
            0x12 => if (d.kind == .tablet and d.subsel <= 1) { // ABS_INFO: min, max, fuzz, flat, res
                std.mem.writeInt(u32, data[4..8], tablet_max, .little);
                size = 20;
            },
            else => {},
        }
        return switch (off) {
            0 => d.select,
            1 => d.subsel,
            2 => size,
            3...7 => 0,
            else => if (off - 8 < data.len) data[@intCast(off - 8)] else 0,
        };
    }

    /// A write to the device's configuration space (input devices select
    /// what to read; nothing else is writable).
    pub fn configWrite(d: *Device, off: u64, v: u8) void {
        if (d.kind != .keyboard and d.kind != .tablet) return;
        switch (off) {
            0 => d.select = v,
            1 => d.subsel = v,
            else => {},
        }
    }

    /// A register write. Returns the queue to process, for a notify.
    pub fn write(d: *Device, off: u64, v: u32) ?u32 {
        switch (off) {
            0x014 => d.device_features_sel = v,
            0x020 => switch (d.driver_features_sel) {
                0 => d.driver_features = (d.driver_features & ~@as(u64, 0xffff_ffff)) | v,
                1 => d.driver_features = (d.driver_features & 0xffff_ffff) | (@as(u64, v) << 32),
                else => {},
            },
            0x024 => d.driver_features_sel = v,
            0x030 => d.queue_sel = v,
            0x038 => if (d.selected()) |q| {
                q.num = if (v >= 1 and v <= queue_max and std.math.isPowerOfTwo(v)) v else 0;
            },
            0x044 => if (d.selected()) |q| {
                q.ready = v == 1 and q.num != 0;
                if (q.ready) q.last_avail = 0;
            },
            0x050 => return v,
            0x064 => d.interrupt_status &= ~v,
            0x070 => {
                if (v == 0) {
                    d.reset();
                } else {
                    var s = v;
                    // FEATURES_OK only for features the device offers.
                    if (s & status_features_ok != 0 and d.driver_features & ~d.offered() != 0) s &= ~status_features_ok;
                    d.status = s;
                }
            },
            0x080 => d.setLow(.desc, v),
            0x084 => d.setHigh(.desc, v),
            0x090 => d.setLow(.driver, v),
            0x094 => d.setHigh(.driver, v),
            0x0a0 => d.setLow(.device, v),
            0x0a4 => d.setHigh(.device, v),
            else => {},
        }
        return null;
    }

    const Field = enum { desc, driver, device };

    fn setLow(d: *Device, comptime f: Field, v: u32) void {
        const q = d.selected() orelse return;
        const p = &@field(q, @tagName(f));
        p.* = (p.* & ~@as(u64, 0xffff_ffff)) | v;
    }

    fn setHigh(d: *Device, comptime f: Field, v: u32) void {
        const q = d.selected() orelse return;
        const p = &@field(q, @tagName(f));
        p.* = (p.* & 0xffff_ffff) | (@as(u64, v) << 32);
    }

    // -----------------------------------------------------------------
    // Queues

    /// The next chain the driver offers, by its head descriptor.
    fn pop(q: *Queue, dma: Dma) ?u16 {
        if (!q.ready) return null;
        const idx = dma.int(u16, q.driver + 2) orelse return null;
        if (idx == q.last_avail) return null;
        const head = dma.int(u16, q.driver + 4 + 2 * @as(u64, q.last_avail % q.num)) orelse return null;
        q.last_avail +%= 1;
        return head;
    }

    fn descAt(q: *const Queue, dma: Dma, i: u16) ?Desc {
        if (i >= q.num) return null;
        const at = q.desc + 16 * @as(u64, i);
        return .{
            .addr = dma.int(u64, at) orelse return null,
            .len = dma.int(u32, at + 8) orelse return null,
            .flags = dma.int(u16, at + 12) orelse return null,
            .next = dma.int(u16, at + 14) orelse return null,
        };
    }

    /// The chain from `head`, at most `out.len` descriptors (a loop or a
    /// chain longer than the queue is cut short).
    fn chain(q: *const Queue, dma: Dma, head: u16, out: []Desc) []Desc {
        var n: usize = 0;
        var i = head;
        while (n < out.len and n < q.num) {
            const desc = descAt(q, dma, i) orelse break;
            out[n] = desc;
            n += 1;
            if (desc.flags & flag_next == 0) break;
            i = desc.next;
        }
        return out[0..n];
    }

    fn push(d: *Device, q: *Queue, dma: Dma, head: u16, len: u32) void {
        const idx = dma.int(u16, q.device + 2) orelse return;
        const at = q.device + 4 + 8 * @as(u64, idx % q.num);
        dma.setInt(u32, at, head);
        dma.setInt(u32, at + 4, len);
        dma.setInt(u16, q.device + 2, idx +% 1);
        d.interrupt_status |= 1;
    }

    /// What a device needs from outside to do its work.
    pub const Io = struct {
        ctx: ?*anyopaque,
        entropy: *const fn (?*anyopaque, []u8) void,
        port_write: *const fn (?*anyopaque, u8, []const u8) void,
        disk_read: *const fn (?*anyopaque, u64, []u8) bool,
        disk_write: *const fn (?*anyopaque, u64, []const u8) bool,
        disk_flush: *const fn (?*anyopaque) bool,
        /// The GPU showed a rectangle of the screen (x, y, width, height).
        display: *const fn (?*anyopaque, u32, u32, u32, u32) void,
    };

    /// Process what the driver offered on queue `qi`.
    pub fn process(d: *Device, qi: u32, dma: Dma, io: Io) void {
        if (qi >= d.queueCount()) return;
        const q = &d.queues[qi];
        switch (d.kind) {
            .rng => while (pop(q, dma)) |head| {
                var buf: [16]Desc = undefined;
                var len: u32 = 0;
                for (chain(q, dma, head, &buf)) |desc| if (desc.flags & flag_write != 0) {
                    if (dma.slice(desc.addr, desc.len)) |s| {
                        io.entropy(io.ctx, s);
                        len += desc.len;
                    }
                };
                d.push(q, dma, head, len);
            },
            .blk => while (pop(q, dma)) |head| {
                var buf: [16]Desc = undefined;
                const parts = chain(q, dma, head, &buf);
                d.push(q, dma, head, blkRequest(d, parts, dma, io));
            },
            .console => if (qi == 1) {
                while (pop(q, dma)) |head| {
                    var buf: [16]Desc = undefined;
                    for (chain(q, dma, head, &buf)) |desc| if (desc.flags & flag_write == 0) {
                        if (dma.slice(desc.addr, desc.len)) |s| io.port_write(io.ctx, d.port, s);
                    };
                    d.push(q, dma, head, 0);
                }
            } else d.deliver(dma),
            .gpu => while (pop(q, dma)) |head| {
                var buf: [16]Desc = undefined;
                d.push(q, dma, head, gpuCommand(d, chain(q, dma, head, &buf), dma, io));
            },
            .keyboard, .tablet => if (qi == 1) {
                // Status (LEDs): taken and handed back.
                while (pop(q, dma)) |head| d.push(q, dma, head, 0);
            } else d.deliver(dma),
        }
    }

    /// An input event from outside (Linux type, code, value). Returns false
    /// if there is no room for it.
    pub fn event(d: *Device, kind: u16, code: u16, value: u32) bool {
        if (d.input.len - d.input_len < 8) return false;
        const e = d.input[d.input_len..][0..8];
        std.mem.writeInt(u16, e[0..2], kind, .little);
        std.mem.writeInt(u16, e[2..4], code, .little);
        std.mem.writeInt(u32, e[4..8], value, .little);
        d.input_len += 8;
        return true;
    }

    /// Hand received bytes to the guest, while it has buffers for them.
    pub fn deliver(d: *Device, dma: Dma) void {
        const q = &d.queues[0];
        while (d.input_len > 0) {
            const head = pop(q, dma) orelse return;
            var buf: [16]Desc = undefined;
            var given: usize = 0;
            for (chain(q, dma, head, &buf)) |desc| if (desc.flags & flag_write != 0) {
                const s = dma.slice(desc.addr, desc.len) orelse continue;
                const n = @min(s.len, d.input_len - given);
                @memcpy(s[0..n], d.input[given..][0..n]);
                given += n;
            };
            std.mem.copyForwards(u8, d.input[0 .. d.input_len - given], d.input[given..d.input_len]);
            d.input_len -= given;
            d.push(q, dma, head, @intCast(given));
        }
    }

    /// Bytes from outside for a console. Returns how many it could keep.
    pub fn receive(d: *Device, bytes: []const u8) usize {
        const n = @min(bytes.len, d.input.len - d.input_len);
        @memcpy(d.input[d.input_len..][0..n], bytes[0..n]);
        d.input_len += n;
        return n;
    }
};

pub const Backing = struct { addr: u64, len: u32 };

// GPU commands and responses (virtio-gpu, 2D).
const gpu_get_display_info: u32 = 0x0100;
const gpu_resource_create_2d: u32 = 0x0101;
const gpu_resource_unref: u32 = 0x0102;
const gpu_set_scanout: u32 = 0x0103;
const gpu_resource_flush: u32 = 0x0104;
const gpu_transfer_to_host_2d: u32 = 0x0105;
const gpu_resource_attach_backing: u32 = 0x0106;
const gpu_resource_detach_backing: u32 = 0x0107;
const gpu_ok_nodata: u32 = 0x1100;
const gpu_ok_display_info: u32 = 0x1101;
const gpu_err_unspec: u32 = 0x1200;
const gpu_err_invalid_resource: u32 = 0x1203;
const gpu_err_invalid_parameter: u32 = 0x1205;

/// One GPU command: the request in the device-readable descriptors, the
/// response in the first device-writable one. Returns the response length.
fn gpuCommand(d: *Device, parts: []const Desc, dma: Dma, io: Device.Io) u32 {
    var req: [1024]u8 = @splat(0);
    var req_len: usize = 0;
    var resp_desc: ?Desc = null;
    for (parts) |desc| {
        if (desc.flags & flag_write != 0) {
            if (resp_desc == null) resp_desc = desc;
            continue;
        }
        const s = dma.slice(desc.addr, desc.len) orelse continue;
        const n = @min(s.len, req.len - req_len);
        @memcpy(req[req_len..][0..n], s[0..n]);
        req_len += n;
    }
    const out_desc = resp_desc orelse return 0;
    const out = dma.slice(out_desc.addr, out_desc.len) orelse return 0;
    if (out.len < 24) return 0;
    const kind = std.mem.readInt(u32, req[0..4], .little);
    const rd = struct {
        fn at(r: []const u8, off: usize) u32 {
            return std.mem.readInt(u32, r[off..][0..4], .little);
        }
    };
    var resp: u32 = gpu_ok_nodata;
    var resp_len: u32 = 24;
    @memset(out, 0);
    switch (kind) {
        gpu_get_display_info => {
            // One display, the size of the screen, enabled.
            if (out.len >= 24 + 24) {
                std.mem.writeInt(u32, out[24 + 8 ..][0..4], d.screen_width, .little);
                std.mem.writeInt(u32, out[24 + 12 ..][0..4], d.screen_height, .little);
                std.mem.writeInt(u32, out[24 + 16 ..][0..4], 1, .little);
            }
            resp = gpu_ok_display_info;
            resp_len = @intCast(@min(out.len, 24 + 16 * 24));
        },
        gpu_resource_create_2d => {
            // id, format, width, height: one resource, the size of the screen.
            const w = rd.at(&req, 32);
            const h = rd.at(&req, 36);
            if (w != d.screen_width or h != d.screen_height or rd.at(&req, 24) == 0) {
                resp = gpu_err_invalid_parameter;
            } else {
                d.resource = rd.at(&req, 24);
                d.resource_format = rd.at(&req, 28);
                d.backing_len = 0;
            }
        },
        gpu_resource_unref => if (rd.at(&req, 24) == d.resource) {
            d.resource = 0;
        },
        gpu_resource_attach_backing => {
            const n = rd.at(&req, 28);
            if (rd.at(&req, 24) != d.resource or n > d.backing.len or 32 + 16 * n > req_len) {
                resp = gpu_err_invalid_parameter;
            } else {
                for (0..n) |i| {
                    const e = req[32 + 16 * i ..][0..16];
                    d.backing[i] = .{ .addr = std.mem.readInt(u64, e[0..8], .little), .len = std.mem.readInt(u32, e[8..12], .little) };
                }
                d.backing_len = n;
            }
        },
        gpu_resource_detach_backing => d.backing_len = 0,
        gpu_set_scanout => {},
        gpu_transfer_to_host_2d => {
            // rect (x, y, w, h), offset, id: copy from the backing, converting
            // to RGBA.
            if (rd.at(&req, 48) != d.resource or d.resource == 0) {
                resp = gpu_err_invalid_resource;
            } else if (!gpuTransfer(d, rd.at(&req, 24), rd.at(&req, 28), rd.at(&req, 32), rd.at(&req, 36), std.mem.readInt(u64, req[40..48], .little), dma)) {
                resp = gpu_err_invalid_parameter;
            }
        },
        gpu_resource_flush => {
            const x = rd.at(&req, 24);
            const y = rd.at(&req, 28);
            const w = rd.at(&req, 32);
            const h = rd.at(&req, 36);
            if (rd.at(&req, 40) != d.resource or d.resource == 0) {
                resp = gpu_err_invalid_resource;
            } else if (@as(u64, x) + w <= d.screen_width and @as(u64, y) + h <= d.screen_height) {
                io.display(io.ctx, x, y, w, h);
            } else resp = gpu_err_invalid_parameter;
        },
        else => resp = gpu_err_unspec,
    }
    std.mem.writeInt(u32, out[0..4], resp, .little);
    return resp_len;
}

/// Copy a rectangle of the resource from its backing to the screen.
fn gpuTransfer(d: *Device, x: u32, y: u32, w: u32, h: u32, offset: u64, dma: Dma) bool {
    if (@as(u64, x) + w > d.screen_width or @as(u64, y) + h > d.screen_height) return false;
    const stride: u64 = @as(u64, d.screen_width) * 4;
    var row: u32 = 0;
    var line: [4 * 4096]u8 = undefined;
    while (row < h) : (row += 1) {
        const bytes = @as(usize, w) * 4;
        if (bytes > line.len) return false;
        if (!backingRead(d, dma, offset + row * stride, line[0..bytes])) return false;
        const dst = d.screen[@intCast((@as(u64, y) + row) * stride + @as(u64, x) * 4)..][0..bytes];
        var i: usize = 0;
        while (i < bytes) : (i += 4) {
            // B8G8R8X8 / B8G8R8A8 (formats 1 and 2) to R, G, B, opaque.
            dst[i] = line[i + 2];
            dst[i + 1] = line[i + 1];
            dst[i + 2] = line[i];
            dst[i + 3] = 0xff;
        }
    }
    return true;
}

/// Read `out.len` bytes at `offset` in the resource's backing (scattered pages).
fn backingRead(d: *const Device, dma: Dma, offset: u64, out: []u8) bool {
    var off = offset;
    var done: usize = 0;
    var base: u64 = 0;
    for (d.backing[0..d.backing_len]) |b| {
        if (done == out.len) break;
        if (off < base + b.len) {
            const within = off - base;
            const n: usize = @intCast(@min(b.len - within, out.len - done));
            const src = dma.peek(b.addr + within, n) orelse return false;
            @memcpy(out[done..][0..n], src);
            done += n;
            off += n;
        }
        base += b.len;
    }
    return done == out.len;
}

const blk_in: u32 = 0;
const blk_out: u32 = 1;
const blk_flush: u32 = 4;
const blk_get_id: u32 = 8;

/// One block request: header, data buffers, status byte. Returns the bytes
/// written into device-writable buffers.
fn blkRequest(d: *Device, parts: []const Desc, dma: Dma, io: Device.Io) u32 {
    if (parts.len < 2) return 0;
    const status_desc = parts[parts.len - 1];
    const status = dma.slice(status_desc.addr, 1) orelse return 0;
    const header = dma.slice(parts[0].addr, 16) orelse {
        status[0] = 1;
        return 1;
    };
    const kind = std.mem.readInt(u32, header[0..4], .little);
    const sector = std.mem.readInt(u64, header[8..16], .little);
    const data = parts[1 .. parts.len - 1];
    var written: u32 = 0;
    var ok = true;
    switch (kind) {
        blk_in, blk_out => {
            var offset = sector *| 512;
            for (data) |desc| {
                const s = dma.slice(desc.addr, desc.len) orelse {
                    ok = false;
                    break;
                };
                if (offset +| s.len > d.sectors * 512) {
                    ok = false;
                    break;
                }
                if (kind == blk_in) {
                    if (desc.flags & flag_write == 0 or !io.disk_read(io.ctx, offset, s)) {
                        ok = false;
                        break;
                    }
                    written += desc.len;
                } else if (!io.disk_write(io.ctx, offset, s)) {
                    ok = false;
                    break;
                }
                offset += s.len;
            }
        },
        blk_flush => ok = io.disk_flush(io.ctx),
        blk_get_id => {
            if (data.len > 0) if (dma.slice(data[0].addr, @min(data[0].len, 20))) |s| {
                @memset(s, 0);
                const id = "grain-emu-disk";
                @memcpy(s[0..@min(s.len, id.len)], id[0..@min(s.len, id.len)]);
                written += @intCast(s.len);
            };
        },
        else => {
            status[0] = 2; // unsupported
            return written + 1;
        },
    }
    status[0] = if (ok) 0 else 1;
    return written + 1;
}

// ---------------------------------------------------------------------------
// Tests

const TestRam = struct {
    bytes: [64 * 1024]u8 = @splat(0),
    const base: u64 = 0x8000_0000;

    fn dma(r: *TestRam) Dma {
        return .{ .ram = &r.bytes, .base = base, .ctx = r, .written = noWrite };
    }
    fn noWrite(_: *anyopaque, _: u64, _: u64) void {}
    fn put(r: *TestRam, off: usize, comptime T: type, v: T) void {
        std.mem.writeInt(T, r.bytes[off..][0..@sizeOf(T)], v, .little);
    }
    fn get(r: *TestRam, off: usize, comptime T: type) T {
        return std.mem.readInt(T, r.bytes[off..][0..@sizeOf(T)], .little);
    }
};

const TestIo = struct {
    var flushed: [4]u32 = .{ 0, 0, 0, 0 };
    fn display(_: ?*anyopaque, x: u32, y: u32, w: u32, h: u32) void {
        flushed = .{ x, y, w, h };
    }
    fn none(_: ?*anyopaque, _: []u8) void {}
    fn port(_: ?*anyopaque, _: u8, _: []const u8) void {}
    fn rd(_: ?*anyopaque, _: u64, _: []u8) bool {
        return false;
    }
    fn wr(_: ?*anyopaque, _: u64, _: []const u8) bool {
        return false;
    }
    fn fl(_: ?*anyopaque) bool {
        return true;
    }
    const io: Device.Io = .{ .ctx = null, .entropy = none, .port_write = port, .disk_read = rd, .disk_write = wr, .disk_flush = fl, .display = display };
};

/// A GPU command in RAM at 0 (request) and 0x800 (response); returns the
/// response type.
fn testGpu(d: *Device, r: *TestRam, req: []const u32) u32 {
    for (req, 0..) |w, i| r.put(4 * i, u32, w);
    const parts = [_]Desc{
        .{ .addr = TestRam.base, .len = @intCast(4 * req.len), .flags = 0, .next = 0 },
        .{ .addr = TestRam.base + 0x800, .len = 24 + 16 * 24, .flags = flag_write, .next = 0 },
    };
    _ = gpuCommand(d, &parts, r.dma(), TestIo.io);
    return r.get(0x800, u32);
}

test "gpu: display info, a resource, a transfer converts to RGBA, a flush shows it" {
    var r: TestRam = .{};
    var screen: [4 * 2 * 4]u8 = @splat(0);
    var d: Device = .{ .kind = .gpu, .screen = &screen, .screen_width = 4, .screen_height = 2 };
    // Each request: the 24-byte header (type, flags, fence id (2), ctx id, ring) then its fields.
    try std.testing.expectEqual(gpu_ok_display_info, testGpu(&d, &r, &.{ gpu_get_display_info, 0, 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u32, 4), r.get(0x800 + 24 + 8, u32));
    try std.testing.expectEqual(@as(u32, 1), r.get(0x800 + 24 + 16, u32));
    // A resource of another size is refused; the screen's size is taken.
    try std.testing.expectEqual(gpu_err_invalid_parameter, testGpu(&d, &r, &.{ gpu_resource_create_2d, 0, 0, 0, 0, 0, 7, 2, 8, 8 }));
    try std.testing.expectEqual(gpu_ok_nodata, testGpu(&d, &r, &.{ gpu_resource_create_2d, 0, 0, 0, 0, 0, 7, 2, 4, 2 }));
    // Backing: two pieces, 10 bytes at +0x1000 and 22 bytes at +0x2000.
    const lo: u32 = @truncate(TestRam.base);
    try std.testing.expectEqual(gpu_ok_nodata, testGpu(&d, &r, &.{ gpu_resource_attach_backing, 0, 0, 0, 0, 0, 7, 2, lo + 0x1000, 0, 10, 0, lo + 0x2000, 0, 22, 0 }));
    // Pixel n of the resource is B=n, G=0x10+n, R=0x20+n (pixel 2 straddles the pieces).
    for (0..32) |logical| {
        const n = logical / 4;
        const byte: u8 = switch (logical % 4) {
            0 => @intCast(n),
            1 => @intCast(0x10 + n),
            2 => @intCast(0x20 + n),
            else => 0,
        };
        r.bytes[if (logical < 10) 0x1000 + logical else 0x2000 + (logical - 10)] = byte;
    }
    // Transfer x=1, y=0, 2x2, from offset (0 * 4 + 1) * 4.
    try std.testing.expectEqual(gpu_ok_nodata, testGpu(&d, &r, &.{ gpu_transfer_to_host_2d, 0, 0, 0, 0, 0, 1, 0, 2, 2, 4, 0, 7, 0 }));
    // Pixel 6 (x=2, y=1) is now R=0x26, G=0x16, B=0x06, opaque; pixel 2 came
    // from both pieces; pixel 0 is untouched.
    try std.testing.expectEqualSlices(u8, &.{ 0x26, 0x16, 0x06, 0xff }, screen[4 * 6 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0x22, 0x12, 0x02, 0xff }, screen[4 * 2 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, screen[0..4]);
    try std.testing.expectEqual(gpu_ok_nodata, testGpu(&d, &r, &.{ gpu_resource_flush, 0, 0, 0, 0, 0, 1, 0, 2, 2, 7, 0 }));
    try std.testing.expectEqual([4]u32{ 1, 0, 2, 2 }, TestIo.flushed);
    // Out of the screen: refused.
    try std.testing.expectEqual(gpu_err_invalid_parameter, testGpu(&d, &r, &.{ gpu_resource_flush, 0, 0, 0, 0, 0, 3, 0, 2, 2, 7, 0 }));
}

test "input: the tablet reports absolute axes, the keyboard keys" {
    var tablet: Device = .{ .kind = .tablet };
    tablet.configWrite(0, 0x11);
    tablet.configWrite(1, 3); // EV_ABS: some bits
    try std.testing.expect((tablet.read(0x100) >> 16) & 0xff > 0);
    tablet.configWrite(0, 0x12);
    tablet.configWrite(1, 0); // ABS_INFO for X: max after min
    try std.testing.expectEqual(tablet_max, tablet.read(0x100 + 8 + 4));
    var keyboard: Device = .{ .kind = .keyboard };
    keyboard.configWrite(0, 0x11);
    keyboard.configWrite(1, 3); // EV_ABS: none
    try std.testing.expectEqual(@as(u32, 0), (keyboard.read(0x100) >> 16) & 0xff);
    keyboard.configWrite(1, 1); // EV_KEY: KEY_A (30) among them
    try std.testing.expect((keyboard.read(0x100 + 8) >> 30) & 1 == 1);
}

test "input: an event lands in a buffer the driver lent" {
    var r: TestRam = .{};
    var d: Device = .{ .kind = .keyboard };
    // Queue 0 at 0x1000 (descriptors), 0x1100 (available), 0x1200 (used); one buffer at 0x3000.
    d.queues[0] = .{ .num = 16, .ready = true, .desc = TestRam.base + 0x1000, .driver = TestRam.base + 0x1100, .device = TestRam.base + 0x1200 };
    r.put(0x1000, u64, TestRam.base + 0x3000);
    r.put(0x1008, u32, 8);
    r.put(0x100c, u16, flag_write);
    r.put(0x1104, u16, 0); // ring[0] = descriptor 0
    r.put(0x1102, u16, 1); // avail idx
    try std.testing.expect(d.event(1, 30, 1)); // KEY_A down
    d.deliver(r.dma());
    try std.testing.expectEqual(@as(u16, 1), r.get(0x1202, u16)); // used idx
    try std.testing.expectEqual(@as(u32, 8), r.get(0x1208, u32)); // length
    try std.testing.expectEqual(@as(u16, 1), r.get(0x3000, u16));
    try std.testing.expectEqual(@as(u16, 30), r.get(0x3002, u16));
    try std.testing.expectEqual(@as(u32, 1), r.get(0x3004, u32));
    try std.testing.expect(d.interrupt_status & 1 != 0);
}
