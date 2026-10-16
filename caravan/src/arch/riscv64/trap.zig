//! Trap entry and exit.
//!
//! While a user thread runs, `sscratch` holds the address of its saved
//! `Context`; while the kernel runs, `sscratch` is 0. Every trap enters at
//! `caravanTrapEntry`, which swaps a0 with sscratch to tell the two apart:
//!
//!   from user:   save all registers into the thread's Context, switch to the
//!                hart's kernel stack and call `caravanUserTrap(ctx)` (never returns)
//!   from kernel: push a Frame on the current stack and call
//!                `caravanKernelTrap(frame)`; returns with sret if it returns
//!
//! `caravanResume(ctx)` loads a Context and drops to user mode.
const std = @import("std");
const core = @import("core");

pub const Context = extern struct {
    /// x0..x31 (slot 0 unused).
    x: [32]u64 = @splat(0),
    pc: u64 = 0,
    /// Set before resuming: where the kernel stack starts on the next trap.
    kernel_sp: u64 = 0,
    /// Set before resuming: the hart-local block (loaded into tp on entry).
    hart_local: u64 = 0,
    _pad: u64 = 0,

    pub fn init(pc: u64, sp: u64, a0: u64) Context {
        var c: Context = .{ .pc = pc };
        c.x[2] = sp;
        c.x[10] = a0;
        return c;
    }

    fn index(r: core.kernel.Reg) usize {
        return switch (r) {
            .pc => unreachable,
            .sp => 2,
            .a0 => 10,
            .a1 => 11,
            .a2 => 12,
            .a3 => 13,
            .a4 => 14,
            .a5 => 15,
            .a6 => 16,
            .a7 => 17,
        };
    }

    pub fn get(c: *const Context, r: core.kernel.Reg) usize {
        return if (r == .pc) c.pc else c.x[index(r)];
    }

    pub fn set(c: *Context, r: core.kernel.Reg, v: usize) void {
        if (r == .pc) c.pc = v else c.x[index(r)] = v;
    }
};

/// Registers saved for a trap taken in kernel mode.
pub const Frame = extern struct {
    x: [32]u64,
    sepc: u64,
    sstatus: u64,
};

const off_pc = @offsetOf(Context, "pc");
const off_ksp = @offsetOf(Context, "kernel_sp");
const off_hl = @offsetOf(Context, "hart_local");
const frame_size = @sizeOf(Frame);

comptime {
    std.debug.assert(@sizeOf(Context) % 16 == 0);
    std.debug.assert(frame_size % 16 == 0);
}

fn regOps(comptime op: []const u8, comptime base: []const u8, comptime skip: []const u8) []const u8 {
    comptime var s: []const u8 = "";
    inline for (1..32) |i| {
        const skipped = comptime std.mem.indexOfScalar(u8, skip, i) != null;
        if (!skipped) s = s ++ std.fmt.comptimePrint("{s} x{d}, {d}({s})\n", .{ op, i, i * 8, base });
    }
    return s;
}

comptime {
    asm (std.fmt.comptimePrint(
            \\.section .text
            \\.balign 4
            \\.global caravanTrapEntry
            \\caravanTrapEntry:
            \\    csrrw a0, sscratch, a0
            \\    beqz a0, .Lfrom_kernel
            \\
        , .{}) ++
            regOps("sd", "a0", &.{10}) ++
            std.fmt.comptimePrint(
                \\    csrr t0, sscratch
                \\    sd t0, 80(a0)
                \\    csrr t0, sepc
                \\    sd t0, {[pc]d}(a0)
                \\    ld sp, {[ksp]d}(a0)
                \\    ld tp, {[hl]d}(a0)
                \\    csrw sscratch, zero
                \\    call caravanUserTrap
                \\    unimp
                \\.Lfrom_kernel:
                \\    csrrw a0, sscratch, a0
                \\    addi sp, sp, -{[fs]d}
                \\
            , .{ .pc = off_pc, .ksp = off_ksp, .hl = off_hl, .fs = frame_size }) ++
            regOps("sd", "sp", &.{2}) ++
            std.fmt.comptimePrint(
                \\    addi t0, sp, {[fs]d}
                \\    sd t0, 16(sp)
                \\    csrr t0, sepc
                \\    sd t0, 256(sp)
                \\    csrr t0, sstatus
                \\    sd t0, 264(sp)
                \\    mv a0, sp
                \\    call caravanKernelTrap
                \\    ld t0, 256(sp)
                \\    csrw sepc, t0
                \\    ld t0, 264(sp)
                \\    csrw sstatus, t0
                \\
            , .{ .fs = frame_size }) ++
            regOps("ld", "sp", &.{2}) ++
            std.fmt.comptimePrint(
                \\    addi sp, sp, {[fs]d}
                \\    sret
                \\
                \\.balign 4
                \\.global caravanResume
                \\caravanResume:
                \\    ld t0, {[pc]d}(a0)
                \\    csrw sepc, t0
                \\    li t0, 0x100
                \\    csrc sstatus, t0
                \\    li t0, 0x20
                \\    csrs sstatus, t0
                \\    csrw sscratch, a0
                \\
            , .{ .fs = frame_size, .pc = off_pc }) ++
            regOps("ld", "a0", &.{10}) ++
            \\    ld a0, 80(a0)
            \\    sret
            \\
    );
}

pub extern fn caravanTrapEntry() callconv(.c) void;
pub extern fn caravanResume(ctx: *Context) callconv(.c) noreturn;

pub const Interrupt = enum { software, timer, external };

pub const Cause = union(enum) {
    interrupt: Interrupt,
    syscall,
    fault: core.kernel.Fault,
    unknown_interrupt: u64,
};

const interrupt_bit: u64 = 1 << 63;

pub fn decode(scause: u64, stval: u64, pc: u64) Cause {
    if (scause & interrupt_bit != 0) return switch (scause & ~interrupt_bit) {
        1 => .{ .interrupt = .software },
        5 => .{ .interrupt = .timer },
        9 => .{ .interrupt = .external },
        else => .{ .unknown_interrupt = scause },
    };
    const kind: @import("abi").FaultKind = switch (scause) {
        8 => return .syscall,
        0, 4, 6 => .misaligned,
        1, 5, 7 => .access,
        2 => .illegal_instruction,
        3 => .breakpoint,
        12 => .fetch_page_fault,
        13 => .load_page_fault,
        15 => .store_page_fault,
        else => .unknown,
    };
    return .{ .fault = .{ .kind = kind, .addr = stval, .pc = pc, .raw = scause } };
}
