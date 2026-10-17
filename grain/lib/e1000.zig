//! Intel 8254x ("e1000") Gigabit Ethernet: frames in and out.
//!
//! The registers are BAR 0. Sixteen receive descriptors, each with a 2 KiB
//! buffer (two per page), are handed to the card and handed back as soon as
//! their frame is copied out; eight transmit descriptors, each with its own
//! 2 KiB buffer, are used in turn. Legacy descriptors, no offloads: the same
//! interface as virtio-net, so Mycelium drives either.
const std = @import("std");
const grain = @import("grain.zig");

pub const vendor: u16 = 0x8086;
/// 82540EM, 82545EM and 82544GC: the parts QEMU (and many machines) offer.
pub const devices = [_]u16{ 0x100e, 0x100f, 0x1004 };

pub fn supports(v: u16, d: u16) bool {
    return v == vendor and std.mem.indexOfScalar(u16, &devices, d) != null;
}

const buffer = 2048;
pub const max_frame = 1518;
const rx_count = 16;
const tx_count = 8;

pub const Page = struct { va: usize, pa: u64 };

pub const Error = error{ TooLarge, Timeout };

const Reg = struct {
    const ctrl = 0x0000;
    const icr = 0x00c0;
    const ims = 0x00d0;
    const imc = 0x00d8;
    const rctl = 0x0100;
    const tctl = 0x0400;
    const tipg = 0x0410;
    const rdbal = 0x2800;
    const rdbah = 0x2804;
    const rdlen = 0x2808;
    const rdh = 0x2810;
    const rdt = 0x2818;
    const tdbal = 0x3800;
    const tdbah = 0x3804;
    const tdlen = 0x3808;
    const tdh = 0x3810;
    const tdt = 0x3818;
    const mta = 0x5200;
    const ral0 = 0x5400;
    const rah0 = 0x5404;
};

const RxDesc = extern struct { addr: u64, length: u16, checksum: u16, status: u8, errors: u8, special: u16 };
const TxDesc = extern struct { addr: u64, length: u16, cso: u8, cmd: u8, status: u8, css: u8, special: u16 };

const dd: u8 = 1; // descriptor done
const eop: u8 = 2; // end of packet (rx status)
const cmd_eop: u8 = 1;
const cmd_ifcs: u8 = 2; // insert the frame checksum
const cmd_rs: u8 = 8; // report status

