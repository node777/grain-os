//! The portable kernel core: logic that must not depend on any architecture.
//! It is compiled as its own module, so it cannot import arch/ code.
pub const klog = @import("klog.zig");
pub const fdt = @import("fdt.zig");
pub const elf = @import("elf.zig");
pub const kernel = @import("kernel.zig");
pub const Kernel = kernel.Kernel;

test {
    @import("std").testing.refAllDecls(@This());
}
