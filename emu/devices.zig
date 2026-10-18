//! The small devices of QEMU's `virt` board that Caravan uses: the PLIC
//! (riscv,plic0), a 16550 UART, and the SiFive test finisher. Register
//! layouts follow QEMU's, so the same kernel runs on both unchanged.
const std = @import("std");

pub const plic_base: u64 = 0x0c00_0000;
pub const plic_size: u64 = 0x60_0000;
pub const plic_ndev = 95;
pub const uart_base: u64 = 0x1000_0000;
pub const uart_size: u64 = 0x100;
pub const uart_irq = 10;
pub const finisher_base: u64 = 0x10_0000;
pub const finisher_size: u64 = 0x1000;

pub const max_contexts = 2 * 8;

/// Context 2h is hart h's M-mode (unused here), 2h+1 its S-mode, as on QEMU.
pub const Plic = struct {
    priority: [plic_ndev + 1]u32 = @splat(0),
    /// Lines a device is asserting (bit = line).
    level: u128 = 0,
    /// Claimed and not yet completed.
    claimed: u128 = 0,
    enable: [max_contexts]u128 = @splat(0),
    threshold: [max_contexts]u32 = @splat(0),

    pub fn setLevel(p: *Plic, line: u32, on: bool) void {
        const bit = @as(u128, 1) << @intCast(line);
        p.level = if (on) p.level | bit else p.level & ~bit;
    }

    fn best(p: *const Plic, ctx: usize) u32 {
        var cand = p.level & ~p.claimed & p.enable[ctx];
        if (cand == 0) return 0;
        var id: u32 = 0;
        var prio: u32 = p.threshold[ctx];
        while (cand != 0) {
            const line: u32 = @intCast(@ctz(cand));
            cand &= cand - 1;
            if (line <= plic_ndev and p.priority[line] > prio) {
                prio = p.priority[line];
                id = line;
            }
        }
        return id;
    }

    /// Whether hart `hart`'s S-mode external interrupt is pending.
    pub fn pendingFor(p: *const Plic, hart: u32) bool {
        const ctx = 2 * @as(usize, hart) + 1;
        if (ctx >= max_contexts) return false;
        if (p.level & ~p.claimed & p.enable[ctx] == 0) return false;
        return p.best(ctx) != 0;
    }

    pub fn read(p: *Plic, off: u64) u32 {
        if (off < 0x1000) {
            const line = off / 4;
            return if (line <= plic_ndev) p.priority[@intCast(line)] else 0;
        }
        if (off >= 0x1000 and off < 0x1010) {
            const word = (off - 0x1000) / 4;
            return @truncate((p.level & ~p.claimed) >> @intCast(32 * word));
        }
        if (off >= 0x2000 and off < 0x2000 + 0x80 * max_contexts) {
            const ctx: usize = @intCast((off - 0x2000) / 0x80);
            const word = ((off - 0x2000) % 0x80) / 4;
            if (word >= 4) return 0;
            return @truncate(p.enable[ctx] >> @intCast(32 * word));
        }
        if (off >= 0x20_0000) {
            const ctx: usize = @intCast((off - 0x20_0000) / 0x1000);
            if (ctx >= max_contexts) return 0;
            switch ((off - 0x20_0000) % 0x1000) {
                0 => return p.threshold[ctx],
                4 => {
                    const id = p.best(ctx);
                    if (id != 0) p.claimed |= @as(u128, 1) << @intCast(id);
                    return id;
                },
                else => return 0,
            }
        }
        return 0;
    }

    pub fn write(p: *Plic, off: u64, v: u32) void {
        if (off < 0x1000) {
            const line = off / 4;
            if (line >= 1 and line <= plic_ndev) p.priority[@intCast(line)] = v & 7;
            return;
        }
        if (off >= 0x2000 and off < 0x2000 + 0x80 * max_contexts) {
            const ctx: usize = @intCast((off - 0x2000) / 0x80);
            const word = ((off - 0x2000) % 0x80) / 4;
            if (word >= 4) return;
            const shift: u7 = @intCast(32 * word);
            const mask = @as(u128, 0xffff_ffff) << shift;
            p.enable[ctx] = (p.enable[ctx] & ~mask) | (@as(u128, v) << shift) & ~@as(u128, 1);
            return;
        }
        if (off >= 0x20_0000) {
            const ctx: usize = @intCast((off - 0x20_0000) / 0x1000);
            if (ctx >= max_contexts) return;
            switch ((off - 0x20_0000) % 0x1000) {
                0 => p.threshold[ctx] = v & 7,
                4 => if (v >= 1 and v <= plic_ndev) {
                    p.claimed &= ~(@as(u128, 1) << @intCast(v));
                },
                else => {},
            }
        }
    }
};

