//! The aarch64 implementation of the kernel core's arch interface (see
//! core/kernel.zig) and of main.zig's glue, plus the per-core state they
//! need. Runs at EL1 on QEMU virt: a GICv2, the virtual timer, PSCI to
//! start cores and power off, a PL011 for the kernel's records.
const std = @import("std");
const core = @import("core");
const sys = @import("sysreg.zig");
const gic = @import("gic.zig");
const psci = @import("psci.zig");
const trap = @import("trap.zig");
pub const boot = @import("boot.zig");

pub const Paging = @import("vmsa");
pub const Context = trap.Context;
pub const Frame = trap.Frame;
pub const Cause = trap.Cause;
pub const elf_machine: u16 = core.elf.machine_aarch64;
pub const max_harts = core.kernel.max_harts;
pub const name = .aarch64;
pub const kernel_offset = boot.kernel_offset;

/// Per-core state. In the kernel, TPIDR_EL1 points at the running core's entry.
pub const HartLocal = struct {
    index: u32 = 0,
    /// MPIDR affinity (the device tree's `reg` for the core).
    hart_id: u32 = 0,
    online: bool = false,
    stack_top: usize = 0,
    /// Root table currently in TTBR0 (physical).
    active_root: std.atomic.Value(u64) = .init(0),
    /// Bumped on every trap from user mode, before taking the kernel lock.
    epoch: std.atomic.Value(u64) = .init(0),
    /// True from just before resuming a thread until its next trap.
    in_user: std.atomic.Value(bool) = .init(false),
    /// Another core asks this one to leave a root table that is being destroyed.
    leave_root: std.atomic.Value(u64) = .init(0),
};

pub var harts: [max_harts]HartLocal = @splat(.{});
pub var hart_count: u32 = 1;

var uart: usize = 0;

pub inline fn relax() void {
    asm volatile ("yield");
}

pub fn self() *HartLocal {
    return @ptrFromInt(sys.read("tpidr_el1"));
}

/// The TTBR0 table while no thread runs: empty.
pub fn bootRootPhys() u64 {
    return @intFromPtr(&boot.empty_root) - boot.kernel_offset;
}

pub fn physToVirt(pa: u64) usize {
    return pa + boot.physmap_base;
}

/// User root tables hold user mappings only: the kernel lives in TTBR1.
pub fn initRootTable(ptes: *[Paging.entries]u64) void {
    _ = ptes;
}

/// Every core forgets translations through `root`: TLB maintenance is
/// broadcast in hardware, so no IPIs.
pub fn flushTlb(root: u64) void {
    _ = root;
    sys.flushTlbAll();
}

/// Switch away from a root table that is about to be destroyed, on every
/// core, and wait until no core uses it.
pub fn retireRoot(pa: u64) void {
    const me = self();
    if (me.active_root.load(.acquire) == pa) switchRoot(me, bootRootPhys());
    for (harts[0..hart_count]) |*h| {
        if (h == me or !h.online or h.active_root.load(.acquire) != pa) continue;
        h.leave_root.store(pa, .release);
        sendIpi(h);
        while (h.active_root.load(.acquire) == pa) relax();
    }
    sys.flushTlbAll();
}

pub fn switchRoot(h: *HartLocal, pa: u64) void {
    sys.write("ttbr0_el1", pa);
    sys.isb();
    sys.flushTlbLocal();
    h.active_root.store(pa, .release);
}

pub fn serviceRequests(h: *HartLocal) void {
    const pa = h.leave_root.load(.acquire);
    if (pa != 0) {
        if (h.active_root.load(.acquire) == pa) switchRoot(h, bootRootPhys());
        h.leave_root.store(0, .release);
    }
}

pub fn setTimer(hart: u32, deadline: u64) void {
    std.debug.assert(hart == self().index);
    sys.write("cntv_cval_el0", deadline);
    sys.write("cntv_ctl_el0", 1);
}

pub fn irqMask(line: u32) void {
    gic.enable(line, false);
}

pub fn irqUnmask(line: u32) void {
    gic.enable(line, true);
}

pub fn debugWrite(bytes: []const u8) void {
    if (uart == 0) return;
    const dr: *volatile u32 = @ptrFromInt(uart);
    const fr: *volatile u32 = @ptrFromInt(uart + 0x18);
    for (bytes) |c| {
        while (fr.* & (1 << 5) != 0) {} // transmit FIFO full
        dr.* = c;
    }
}

// ---------------------------------------------------------------------------
// Glue for main.zig (see the list at its top).

extern const __stacks_start: u8;
extern fn _start_secondary() callconv(.naked) void;

pub fn stackTop(index: usize) usize {
    return @intFromPtr(&__stacks_start) + (index + 1) * boot.stack_size;
}

pub fn now() u64 {
    return sys.counter();
}

/// Instructions retired (PMU event counter 0, counting INST_RETIRED).
pub fn instret() u64 {
    return sys.read("pmevcntr0_el0");
}

