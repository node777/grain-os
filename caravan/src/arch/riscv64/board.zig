//! Board-specific facts that are not yet discovered from the device tree.
const std = @import("std");
const options = @import("build_options");
const sbi = @import("sbi.zig");

pub const Board = enum { qemu_virt, generic_sbi };
pub const board: Board = @fromBackingInt(@intCast(@backingInt(options.board)));

/// Power off. On QEMU virt the SiFive test finisher sets QEMU's own exit
/// status, so a harness sees pass or fail without parsing output. SBI reset
/// can't carry that: OpenSBI reports every shutdown reason as success.
pub fn exit(code: u16) noreturn {
    switch (board) {
        .qemu_virt => {
            const finisher: *volatile u32 = @ptrFromInt(0x0010_0000);
            finisher.* = if (code == 0) 0x5555 else (@as(u32, code) << 16) | 0x3333;
        },
        .generic_sbi => {},
    }
    sbi.shutdown(if (code == 0) .none else .system_failure);
}

comptime {
    std.debug.assert(std.meta.fieldNames(Board).len == std.meta.fieldNames(@TypeOf(options.board)).len);
}
