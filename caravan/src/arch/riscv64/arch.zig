//! The riscv64 implementation of the kernel core's arch interface (see
//! core/kernel.zig), plus the per-hart state that interface needs.
const std = @import("std");
const core = @import("core");
const csr = @import("csr.zig");
const sbi = @import("sbi.zig");
const plic = @import("plic.zig");
const trap = @import("trap.zig");
const board = @import("board.zig");
pub const boot = @import("boot.zig");

pub const Paging = @import("sv39");
pub const Context = trap.Context;
pub const Frame = trap.Frame;
pub const Cause = trap.Cause;
pub const elf_machine: u16 = core.elf.machine_riscv;
pub const max_harts = core.kernel.max_harts;
pub const name = .riscv64;
pub const kernel_offset = boot.kernel_offset;

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

// ---------------------------------------------------------------------------
// Glue for main.zig (see the list at its top).

extern const __stacks_start: u8;
extern fn _start_secondary() callconv(.naked) void;

pub fn stackTop(index: usize) usize {
    return @intFromPtr(&__stacks_start) + (index + 1) * boot.stack_size;
}

pub fn now() u64 {
    return csr.time();
}

pub inline fn instret() u64 {
    return asm volatile ("rdinstret %[r]"
        : [r] "=r" (-> u64),
    );
}

pub fn setupHart(h: *HartLocal) void {
    asm volatile ("mv tp, %[hl]"
        :
        : [hl] "r" (@intFromPtr(h)),
    );
    csr.write("stvec", @intFromPtr(&trap.caravanTrapEntry));
    csr.write("sscratch", 0);
    // Let user code read cycle, time and instret.
    csr.write("scounteren", 0b111);
    csr.set("sie", csr.sie_stie | csr.sie_ssie | csr.sie_seie);
    if (h.plic_context) |ctx| plic.setThreshold(ctx, 0);
    h.active_root.store(bootRootPhys(), .release);
}

/// The hart table (boot hart first, then device-tree order, each with its
/// PLIC context) and the PLIC.
pub fn initPlatform(p: *const core.fdt.Platform, boot_hart_id: u32) error{BootHartMissing}!void {
    if (p.test_finisher) |f| board.finisher = physToVirt(f);
    const list = p.hartList();
    const boot_index = p.hartIndex(boot_hart_id) orelse return error.BootHartMissing;
    var n: usize = 0;
    for (0..list.len) |k| {
        // k = 0 places the boot hart; after that, device-tree order without it.
        const di = if (k == 0) boot_index else if (k <= boot_index) k - 1 else k;
        if (n == max_harts) break;
        const h = &harts[n];
        h.index = @intCast(n);
        h.hart_id = list[di].id;
        h.plic_context = list[di].plic_context;
        h.stack_top = stackTop(n);
        n += 1;
    }
    hart_count = @intCast(n);
    if (p.plic) |pl| plic.init(physToVirt(pl.base), p.plic_ndev);
}

pub fn platformRecord(p: *const core.fdt.Platform) struct { plic: core.klog.Hex(u64), plic_lines: u32, plic_context: u32, uart: core.klog.Hex(u64), uart_irq: u32, finisher: core.klog.Hex(u64) } {
    return .{
        .plic = core.klog.hex(if (p.plic) |pl| pl.base else 0),
        .plic_lines = p.plic_ndev,
        .plic_context = if (harts[0].plic_context) |c| c else 0xffff,
        .uart = core.klog.hex(if (p.uart) |u| u.base else 0),
        .uart_irq = p.uart_irq orelse 0,
        .finisher = core.klog.hex(p.test_finisher orelse 0),
    };
}

pub fn startHart(h: *HartLocal) sbi.Error!void {
    try sbi.hartStart(h.hart_id, @intFromPtr(&_start_secondary) - boot.kernel_offset, h.index);
}

pub fn sendIpi(h: *HartLocal) void {
    sbi.sendIpi(h.hart_id);
}

pub fn trapCause(kind: usize, pc: u64) Cause {
    _ = kind; // scause says everything
    return trap.decode(csr.read("scause"), csr.read("stval"), pc);
}

/// A trap whose thread is gone: treat it as an IPI (reschedule).
pub const stale_trap: u64 = trap.interrupt_bit | 1;

pub fn skipSyscall(ctx: *Context) void {
    ctx.pc += 4;
}

pub fn interruptEvent(h: *HartLocal, raw: u64, claimed: *?u32) core.kernel.Event {
    return switch (raw & ~trap.interrupt_bit) {
        5 => .timer,
        1 => blk: {
            csr.clear("sip", csr.sip_ssip);
            break :blk .ipi;
        },
        9 => blk: {
            const ctx = h.plic_context orelse break :blk .ipi;
            const line = plic.claim(ctx);
            if (line == 0) break :blk .ipi;
            claimed.* = line;
            break :blk .{ .irq = line };
        },
        else => .ipi,
    };
}

pub fn completeIrq(h: *HartLocal, line: u32) void {
    plic.complete(h.plic_context.?, line);
}

pub fn kernelFaultRecord(frame: *const Frame) struct { scause: usize, stval: core.klog.Hex(u64), pc: core.klog.Hex(u64), ra: core.klog.Hex(u64) } {
    return .{ .scause = csr.read("scause"), .stval = core.klog.hex(@as(u64, csr.read("stval"))), .pc = core.klog.hex(frame.sepc), .ra = core.klog.hex(frame.x[1]) };
}

pub fn resumeThread(ctx: *Context) noreturn {
    trap.caravanResume(ctx);
}

pub fn idle(h: *HartLocal) noreturn {
    // Reset to the top of this hart's stack: whatever was below is finished.
    asm volatile (
        \\mv sp, %[top]
        \\csrsi sstatus, 2
        \\1: wfi
        \\j 1b
        :
        : [top] "r" (h.stack_top),
    );
    unreachable;
}

pub fn exit(code: u16) noreturn {
    board.exit(code);
}
