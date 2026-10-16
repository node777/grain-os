//! Trap entry and decoding. Every trap — interrupt or exception — arrives at
//! `entry`, which saves the full integer register file into a `Frame` on the
//! current stack and calls the portable dispatcher with a decoded `Cause`.
//! Today all traps come from S-mode; user-mode entry (sscratch stack swap)
//! arrives with the first user domain.
const std = @import("std");
const csr = @import("csr.zig");

pub const Frame = extern struct {
    /// x0..x31; slot 0 is unused, slot 2 holds the interrupted sp.
    x: [32]usize,
    sepc: usize,
    sstatus: usize,

    comptime {
        std.debug.assert(@sizeOf(Frame) % 16 == 0);
    }
};

pub const Cause = union(enum) {
    timer,
    software,
    external,
    breakpoint: usize,
    ecall_user: usize,
    page_fault: struct { addr: usize, kind: Access },
    illegal_instruction: usize,
    other: struct { scause: usize, stval: usize },

    pub const Access = enum { fetch, load, store };
};

const interrupt_bit: usize = 1 << 63;

pub fn decode(scause: usize, stval: usize) Cause {
    if (scause & interrupt_bit != 0) return switch (scause & ~interrupt_bit) {
        1 => .software,
        5 => .timer,
        9 => .external,
        else => .{ .other = .{ .scause = scause, .stval = stval } },
    };
    return switch (scause) {
        2 => .{ .illegal_instruction = stval },
        3 => .{ .breakpoint = stval },
        8 => .{ .ecall_user = stval },
        12 => .{ .page_fault = .{ .addr = stval, .kind = .fetch } },
        13 => .{ .page_fault = .{ .addr = stval, .kind = .load } },
        15 => .{ .page_fault = .{ .addr = stval, .kind = .store } },
        else => .{ .other = .{ .scause = scause, .stval = stval } },
    };
}

/// Length in bytes of the instruction at `pc` (2 if compressed, else 4).
pub fn instructionLength(pc: usize) usize {
    const half: *const volatile u16 = @ptrFromInt(pc);
    return if (half.* & 0b11 == 0b11) 4 else 2;
}

const frame_size = @sizeOf(Frame);
const off_sepc = @offsetOf(Frame, "sepc");
const off_sstatus = @offsetOf(Frame, "sstatus");

fn regOps(comptime op: []const u8) []const u8 {
    comptime var s: []const u8 = "";
    inline for (1..32) |i| {
        if (i == 2) continue;
        s = s ++ std.fmt.comptimePrint("{s} x{d}, {d}(sp)\n", .{ op, i, i * 8 });
    }
    return s;
}

pub fn entry() align(4) callconv(.naked) noreturn {
    asm volatile (std.fmt.comptimePrint("addi sp, sp, -{d}\n", .{frame_size}) ++
            regOps("sd") ++
            std.fmt.comptimePrint(
                \\addi t0, sp, {[size]d}
                \\sd t0, 16(sp)
                \\csrr t0, sepc
                \\sd t0, {[sepc]d}(sp)
                \\csrr t0, sstatus
                \\sd t0, {[sstatus]d}(sp)
                \\mv a0, sp
                \\call caravanTrap
                \\ld t0, {[sepc]d}(sp)
                \\csrw sepc, t0
                \\ld t0, {[sstatus]d}(sp)
                \\csrw sstatus, t0
                \\
            , .{ .size = frame_size, .sepc = off_sepc, .sstatus = off_sstatus }) ++
            regOps("ld") ++
            std.fmt.comptimePrint(
                \\addi sp, sp, {d}
                \\sret
            , .{frame_size}));
}

pub fn install() void {
    // Direct mode (low bits 00): every trap enters `entry`.
    csr.write("stvec", @intFromPtr(&entry));
}
