//! The portable kernel core: logic that must not depend on any architecture.
//! It is compiled as its own module, so it cannot import arch/ code.
pub const klog = @import("klog.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
