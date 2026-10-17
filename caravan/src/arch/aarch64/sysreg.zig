//! AArch64 system registers and barriers.

pub inline fn read(comptime name: []const u8) u64 {
    return asm volatile ("mrs %[r], " ++ name
        : [r] "=r" (-> u64),
    );
}

pub inline fn write(comptime name: []const u8, value: u64) void {
    asm volatile ("msr " ++ name ++ ", %[v]"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

pub inline fn isb() void {
    asm volatile ("isb" ::: .{ .memory = true });
}

/// The virtual counter: the platform timer (CNTFRQ_EL0 ticks per second).
pub inline fn counter() u64 {
    isb();
    return read("cntvct_el0");
}

/// Translations through TTBR0 changed or were left: forget them on every
/// core of the inner shareable domain (the hardware broadcasts this), and
/// the instruction caches with them, since a new mapping may hold code.
pub inline fn flushTlbAll() void {
    asm volatile (
        \\dsb ishst
        \\tlbi vmalle1is
        \\ic ialluis
        \\dsb ish
        \\isb
        ::: .{ .memory = true });
}

/// The same, on this core only (after switching TTBR0).
pub inline fn flushTlbLocal() void {
    asm volatile (
        \\dsb nshst
        \\tlbi vmalle1
        \\dsb nsh
        \\isb
        ::: .{ .memory = true });
}
