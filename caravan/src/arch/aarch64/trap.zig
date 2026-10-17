//! Exception entry and exit (EL1, AArch64).
//!
//! While a user thread runs, SP_EL1 points at its saved `Context`, so an
//! exception from EL0 stores the registers straight into it, then switches
//! to the hart's kernel stack and calls `caravanUserTrap(ctx, kind)` (never
//! returns). An exception taken at EL1 (an interrupt while idling, or a
//! kernel fault) pushes a `Frame` on the current stack and calls
//! `caravanKernelTrap(frame, kind)`. `kind` is 0 for a synchronous
//! exception and 1 for an interrupt: the vector says which, no register does.
//!
//! `caravanResume(ctx)` loads a Context and drops to EL0.
const std = @import("std");
const core = @import("core");
const abi = @import("abi");

pub const Context = extern struct {
    /// x0..x30.
    x: [31]u64 = @splat(0),
    sp: u64 = 0,
    pc: u64 = 0,
    /// Only the condition flags survive a resume: a thread always runs at
    /// EL0 with interrupts on.
    spsr: u64 = 0,
    /// The thread pointer register (TPIDR_EL0).
    tls: u64 = 0,
    /// Set before resuming: where the kernel stack starts on the next trap.
    kernel_sp: u64 = 0,
    /// Set before resuming (unused here: TPIDR_EL1 holds the hart-local block).
    hart_local: u64 = 0,
    _pad: u64 = 0,

    pub fn init(pc: u64, sp: u64, a0: u64) Context {
        var c: Context = .{ .pc = pc, .sp = sp };
        c.x[0] = a0;
        return c;
    }

    pub fn get(c: *const Context, r: core.kernel.Reg) usize {
        return switch (r) {
            .pc => c.pc,
            .sp => c.sp,
            else => c.x[argIndex(r)],
        };
    }

    pub fn set(c: *Context, r: core.kernel.Reg, v: usize) void {
        switch (r) {
            .pc => c.pc = v,
            .sp => c.sp = v,
            else => c.x[argIndex(r)] = v,
        }
    }

    /// The ABI's a0..a7 are x0..x7.
    fn argIndex(r: core.kernel.Reg) usize {
        return @backingInt(r) - @backingInt(core.kernel.Reg.a0);
    }
};

/// Registers saved for an exception taken at EL1.
pub const Frame = extern struct {
    x: [31]u64,
    elr: u64,
    spsr: u64,
    _pad: u64,

    pub fn pc(f: *const Frame) u64 {
        return f.elr;
    }
};

const off_sp = @offsetOf(Context, "sp");
const off_pc = @offsetOf(Context, "pc");
const off_tls = @offsetOf(Context, "tls");
const off_ksp = @offsetOf(Context, "kernel_sp");
const frame_size = @sizeOf(Frame);

comptime {
    std.debug.assert(@sizeOf(Context) % 16 == 0);
    std.debug.assert(frame_size % 16 == 0);
    std.debug.assert(off_pc == off_sp + 8 and @offsetOf(Context, "spsr") == off_pc + 8);
    std.debug.assert(@offsetOf(Frame, "spsr") == @offsetOf(Frame, "elr") + 8);
}

/// Store or load x0..x29 in pairs at [base + 16 * i].
fn pairs(comptime op: []const u8, comptime base: []const u8, comptime from: usize) []const u8 {
    comptime var s: []const u8 = "";
    inline for (from..15) |i| s = s ++ std.fmt.comptimePrint("    {s} x{d}, x{d}, [{s}, #{d}]\n", .{ op, 2 * i, 2 * i + 1, base, 16 * i });
    return s;
}

