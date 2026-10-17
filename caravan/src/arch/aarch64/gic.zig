//! Arm Generic Interrupt Controller, version 2. The kernel owns it: user
//! space sees shared peripheral interrupts (32 and up) only as Irq
//! capabilities. Software-generated interrupts 0..15 are IPIs; per-CPU
//! interrupt 27 is the virtual timer.
var dist: usize = 0;
var cpu: usize = 0;
/// One past the highest interrupt ID the distributor implements.
pub var lines: u32 = 0;

pub const sgi_reschedule: u32 = 0;
pub const timer_ppi: u32 = 27;
pub const spurious: u32 = 1023;

const GICD_CTLR = 0x000;
const GICD_TYPER = 0x004;
const GICD_ISENABLER = 0x100;
const GICD_ICENABLER = 0x180;
const GICD_IPRIORITYR = 0x400;
const GICD_ITARGETSR = 0x800;
const GICD_SGIR = 0xf00;

const GICC_CTLR = 0x00;
const GICC_PMR = 0x04;
const GICC_BPR = 0x08;
const GICC_IAR = 0x0c;
const GICC_EOIR = 0x10;

fn d32(off: usize) *volatile u32 {
    return @ptrFromInt(dist + off);
}
fn c32(off: usize) *volatile u32 {
    return @ptrFromInt(cpu + off);
}

/// Distributor: every shared interrupt off, mid priority, delivered to
/// `target` (a CPU interface number: the boot core).
pub fn init(dist_va: usize, cpu_va: usize, target: u32) void {
    dist = dist_va;
    cpu = cpu_va;
    d32(GICD_CTLR).* = 0;
    lines = @min(((d32(GICD_TYPER).* & 0x1f) + 1) * 32, 1020);
    var i: u32 = 32;
    while (i < lines) : (i += 32) d32(GICD_ICENABLER + i / 8).* = 0xffff_ffff;
    i = 32;
    while (i < lines) : (i += 4) {
        d32(GICD_IPRIORITYR + i).* = 0xa0a0_a0a0;
        const t: u32 = @as(u32, 1) << @intCast(target & 7);
        d32(GICD_ITARGETSR + i).* = t | t << 8 | t << 16 | t << 24;
    }
    d32(GICD_CTLR).* = 1;
}

/// This core's interface: take every priority, and the IPI and timer
/// interrupts (their enables are banked per core).
pub fn initCpu() void {
    if (dist == 0) return;
    d32(GICD_ISENABLER).* = (@as(u32, 1) << sgi_reschedule) | (@as(u32, 1) << timer_ppi);
    c32(GICC_PMR).* = 0xff;
    c32(GICC_BPR).* = 0;
    c32(GICC_CTLR).* = 1;
}

pub fn enable(line: u32, on: bool) void {
    if (dist == 0 or line < 32 or line >= lines) return;
    const bit = @as(u32, 1) << @intCast(line % 32);
    d32((if (on) @as(usize, GICD_ISENABLER) else GICD_ICENABLER) + (line / 32) * 4).* = bit;
}

/// Take the highest-priority pending interrupt (its IAR value).
pub fn acknowledge() u32 {
    return c32(GICC_IAR).*;
}

pub fn end(iar: u32) void {
    c32(GICC_EOIR).* = iar;
}

/// Raise the reschedule SGI on one CPU interface.
pub fn sendSgi(target: u32) void {
    asm volatile ("dsb ishst" ::: .{ .memory = true });
    d32(GICD_SGIR).* = (@as(u32, 1) << @intCast(16 + (target & 7))) | sgi_reschedule;
}
