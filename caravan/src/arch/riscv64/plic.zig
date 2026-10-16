//! Platform-Level Interrupt Controller (riscv,plic0). The kernel owns it:
//! userspace sees interrupt lines only as Irq capabilities.
var base: usize = 0;
var ndev: u32 = 0;

pub fn init(virt_base: usize, lines: u32) void {
    base = virt_base;
    ndev = lines;
    var i: u32 = 1;
    while (i <= ndev) : (i += 1) reg(4 * @as(usize, i)).* = 1;
}

fn reg(off: usize) *volatile u32 {
    return @ptrFromInt(base + off);
}

pub fn enable(ctx: u32, line: u32, on: bool) void {
    if (base == 0 or line == 0 or line > ndev) return;
    const r = reg(0x2000 + @as(usize, ctx) * 0x80 + (line / 32) * 4);
    const bit = @as(u32, 1) << @intCast(line % 32);
    r.* = if (on) r.* | bit else r.* & ~bit;
}

pub fn setThreshold(ctx: u32, t: u32) void {
    if (base == 0) return;
    reg(0x20_0000 + @as(usize, ctx) * 0x1000).* = t;
}

pub fn claim(ctx: u32) u32 {
    if (base == 0) return 0;
    return reg(0x20_0000 + @as(usize, ctx) * 0x1000 + 4).*;
}

pub fn complete(ctx: u32, line: u32) void {
    if (base == 0) return;
    reg(0x20_0000 + @as(usize, ctx) * 0x1000 + 4).* = line;
}