fn userEntry(comptime label: []const u8, comptime kind: u8) []const u8 {
    return label ++ ":\n" ++ pairs("stp", "sp", 0) ++ std.fmt.comptimePrint(
        \\    mrs x0, sp_el0
        \\    stp x30, x0, [sp, #240]
        \\    mrs x0, elr_el1
        \\    mrs x1, spsr_el1
        \\    stp x0, x1, [sp, #{[pc]d}]
        \\    mrs x0, tpidr_el0
        \\    str x0, [sp, #{[tls]d}]
        \\    mov x0, sp
        \\    ldr x2, [x0, #{[ksp]d}]
        \\    mov sp, x2
        \\    mov x1, #{[kind]d}
        \\    bl caravanUserTrap
        \\    brk #0
        \\
    , .{ .pc = off_pc, .tls = off_tls, .ksp = off_ksp, .kind = kind });
}

fn kernelEntry(comptime label: []const u8, comptime kind: u8) []const u8 {
    return label ++ ":\n" ++ std.fmt.comptimePrint("    sub sp, sp, #{d}\n", .{frame_size}) ++ pairs("stp", "sp", 0) ++ std.fmt.comptimePrint(
        \\    mrs x0, elr_el1
        \\    mrs x1, spsr_el1
        \\    str x30, [sp, #240]
        \\    stp x0, x1, [sp, #248]
        \\    mov x0, sp
        \\    mov x1, #{[kind]d}
        \\    bl caravanKernelTrap
        \\    ldp x0, x1, [sp, #248]
        \\    msr elr_el1, x0
        \\    msr spsr_el1, x1
        \\    ldr x30, [sp, #240]
        \\
    , .{ .kind = kind }) ++ pairs("ldp", "sp", 0) ++ std.fmt.comptimePrint(
        \\    add sp, sp, #{d}
        \\    eret
        \\
    , .{frame_size});
}

/// One 128-byte vector slot that branches to `target`.
fn slot(comptime target: []const u8) []const u8 {
    return "    .balign 128\n    b " ++ target ++ "\n";
}

comptime {
    asm ("    .section .text\n" ++
            "    .balign 2048\n" ++
            "    .global caravanVectors\n" ++
            "caravanVectors:\n" ++
            // Current EL with SP_EL0: never used.
            slot(".Lhang") ++ slot(".Lhang") ++ slot(".Lhang") ++ slot(".Lhang") ++
            // Current EL with SP_EL1: the kernel.
            slot(".Lkernel_sync") ++ slot(".Lkernel_irq") ++ slot(".Lhang") ++ slot(".Lhang") ++
            // Lower EL, AArch64: user threads.
            slot(".Luser_sync") ++ slot(".Luser_irq") ++ slot(".Lhang") ++ slot(".Lhang") ++
            // Lower EL, AArch32: not supported.
            slot(".Lhang") ++ slot(".Lhang") ++ slot(".Lhang") ++ slot(".Lhang") ++
            "    .balign 128\n" ++
            ".Lhang:\n    wfe\n    b .Lhang\n" ++
            userEntry(".Luser_sync", 0) ++
            userEntry(".Luser_irq", 1) ++
            kernelEntry(".Lkernel_sync", 0) ++
            kernelEntry(".Lkernel_irq", 1) ++
            std.fmt.comptimePrint(
                \\    .balign 4
                \\    .global caravanResume
                \\caravanResume:
                \\    mov sp, x0
                \\    ldp x1, x2, [x0, #{[sp]d}]
                \\    msr sp_el0, x1
                \\    msr elr_el1, x2
                \\    ldr x1, [x0, #{[spsr]d}]
                \\    and x1, x1, #0xf0000000
                \\    msr spsr_el1, x1
                \\    ldr x1, [x0, #{[tls]d}]
                \\    msr tpidr_el0, x1
                \\    ldr x30, [sp, #240]
                \\
            , .{ .sp = off_sp, .spsr = off_pc + 8, .tls = off_tls }) ++
            pairs("ldp", "sp", 1) ++
            \\    ldp x0, x1, [sp, #0]
            \\    eret
            \\
    );
}

pub extern const caravanVectors: u8;
pub extern fn caravanResume(ctx: *Context) callconv(.c) noreturn;

pub const Cause = union(enum) {
    /// Interrupts are read from the GIC; nothing to carry.
    interrupt: u64,
    syscall,
    fault: core.kernel.Fault,
};

/// Decode a synchronous exception from ESR_EL1 and FAR_EL1.
pub fn decode(esr: u64, far: u64, pc: u64) Cause {
    const ec = (esr >> 26) & 0x3f;
    const fsc = esr & 0x3f;
    const kind: abi.FaultKind = switch (ec) {
        0x15 => return .syscall, // SVC from AArch64
        0x24, 0x25 => if (isPageFault(fsc))
            (if (esr & (1 << 6) != 0) .store_page_fault else .load_page_fault)
        else if (fsc == 0x21) .misaligned else .access,
        0x20, 0x21 => if (isPageFault(fsc)) .fetch_page_fault else .access,
        0x22, 0x26 => .misaligned, // PC or SP alignment
        0x00, 0x07, 0x0e => .illegal_instruction, // unknown, FP/SIMD (off), illegal state
        0x3c => .breakpoint, // BRK
        else => .unknown,
    };
    return .{ .fault = .{ .kind = kind, .addr = far, .pc = pc, .raw = esr } };
}

/// Translation, access-flag and permission faults, at any level.
fn isPageFault(fsc: u64) bool {
    return fsc >= 0x04 and fsc <= 0x0f;
}
