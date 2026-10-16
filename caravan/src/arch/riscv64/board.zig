//! Board power control. On QEMU virt the SiFive test finisher sets QEMU's own
//! exit status, so a harness sees pass or fail without parsing output. SBI
//! reset can't carry that: OpenSBI reports every shutdown reason as success.
const sbi = @import("sbi.zig");

/// Virtual address of the test finisher, if the device tree has one.
pub var finisher: ?usize = null;

pub fn exit(code: u16) noreturn {
    if (finisher) |addr| {
        const f: *volatile u32 = @ptrFromInt(addr);
        f.* = if (code == 0) 0x5555 else (@as(u32, code) << 16) | 0x3333;
    }
    sbi.shutdown(if (code == 0) .none else .system_failure);
}