pub const E1000 = struct {
    regs: usize,
    rings: Page,
    rx: [8]Page,
    tx: [4]Page,
    mac: [6]u8,
    rx_next: u16 = 0,
    tx_next: u16 = 0,
    /// Which transmit descriptors the card still holds.
    tx_busy: [tx_count]bool = @splat(false),

    /// `rings`: one page for both descriptor rings; `rx`/`tx`: buffer pages.
    pub fn init(regs: usize, rings: Page, rx: [8]Page, tx: [4]Page) Error!E1000 {
        var e: E1000 = .{ .regs = regs, .rings = rings, .rx = rx, .tx = tx, .mac = undefined };
        // Reset, then bring the link up.
        e.write(Reg.imc, 0xffff_ffff);
        e.write(Reg.ctrl, e.read(Reg.ctrl) | 1 << 26);
        var spins: usize = 0;
        while (e.read(Reg.ctrl) & (1 << 26) != 0) : (spins += 1) {
            if (spins > 1_000_000) return error.Timeout;
            grain.yield();
        }
        e.write(Reg.imc, 0xffff_ffff);
        e.write(Reg.ctrl, e.read(Reg.ctrl) | 1 << 6 | 1 << 5); // set link up, auto speed
        // The address the EEPROM put in receive address 0.
        const lo = e.read(Reg.ral0);
        const hi = e.read(Reg.rah0);
        e.mac = .{ @truncate(lo), @truncate(lo >> 8), @truncate(lo >> 16), @truncate(lo >> 24), @truncate(hi), @truncate(hi >> 8) };
        for (0..128) |i| e.write(Reg.mta + i * 4, 0);

        @memset(@as([*]u8, @ptrFromInt(rings.va))[0..4096], 0);
        const rxd = e.rxRing();
        for (rxd, 0..) |*d, i| d.* = .{ .addr = e.rxBuffer(@intCast(i)).pa, .length = 0, .checksum = 0, .status = 0, .errors = 0, .special = 0 };
        e.write(Reg.rdbal, @truncate(rings.pa));
        e.write(Reg.rdbah, @truncate(rings.pa >> 32));
        e.write(Reg.rdlen, rx_count * @sizeOf(RxDesc));
        e.write(Reg.rdh, 0);
        e.write(Reg.rdt, rx_count - 1);
        const tx_pa = rings.pa + 1024;
        e.write(Reg.tdbal, @truncate(tx_pa));
        e.write(Reg.tdbah, @truncate(tx_pa >> 32));
        e.write(Reg.tdlen, tx_count * @sizeOf(TxDesc));
        e.write(Reg.tdh, 0);
        e.write(Reg.tdt, 0);
        // Receive: on, broadcast, 2 KiB buffers, strip the CRC.
        e.write(Reg.rctl, 1 << 1 | 1 << 15 | 1 << 26);
        // Transmit: on, pad short frames, the usual collision settings.
        e.write(Reg.tctl, 1 << 1 | 1 << 3 | 0x10 << 4 | 0x40 << 12);
        e.write(Reg.tipg, 0x0060_200a);
        // Interrupt on receive (timer and threshold) and transmit done.
        e.write(Reg.ims, 1 << 7 | 1 << 4 | 1 << 0);
        return e;
    }

    fn read(e: *const E1000, off: usize) u32 {
        return @as(*volatile u32, @ptrFromInt(e.regs + off)).*;
    }
    fn write(e: *const E1000, off: usize, v: u32) void {
        @as(*volatile u32, @ptrFromInt(e.regs + off)).* = v;
    }

    fn rxRing(e: *const E1000) *volatile [rx_count]RxDesc {
        return @ptrFromInt(e.rings.va);
    }
    fn txRing(e: *const E1000) *volatile [tx_count]TxDesc {
        return @ptrFromInt(e.rings.va + 1024);
    }

    fn rxBuffer(e: *const E1000, i: u16) Page {
        const p = e.rx[i / 2];
        const off: usize = (i % 2) * buffer;
        return .{ .va = p.va + off, .pa = p.pa + off };
    }

    fn txBuffer(e: *const E1000, i: u16) Page {
        const p = e.tx[i / 2];
        const off: usize = (i % 2) * buffer;
        return .{ .va = p.va + off, .pa = p.pa + off };
    }

    /// Acknowledge the interrupt (reading the cause clears it).
    pub fn ack(e: *const E1000) void {
        _ = e.read(Reg.icr);
    }

    /// The next frame the card received, copied into `out`, if any.
    pub fn recv(e: *E1000, out: []u8) ?[]u8 {
        while (true) {
            grain.fence();
            const d = &e.rxRing()[e.rx_next];
            if (d.status & dd == 0) return null;
            const i = e.rx_next;
            const whole = d.status & eop != 0 and d.errors == 0;
            const len = @min(@as(usize, d.length), out.len);
            if (whole) @memcpy(out[0..len], @as([*]const u8, @ptrFromInt(e.rxBuffer(i).va))[0..len]);
            d.status = 0;
            e.rx_next = (e.rx_next + 1) % rx_count;
            grain.fence();
            e.write(Reg.rdt, i); // the card may use it again
            if (whole) return out[0..len];
        }
    }

    /// Send a frame. Waits (yielding) only if all eight descriptors are busy.
    pub fn send(e: *E1000, frame: []const u8) Error!void {
        if (frame.len > max_frame) return error.TooLarge;
        const i = e.tx_next;
        const d = &e.txRing()[i];
        while (e.tx_busy[i] and d.status & dd == 0) grain.yield();
        const b = e.txBuffer(i);
        @memcpy(@as([*]u8, @ptrFromInt(b.va))[0..frame.len], frame);
        d.* = .{ .addr = b.pa, .length = @intCast(frame.len), .cso = 0, .cmd = cmd_eop | cmd_ifcs | cmd_rs, .status = 0, .css = 0, .special = 0 };
        e.tx_busy[i] = true;
        e.tx_next = (i + 1) % tx_count;
        grain.fence();
        e.write(Reg.tdt, e.tx_next);
    }
};

comptime {
    std.debug.assert(@sizeOf(RxDesc) == 16 and @sizeOf(TxDesc) == 16);
}
