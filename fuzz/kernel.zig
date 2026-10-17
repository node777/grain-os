//! Fuzz targets for the kernel: every way into it (system calls, faults,
//! interrupts, time, boot) and the parsers it runs on boot data. See
//! user.zig for the rest, and source.zig for how targets are driven:
//!
//!   zig build test                  each target, a seeded sweep
//!   zig build fuzz                  a longer sweep (-Dfuzz-sweep=percent)
//!   zig build fuzz --fuzz[=N]       Zig's coverage-guided fuzzer (crashes
//!                                   are saved under .zig-cache/f/)
//!
//! A target fails by returning an error or by panicking (Zig's safety
//! checks are on: an overflow, a bad index or `unreachable` is a finding).
//! The kernel's invariants are checked after every kernel entry.
const std = @import("std");
const fuzz = @import("source.zig");
const Source = fuzz.Source;
const sim = @import("sim");
const core = @import("core");

// ---------------------------------------------------------------------------
// The kernel

/// System calls (plausible and garbage, from every kind of thread), faults,
/// interrupts on any line, IPIs and time, on one or two harts; the
/// invariants after every kernel entry.
fn kernelEntries(src: *Source) !void {
    const harts: u32 = 1 + @as(u32, @intCast(src.below(2)));
    var m = try sim.Machine.boot(harts, 4 << 20);
    defer m.deinit();
    const gen: sim.driver.Gen(*Source) = .{ .rng = src };
    var st: sim.driver.Stats = .{};
    var n: usize = 0;
    while (n < 2000 and src.more()) : (n += 1) {
        _ = try sim.driver.step(&m, gen, harts, &st);
        // Like the simulator: a machine with nothing left to run is done.
        if (m.current(0) == null and (harts == 1 or m.current(1) == null) and sim.arch.timer[0] == std.math.maxInt(u64) and (harts == 1 or sim.arch.timer[1] == std.math.maxInt(u64))) break;
    }
}

/// Boot: a damaged root task image and device tree copy, and odd platform
/// numbers (harts, interrupt lines, device ranges). Boot may refuse; it may
/// not crash, and a machine that boots must hold its invariants.
fn kernelBoot(src: *Source) !void {
    var plat = sim.arch.platform(1 + @as(u32, @intCast(src.below(4))), 4 << 20);
    if (src.chance(30)) plat.plic_ndev = @intCast(src.below(2000));
    if (src.chance(20)) {
        plat.irq_first = @intCast(src.below(64));
        plat.irq_end = @intCast(src.below(1100));
    }
    if (src.chance(30)) {
        plat.devices_len = src.below(core.fdt.max_devices + 1);
        for (plat.devices[0..plat.devices_len]) |*d| d.* = .{ .base = src.below(1 << 40) & ~@as(u64, 0xfff), .size = src.below(1 << 32) };
    }
    if (src.chance(20)) plat.timebase_hz = src.int(u64);
    var elf = sim.arch.fakeRootElf();
    const root_elf = if (src.chance(80)) src.mutate(&elf) else &elf;
    var dtb_buf: [8192]u8 = undefined;
    const dtb = src.slice(&dtb_buf);
    if (dtb.len >= 8 and src.chance(50)) std.mem.writeInt(u32, dtb[0..4], 0xd00dfeed, .big);
    var m = sim.Machine.bootWith(@intCast(plat.harts_len), 4 << 20, plat, root_elf, dtb, .{}) catch return;
    defer m.deinit();
    try m.check();
}

const arm_dtb = @embedFile("arm.dtb");
const riscv_dtb = @embedFile("riscv.dtb");

/// The device tree parser, on damaged copies of QEMU's trees and on noise.
fn deviceTree(src: *Source) !void {
    var buf: [8192]u8 = undefined;
    const blob = if (src.chance(90)) blk: {
        const sample = if (src.chance(50)) arm_dtb else riscv_dtb;
        @memcpy(buf[0..sample.len], sample);
        break :blk src.mutate(buf[0..sample.len]);
    } else src.slice(&buf);
    const fdt = core.fdt.Fdt.init(blob) catch return;
    try std.testing.expect(fdt.usedSize() <= fdt.totalSize());
    const p = core.fdt.parsePlatform(fdt) catch return;
    _ = p.deviceIrqs();
    if (core.fdt.findPciHost(fdt) catch null) |host| {
        for (0..32) |dev| for (1..5) |pin| {
            _ = host.irqOf(@intCast(dev), @intCast(pin));
        };
    }
}

/// The ELF loader's parser (the kernel's, and Steward's for every program).
fn elfImage(src: *Source) !void {
    var elf = sim.arch.fakeRootElf();
    const bytes = src.mutate(&elf);
    const img = core.elf.Image.parse(bytes, core.elf.machine_riscv) catch return;
    var segs = img.segments();
    while (segs.next() catch return) |seg| {
        try std.testing.expect(seg.data.len <= seg.mem_size);
        try std.testing.expect(seg.vaddr +% seg.mem_size >= seg.vaddr);
    }
}

// ---------------------------------------------------------------------------

test "fuzz: kernel entries" {
    try fuzz.run(kernelEntries, .{ .sweep = 40, .steps = 400 });
}
test "fuzz: kernel boot" {
    try fuzz.run(kernelBoot, .{ .sweep = 60 });
}
test "fuzz: device tree" {
    try fuzz.run(deviceTree, .{ .sweep = 2000 });
}
test "fuzz: ELF images" {
    try fuzz.run(elfImage, .{ .sweep = 2000 });
}
