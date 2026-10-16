//! Supervisor-mode control and status registers.

pub inline fn read(comptime name: []const u8) usize {
    return asm volatile ("csrr %[r], " ++ name
        : [r] "=r" (-> usize),
    );
}

pub inline fn write(comptime name: []const u8, value: usize) void {
    asm volatile ("csrw " ++ name ++ ", %[v]"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

pub inline fn set(comptime name: []const u8, mask: usize) void {
    asm volatile ("csrs " ++ name ++ ", %[m]"
        :
        : [m] "r" (mask),
        : .{ .memory = true });
}

pub inline fn clear(comptime name: []const u8, mask: usize) void {
    asm volatile ("csrc " ++ name ++ ", %[m]"
        :
        : [m] "r" (mask),
        : .{ .memory = true });
}

pub const sstatus_sie: usize = 1 << 1;
pub const sie_stie: usize = 1 << 5;
pub const sip_stip: usize = 1 << 5;

/// Free-running platform timer (the `time` CSR, read via rdtime).
pub inline fn time() u64 {
    return asm volatile ("rdtime %[r]"
        : [r] "=r" (-> u64),
    );
}

pub inline fn wfi() void {
    asm volatile ("wfi");
}

pub const sie_ssie: usize = 1 << 1;
pub const sie_seie: usize = 1 << 9;
pub const sip_ssip: usize = 1 << 1;

/// Switch to the Sv39 root table at physical address `root` and flush.
pub inline fn setRoot(root: u64) void {
    write("satp", (8 << 60) | (root >> 12));
    sfenceAll();
}

pub inline fn sfenceAll() void {
    asm volatile ("sfence.vma" ::: .{ .memory = true });
}
