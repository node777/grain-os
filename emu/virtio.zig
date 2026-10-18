//! virtio-mmio (version 2, "modern") devices: entropy (4), block (2) and a
//! single-port console (3), as Grain's drivers use them. Split virtqueues,
//! no event index, no indirect descriptors.
//!
//! A device sees guest memory through `Dma` and the outside world through
//! the machine's `Host`; the machine routes register accesses and raises
//! the device's PLIC line while `interrupt_status` is non-zero.
const std = @import("std");

pub const Kind = enum { rng, blk, console };

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
    /// Consoles: bytes received and not yet given to the guest.
    input: [8192]u8 = undefined,
    input_len: usize = 0,

    pub fn deviceId(d: *const Device) u32 {
        return switch (d.kind) {
            .blk => 2,
            .console => 3,
            .rng => 4,
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
        return if (d.kind == .console) 2 else 1;
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
            else => 0,
        };
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
        }
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
