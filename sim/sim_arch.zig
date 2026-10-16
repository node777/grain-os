//! A simulated machine for the kernel core: RAM is a host buffer, the timer
//! and interrupt controller are plain variables, and the page-table format is
//! real Sv39. Everything is deterministic.
const std = @import("std");
const core = @import("core");
pub const Paging = @import("sv39");

pub const elf_machine: u16 = core.elf.machine_riscv;
pub const ram_base: u64 = 0x8000_0000;
pub const max_harts = core.kernel.max_harts;

pub var ram: []align(4096) u8 = &.{};
pub var timer: [max_harts]u64 = @splat(std.math.maxInt(u64));
pub var irq_masked: [core.kernel.max_irqs]bool = @splat(true);
pub var tlb_flushes: u64 = 0;
pub var retired_roots: u64 = 0;
pub var echo = false;
pub var output: std.ArrayList(u8) = .empty;
pub var output_alloc: std.mem.Allocator = std.heap.page_allocator;

pub const Context = struct {
    x: [32]u64 = @splat(0),
    pc: u64 = 0,

    pub fn init(pc: u64, sp: u64, a0: u64) Context {
        var c: Context = .{ .pc = pc };
        c.x[2] = sp;
        c.x[10] = a0;
        return c;
    }

    fn index(r: core.kernel.Reg) usize {
        return switch (r) {
            .pc => unreachable,
            .sp => 2,
            .a0 => 10,
            .a1 => 11,
            .a2 => 12,
            .a3 => 13,
            .a4 => 14,
            .a5 => 15,
            .a6 => 16,
            .a7 => 17,
        };
    }

    pub fn get(c: *const Context, r: core.kernel.Reg) usize {
        return if (r == .pc) c.pc else c.x[index(r)];
    }

    pub fn set(c: *Context, r: core.kernel.Reg, v: usize) void {
        if (r == .pc) c.pc = v else c.x[index(r)] = v;
    }
};

pub fn init(size: usize) !void {
    ram = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(4096), size);
    @memset(ram, 0xAA); // the kernel must zero what it uses
    timer = @splat(std.math.maxInt(u64));
    irq_masked = @splat(true);
    tlb_flushes = 0;
    retired_roots = 0;
    output.clearRetainingCapacity();
}

pub fn deinit() void {
    std.heap.page_allocator.free(ram);
    ram = &.{};
}

pub fn physToVirt(pa: u64) usize {
    std.debug.assert(pa >= ram_base and pa < ram_base + ram.len);
    return @intFromPtr(ram.ptr) + @as(usize, @intCast(pa - ram_base));
}

pub fn initRootTable(ptes: *[Paging.entries]u64) void {
    // Stand-in for the kernel half: one global kernel leaf.
    ptes[510] = Paging.makeKernelLeaf(ram_base, true, true, true);
}

pub fn flushTlb(root: u64) void {
    _ = root;
    tlb_flushes += 1;
}

pub fn retireRoot(pa: u64) void {
    _ = pa;
    retired_roots += 1;
}

pub fn setTimer(hart: u32, deadline: u64) void {
    timer[hart] = deadline;
}

pub fn irqMask(line: u32) void {
    irq_masked[line] = true;
}

pub fn irqUnmask(line: u32) void {
    irq_masked[line] = false;
}

pub fn debugWrite(bytes: []const u8) void {
    if (echo) std.debug.print("{s}", .{bytes});
    output.appendSlice(output_alloc, bytes) catch {};
}

/// A minimal valid RISC-V ELF: one RX page at 0x10000, entry there.
pub fn fakeRootElf() [4096 + 4096]u8 {
    var buf: [4096 + 4096]u8 = @splat(0);
    @memcpy(buf[0..4], "\x7fELF");
    buf[4] = 2;
    buf[5] = 1;
    std.mem.writeInt(u16, buf[16..18], 2, .little);
    std.mem.writeInt(u16, buf[18..20], elf_machine, .little);
    std.mem.writeInt(u64, buf[24..32], 0x10000, .little);
    std.mem.writeInt(u64, buf[32..40], 64, .little);
    std.mem.writeInt(u16, buf[54..56], 56, .little);
    std.mem.writeInt(u16, buf[56..58], 1, .little);
    const ph = buf[64..];
    std.mem.writeInt(u32, ph[0..4], 1, .little);
    std.mem.writeInt(u32, ph[4..8], 5, .little);
    std.mem.writeInt(u64, ph[8..16], 4096, .little);
    std.mem.writeInt(u64, ph[16..24], 0x10000, .little);
    std.mem.writeInt(u64, ph[32..40], 4096, .little);
    std.mem.writeInt(u64, ph[40..48], 4096, .little);
    return buf;
}

pub fn platform(harts: u32, ram_size: u64) core.fdt.Platform {
    var p: core.fdt.Platform = .{};
    p.memory[0] = .{ .base = ram_base, .size = ram_size };
    p.memory_len = 1;
    p.reserved[0] = .{ .base = ram_base, .size = 0x20_0000 }; // "firmware"
    p.reserved_len = 1;
    for (0..harts) |i| p.harts[i] = .{ .id = @intCast(i) };
    p.harts_len = harts;
    p.timebase_hz = 10_000_000;
    p.plic_ndev = 31;
    p.devices[0] = .{ .base = 0x1000_0000, .size = 0x1000 };
    p.devices_len = 1;
    return p;
}
