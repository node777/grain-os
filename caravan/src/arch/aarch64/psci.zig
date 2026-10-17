//! Arm Power State Coordination Interface: firmware calls to start cores
//! and power off, through `hvc` or `smc` as the device tree says.
pub var use_smc = false;

const cpu_on: u64 = 0xc400_0003;
const system_off: u64 = 0x8400_0008;

fn call(fid: u64, a1: u64, a2: u64, a3: u64) i64 {
    var r: u64 = fid;
    if (use_smc) {
        asm volatile (".inst 0xd4000003 // smc #0"
            : [r] "={x0}" (r),
            : [f] "{x0}" (r),
              [a] "{x1}" (a1),
              [b] "{x2}" (a2),
              [c] "{x3}" (a3),
            : .{ .memory = true });
    } else {
        asm volatile (".inst 0xd4000002 // hvc #0"
            : [r] "={x0}" (r),
            : [f] "{x0}" (r),
              [a] "{x1}" (a1),
              [b] "{x2}" (a2),
              [c] "{x3}" (a3),
            : .{ .memory = true });
    }
    return @bitCast(r);
}

pub const Error = error{PsciFailed};

/// Start the core `mpidr` at physical address `entry` with x0 = `context`.
pub fn cpuOn(mpidr: u64, entry: u64, context: u64) Error!void {
    if (call(cpu_on, mpidr, entry, context) != 0) return error.PsciFailed;
}

pub fn systemOff() noreturn {
    _ = call(system_off, 0, 0, 0);
    while (true) asm volatile ("wfi");
}