/// A 16550: output goes to the console, input comes from `rx`. The
/// transmitter is always empty (sending is instant).
pub const Uart = struct {
    ier: u8 = 0,
    lcr: u8 = 0,
    mcr: u8 = 0,
    scr: u8 = 0,
    fcr: u8 = 0,
    dll: u8 = 0,
    dlm: u8 = 0,
    /// A "transmitter empty" interrupt is owed (cleared by reading IIR).
    thr_pending: bool = false,
    rx: [64]u8 = undefined,
    rx_len: usize = 0,

    pub fn interrupt(u: *const Uart) bool {
        return (u.ier & 2 != 0 and u.thr_pending) or (u.ier & 1 != 0 and u.rx_len > 0);
    }

    pub fn read(u: *Uart, off: u64) u8 {
        const dlab = u.lcr & 0x80 != 0;
        return switch (off) {
            0 => if (dlab) u.dll else blk: {
                if (u.rx_len == 0) break :blk 0;
                const c = u.rx[0];
                std.mem.copyForwards(u8, u.rx[0 .. u.rx_len - 1], u.rx[1..u.rx_len]);
                u.rx_len -= 1;
                break :blk c;
            },
            1 => if (dlab) u.dlm else u.ier,
            2 => blk: {
                const fifo: u8 = if (u.fcr & 1 != 0) 0xc0 else 0;
                if (u.ier & 1 != 0 and u.rx_len > 0) break :blk fifo | 0x04;
                if (u.ier & 2 != 0 and u.thr_pending) {
                    u.thr_pending = false;
                    break :blk fifo | 0x02;
                }
                break :blk fifo | 0x01;
            },
            3 => u.lcr,
            4 => u.mcr,
            5 => 0x60 | @as(u8, @intFromBool(u.rx_len > 0)),
            6 => 0xb0,
            7 => u.scr,
            else => 0,
        };
    }

    /// Returns a byte to send, if this write sent one.
    pub fn write(u: *Uart, off: u64, v: u8) ?u8 {
        const dlab = u.lcr & 0x80 != 0;
        switch (off) {
            0 => if (dlab) {
                u.dll = v;
            } else {
                if (u.ier & 2 != 0) u.thr_pending = true;
                return v;
            },
            1 => if (dlab) {
                u.dlm = v;
            } else {
                const was = u.ier;
                u.ier = v & 0x0f;
                if (u.ier & 2 != 0 and was & 2 == 0) u.thr_pending = true;
                if (u.ier & 2 == 0) u.thr_pending = false;
            },
            2 => u.fcr = v,
            3 => u.lcr = v,
            4 => u.mcr = v,
            7 => u.scr = v,
            else => {},
        }
        return null;
    }

    pub fn receive(u: *Uart, c: u8) bool {
        if (u.rx_len == u.rx.len) return false;
        u.rx[u.rx_len] = c;
        u.rx_len += 1;
        return true;
    }
};

/// The SiFive test finisher: what a write means for the machine.
pub const Finish = union(enum) { pass, fail: u16, reset, none };

pub fn finisherWrite(v: u32) Finish {
    return switch (v & 0xffff) {
        0x5555 => .pass,
        0x3333 => .{ .fail = @truncate(v >> 16) },
        0x7777 => .reset,
        else => .none,
    };
}

test "plic claims the highest-priority enabled line, once" {
    var p: Plic = .{};
    p.write(4 * 3, 1);
    p.write(4 * 5, 2);
    p.write(0x2000 + 0x80 * 1, (1 << 3) | (1 << 5));
    p.setLevel(3, true);
    p.setLevel(5, true);
    try std.testing.expect(p.pendingFor(0));
    try std.testing.expectEqual(@as(u32, 5), p.read(0x20_0000 + 0x1000 + 4));
    try std.testing.expectEqual(@as(u32, 3), p.read(0x20_0000 + 0x1000 + 4));
    try std.testing.expect(!p.pendingFor(0));
    p.write(0x20_0000 + 0x1000 + 4, 5);
    try std.testing.expect(p.pendingFor(0)); // still asserted
    p.setLevel(5, false);
    try std.testing.expect(!p.pendingFor(0));
}

test "uart transmit interrupt follows IER and IIR reads" {
    var u: Uart = .{};
    try std.testing.expect(!u.interrupt());
    _ = u.write(1, 0x02);
    try std.testing.expect(u.interrupt());
    try std.testing.expectEqual(@as(u8, 0x02), u.read(2));
    try std.testing.expect(!u.interrupt());
    try std.testing.expectEqual(@as(?u8, 'x'), u.write(0, 'x'));
    try std.testing.expect(u.interrupt());
    _ = u.write(1, 0);
    try std.testing.expect(!u.interrupt());
}
