//! The few instructions user space needs that differ between
//! architectures: the system call, the counters, a memory fence, a trap,
//! and the entry stub. The system-call registers are the ABI's a0..a7:
//! RISC-V's a0..a7, AArch64's x0..x7.
const builtin = @import("builtin");

pub const Words = [8]usize;

const riscv = builtin.cpu.arch == .riscv64;

/// Enter the kernel with `in` in a0..a7; returns a0..a7.
pub inline fn syscall(in: Words) Words {
    var r0: usize = undefined;
    var r1: usize = undefined;
    var r2: usize = undefined;
    var r3: usize = undefined;
    var r4: usize = undefined;
    var r5: usize = undefined;
    var r6: usize = undefined;
    var r7: usize = undefined;
    if (riscv) {
        asm volatile ("ecall"
            : [r0] "={a0}" (r0),
              [r1] "={a1}" (r1),
              [r2] "={a2}" (r2),
              [r3] "={a3}" (r3),
              [r4] "={a4}" (r4),
              [r5] "={a5}" (r5),
              [r6] "={a6}" (r6),
              [r7] "={a7}" (r7),
            : [a0] "{a0}" (in[0]),
              [a1] "{a1}" (in[1]),
              [a2] "{a2}" (in[2]),
              [a3] "{a3}" (in[3]),
              [a4] "{a4}" (in[4]),
              [a5] "{a5}" (in[5]),
              [a6] "{a6}" (in[6]),
              [a7] "{a7}" (in[7]),
            : .{ .memory = true });
    } else {
        asm volatile ("svc #0"
            : [r0] "={x0}" (r0),
              [r1] "={x1}" (r1),
              [r2] "={x2}" (r2),
              [r3] "={x3}" (r3),
              [r4] "={x4}" (r4),
              [r5] "={x5}" (r5),
              [r6] "={x6}" (r6),
              [r7] "={x7}" (r7),
            : [a0] "{x0}" (in[0]),
              [a1] "{x1}" (in[1]),
              [a2] "{x2}" (in[2]),
              [a3] "{x3}" (in[3]),
              [a4] "{x4}" (in[4]),
              [a5] "{x5}" (in[5]),
              [a6] "{x6}" (in[6]),
              [a7] "{x7}" (in[7]),
            : .{ .memory = true });
    }
    return .{ r0, r1, r2, r3, r4, r5, r6, r7 };
}

/// The platform timer (BootInfo.timebase_hz ticks per second).
pub inline fn time() u64 {
    if (riscv) return asm volatile ("rdtime %[r]"
        : [r] "=r" (-> u64),
    );
    return asm volatile ("isb\nmrs %[r], cntvct_el0"
        : [r] "=r" (-> u64),
    );
}

pub inline fn cycles() u64 {
    if (riscv) return asm volatile ("rdcycle %[r]"
        : [r] "=r" (-> u64),
    );
    return asm volatile ("mrs %[r], pmccntr_el0"
        : [r] "=r" (-> u64),
    );
}

pub inline fn instret() u64 {
    if (riscv) return asm volatile ("rdinstret %[r]"
        : [r] "=r" (-> u64),
    );
    return asm volatile ("mrs %[r], pmevcntr0_el0"
        : [r] "=r" (-> u64),
    );
}

/// Order all earlier memory accesses (device memory included) before later ones.
pub inline fn fence() void {
    if (riscv) asm volatile ("fence rw, rw" ::: .{ .memory = true }) else asm volatile ("dmb sy" ::: .{ .memory = true });
}

/// An instruction that always faults.
pub inline fn trap() void {
    if (riscv) asm volatile ("unimp") else asm volatile ("udf #0");
}

/// The body of a naked entry point: call `target` (which never returns).
pub fn callStub(comptime target: []const u8) []const u8 {
    return if (riscv) " call " ++ target ++ "\n unimp" else " bl " ++ target ++ "\n udf #0";
}

/// `j .` / `b .`: one instruction that loops forever (for tests).
pub const spin_instruction: u32 = if (riscv) 0x0000006f else 0x1400_0000;