pub fn setupHart(h: *HartLocal) void {
    sys.write("tpidr_el1", @intFromPtr(h));
    sys.write("vbar_el1", @intFromPtr(&trap.caravanVectors));
    sys.isb();
    // User code may read the virtual counter, and the cycle and
    // instruction counters (as rdcycle and rdinstret on RISC-V).
    sys.write("cntkctl_el1", 0b10);
    sys.write("pmevtyper0_el0", 0x08); // INST_RETIRED, at every level
    sys.write("pmcntenset_el0", (1 << 31) | 1);
    sys.write("pmcr_el0", 0b111); // enable, reset both kinds of counter
    sys.write("pmuserenr_el0", 0b1101);
    sys.write("cntv_ctl_el0", 0);
    gic.initCpu();
    switchRoot(h, bootRootPhys());
}

/// The core table (boot core first, then device-tree order), the GIC, PSCI,
/// the UART, and the timer's frequency (from the counter, not the tree).
pub fn initPlatform(p: *core.fdt.Platform, boot_hart_id: u32) error{ BootHartMissing, NoGic, NoPsci }!void {
    if (p.uart) |u| if (p.uart_pl011) {
        uart = physToVirt(u.base);
    };
    const list = p.hartList();
    const boot_index = p.hartIndex(boot_hart_id) orelse return error.BootHartMissing;
    var n: usize = 0;
    for (0..list.len) |k| {
        const di = if (k == 0) boot_index else if (k <= boot_index) k - 1 else k;
        if (n == max_harts) break;
        const h = &harts[n];
        h.index = @intCast(n);
        h.hart_id = list[di].id;
        h.stack_top = stackTop(n);
        n += 1;
    }
    hart_count = @intCast(n);
    const dist = p.gic_dist orelse return error.NoGic;
    const cpu = p.gic_cpu orelse return error.NoGic;
    gic.init(physToVirt(dist.base), physToVirt(cpu.base), boot_hart_id);
    p.irq_first = 32;
    p.irq_end = gic.lines;
    if (!p.psci) return error.NoPsci;
    psci.use_smc = p.psci_smc;
    if (p.timebase_hz == 0) p.timebase_hz = sys.read("cntfrq_el0");
}

pub fn platformRecord(p: *const core.fdt.Platform) struct { gic: core.klog.Hex(u64), gic_lines: u32, uart: core.klog.Hex(u64), uart_irq: u32, psci: []const u8 } {
    return .{
        .gic = core.klog.hex(if (p.gic_dist) |g| g.base else 0),
        .gic_lines = gic.lines,
        .uart = core.klog.hex(if (p.uart) |u| u.base else 0),
        .uart_irq = p.uart_irq orelse 0,
        .psci = if (p.psci_smc) "smc" else "hvc",
    };
}

pub fn startHart(h: *HartLocal) psci.Error!void {
    try psci.cpuOn(h.hart_id, @intFromPtr(&_start_secondary) - boot.kernel_offset, h.index);
}

/// GICv2 targets CPU interfaces; on QEMU virt (and single-cluster parts)
/// a core's interface number is its affinity 0.
pub fn sendIpi(h: *HartLocal) void {
    gic.sendSgi(h.hart_id & 0xff);
}

pub fn trapCause(kind: usize, pc: u64) Cause {
    if (kind == 1) return .{ .interrupt = 0 };
    return trap.decode(sys.read("esr_el1"), sys.read("far_el1"), pc);
}

pub const stale_trap: u64 = 0;

/// ELR already points past the SVC.
pub fn skipSyscall(ctx: *Context) void {
    _ = ctx;
}

pub fn interruptEvent(h: *HartLocal, raw: u64, claimed: *?u32) core.kernel.Event {
    _ = h;
    _ = raw;
    const iar = gic.acknowledge();
    const id = iar & 0x3ff;
    if (id == gic.spurious) return .ipi;
    if (id < 16) {
        gic.end(iar);
        return .ipi;
    }
    if (id == gic.timer_ppi) {
        // The timer's line stays raised until the deadline moves: park it
        // until the core sets the next one.
        sys.write("cntv_ctl_el0", 0b10);
        gic.end(iar);
        return .timer;
    }
    claimed.* = id;
    return .{ .irq = id };
}

pub fn completeIrq(h: *HartLocal, line: u32) void {
    _ = h;
    gic.end(line);
}

pub fn kernelFaultRecord(frame: *const Frame) struct { esr: core.klog.Hex(u64), far: core.klog.Hex(u64), pc: core.klog.Hex(u64), lr: core.klog.Hex(u64) } {
    return .{ .esr = core.klog.hex(sys.read("esr_el1")), .far = core.klog.hex(sys.read("far_el1")), .pc = core.klog.hex(frame.elr), .lr = core.klog.hex(frame.x[30]) };
}

pub fn resumeThread(ctx: *Context) noreturn {
    trap.caravanResume(ctx);
}

pub fn idle(h: *HartLocal) noreturn {
    // Reset to the top of this core's stack: whatever was below is finished.
    asm volatile (
        \\mov sp, %[top]
        \\msr daifclr, #2
        \\1: wfi
        \\b 1b
        :
        : [top] "r" (h.stack_top),
    );
    unreachable;
}

/// PSCI has no exit status: the records say how the run went.
pub fn exit(code: u16) noreturn {
    _ = code;
    psci.systemOff();
}
