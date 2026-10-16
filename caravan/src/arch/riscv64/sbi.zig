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

inline fn ecall(ext: usize, fid: usize, a0: usize, a1: usize, a2: usize) Ret {
    var err: isize = undefined;
    var value: usize = undefined;
    asm volatile ("ecall"
        : [err] "={a0}" (err),
          [value] "={a1}" (value),
        : [a0] "{a0}" (a0),
          [a1] "{a1}" (a1),
          [a2] "{a2}" (a2),
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
