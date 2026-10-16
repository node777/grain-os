//! Supervisor Binary Interface calls into M-mode firmware (OpenSBI on QEMU and
//! most boards). Using SBI for console, timer and reset keeps early boot
//! independent of any particular board's devices.

pub const Error = error{ Failed, NotSupported, InvalidParam, Denied, InvalidAddress, AlreadyAvailable, Unknown };

const Ret = struct { err: isize, value: usize };

const ext_base: usize = 0x10;
const ext_time: usize = 0x54494D45; // "TIME"
const ext_srst: usize = 0x53525354; // "SRST"
const ext_dbcn: usize = 0x4442434E; // "DBCN"
const legacy_putchar: usize = 0x01;
const ext_hsm: usize = 0x48534D; // "HSM"
const ext_ipi: usize = 0x735049; // "sPI"
const ext_rfence: usize = 0x52464E43; // "RFNC"

inline fn ecall(ext: usize, fid: usize, a0: usize, a1: usize, a2: usize) Ret {
    return ecall4(ext, fid, a0, a1, a2, 0);
}

inline fn ecall4(ext: usize, fid: usize, a0: usize, a1: usize, a2: usize, a3: usize) Ret {
    var err: isize = undefined;
    var value: usize = undefined;
    asm volatile ("ecall"
        : [err] "={a0}" (err),
          [value] "={a1}" (value),
        : [a0] "{a0}" (a0),
          [a1] "{a1}" (a1),
          [a2] "{a2}" (a2),
          [a3] "{a3}" (a3),
          [fid] "{a6}" (fid),
          [ext] "{a7}" (ext),
        : .{ .memory = true });
    return .{ .err = err, .value = value };
}

fn check(r: Ret) Error!usize {
    return switch (r.err) {
        0 => r.value,
        -1 => error.Failed,
        -2 => error.NotSupported,
        -3 => error.InvalidParam,
        -4 => error.Denied,
        -5 => error.InvalidAddress,
        -6 => error.AlreadyAvailable,
        else => error.Unknown,
    };
}

pub fn probeExtension(ext: usize) bool {
    const v = check(ecall(ext_base, 3, ext, 0, 0)) catch return false;
    return v != 0;
}

var have_dbcn: ?bool = null;

pub fn consolePutByte(c: u8) void {
    const dbcn = have_dbcn orelse blk: {
        const p = probeExtension(ext_dbcn);
        have_dbcn = p;
        break :blk p;
    };
    if (dbcn) {
        _ = ecall(ext_dbcn, 2, c, 0, 0);
    } else {
        _ = ecall(legacy_putchar, 0, c, 0, 0);
    }
}

/// Program the next supervisor timer interrupt at absolute `time` value.
pub fn setTimer(deadline: u64) void {
    _ = ecall(ext_time, 0, deadline, 0, 0);
}

pub const ResetReason = enum(usize) { none = 0, system_failure = 1 };

pub fn shutdown(reason: ResetReason) noreturn {
    _ = ecall(ext_srst, 0, 0, @backingInt(reason), 0);
    while (true) asm volatile ("wfi");
}

/// Start a stopped hart at physical address `start` with a0 = hart id, a1 = arg.
pub fn hartStart(hart_id: usize, start: usize, arg: usize) Error!void {
    _ = try check(ecall(ext_hsm, 0, hart_id, start, arg));
}

/// Raise a supervisor software interrupt on one hart.
pub fn sendIpi(hart_id: usize) void {
    _ = ecall(ext_ipi, 0, 1, hart_id, 0);
}

/// Flush the whole TLB on every hart in `mask` (bit i = hart id base+i).
/// Returns after the remote harts have done it.
pub fn remoteSfence(mask: usize, base: usize) void {
    _ = ecall4(ext_rfence, 1, mask, base, 0, 0);
}
