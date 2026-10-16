//! The riscv64 implementation of the kernel core's arch interface (see
//! core/kernel.zig), plus the per-hart state that interface needs.
const std = @import("std");
const core = @import("core");
const csr = @import("csr.zig");
const sbi = @import("sbi.zig");
const plic = @import("plic.zig");
const boot = @import("boot.zig");
const trap = @import("trap.zig");

pub const Paging = @import("sv39");
pub const Context = trap.Context;
pub const elf_machine: u16 = core.elf.machine_riscv;
pub const max_harts = core.kernel.max_harts;

/// Per-hart state. In the kernel, `tp` points at the running hart's entry.
pub const HartLocal = struct {
    index: u32 = 0,
    hart_id: u32 = 0,
    online: bool = false,
    stack_top: usize = 0,
    plic_context: ?u32 = null,
    /// Root table currently in satp (physical).
    active_root: std.atomic.Value(u64) = .init(0),
    /// Bumped on every trap from user mode, before taking the kernel lock.
    epoch: std.atomic.Value(u64) = .init(0),
    /// True from just before resuming a thread until its next trap.
    in_user: std.atomic.Value(bool) = .init(false),
    /// Another hart asks this one to leave a root table that is being destroyed.
    leave_root: std.atomic.Value(u64) = .init(0),
};

pub var harts: [max_harts]HartLocal = @splat(.{});
pub var hart_count: u32 = 1;

/// Spin-wait hint (Zihintpause `pause`). Encoded as a FENCE hint, so it is a
/// no-op on cores without the extension; emulators use it to run another
/// vCPU, which matters when the lock holder is descheduled.
pub inline fn relax() void {
    asm volatile (".4byte 0x0100000f");
}

pub fn self() *HartLocal {
    const tp = asm volatile ("mv %[r], tp"
        : [r] "=r" (-> usize),
    );
    return @ptrFromInt(tp);
}

pub fn bootRootPhys() u64 {
    return @intFromPtr(&boot.boot_root) - boot.kernel_offset;
}

pub fn physToVirt(pa: u64) usize {
    return pa + boot.physmap_base;
}

pub fn initRootTable(ptes: *[Paging.entries]u64) void {
    @memcpy(ptes[Paging.user_root_entries..], boot.boot_root[Paging.user_root_entries..]);
}

/// Flush the TLB of every hart translating through root table `root`,
/// synchronously. A hart on another root has nothing cached for it: `setRoot`
/// flushes, and roots only change under the kernel lock, which the caller
/// holds.
pub fn flushTlb(root: u64) void {
    csr.sfenceAll();
    var mask: usize = 0;
    const me = self();
    for (harts[0..hart_count]) |*h| {
        if (h.online and h.index != me.index and h.hart_id < 64 and h.active_root.load(.acquire) == root) mask |= @as(usize, 1) << @intCast(h.hart_id);
    }
    if (mask != 0) sbi.remoteSfence(mask, 0);
}

/// Switch away from a root table that is about to be destroyed, on every
/// hart, and wait until no hart uses it.
pub fn retireRoot(pa: u64) void {
    const boot_pa = bootRootPhys();
    const me = self();
    if (me.active_root.load(.acquire) == pa) switchRoot(me, boot_pa);
    for (harts[0..hart_count]) |*h| {
        if (h == me or !h.online or h.active_root.load(.acquire) != pa) continue;
        h.leave_root.store(pa, .release);
        sbi.sendIpi(h.hart_id);
        while (h.active_root.load(.acquire) == pa) relax();
    }
}

pub fn switchRoot(h: *HartLocal, pa: u64) void {
    csr.setRoot(pa);
    h.active_root.store(pa, .release);
}

/// Honour a pending `retireRoot` request from another hart. Safe without
/// the kernel lock; called on trap entry and while waiting for the lock.
pub fn serviceRequests(h: *HartLocal) void {
    const pa = h.leave_root.load(.acquire);
    if (pa != 0) {
        if (h.active_root.load(.acquire) == pa) switchRoot(h, bootRootPhys());
        h.leave_root.store(0, .release);
    }
}

pub fn setTimer(hart: u32, deadline: u64) void {
    std.debug.assert(hart == self().index);
    sbi.setTimer(deadline);
}

/// External interrupts are routed to the boot hart.
pub fn irqMask(line: u32) void {
    if (harts[0].plic_context) |ctx| plic.enable(ctx, line, false);
}

pub fn irqUnmask(line: u32) void {
    if (harts[0].plic_context) |ctx| plic.enable(ctx, line, true);
}

pub fn debugWrite(bytes: []const u8) void {
    for (bytes) |c| sbi.consolePutByte(c);
}
