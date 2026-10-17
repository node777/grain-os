//! Aurora: the dawn. The first Grain code that wakes on the hardware.
//!
//! Firmware (OpenSBI) starts Aurora on the boot hart with the device tree.
//! Aurora finds the disk, asks Tablecloth which generation to boot (a
//! generation on trial is tried a few times, then given up for the last one
//! that came up), loads that generation's kernel, checking every chunk
//! against the generation's hash, and jumps to it as firmware would have:
//! a0 = hart id, a1 = device tree, paging off.
//!
//! It reads the store's public side only: no passphrase is needed to boot.
//!
//! Measured boot: before jumping, Aurora hashes its own code and the
//! generation it chose into a chain (grain/lib/measure.zig) and hands the
//! kernel a record of it in a2.
const std = @import("std");
const fdt = @import("fdt");
const sbi = @import("sbi");
const klog = @import("klog");
const grain = @import("grain");
const tc = grain.tablecloth;
const gen = grain.generation;
const blk = grain.virtio_blk;
const virtio = grain.virtio;

const Store = tc.Store(blk.Blk, .{});

var store: Store = undefined;
var disk: blk.Blk = undefined;
var queue_page: [4096]u8 align(4096) = undefined;
var req_page: [4096]u8 align(4096) = undefined;
var data_page: [4096]u8 align(4096) = undefined;
var descriptor: [tc.max_object]u8 = undefined;
var chunk: [tc.max_object]u8 = undefined;

extern var __aurora_start: u8;
extern var __aurora_code_end: u8;
extern var __aurora_end: u8;

/// What Aurora measured, for the kernel (its address goes in a2).
var boot_record: grain.abi.BootMeasurement align(8) = .{ .m = .{} };
extern var __bss_start: u8;
extern var __bss_end: u8;

export fn _start() linksection(".text.start") callconv(.naked) noreturn {
    asm volatile (
        \\ la sp, __stack_top
        \\ call auroraMain
        \\ unimp
    );
}

fn say(comptime event: []const u8, fields: anytype) void {
    var buf: [256]u8 = undefined;
    const line = klog.formatPrefixed("@aurora", buf[0 .. buf.len - 1], event, fields) catch return;
    for (line) |c| sbi.consolePutByte(c);
    sbi.consolePutByte('\n');
}

fn short(h: tc.Hash) @TypeOf(klog.hex(@as(u64, 0))) {
    return klog.hex(std.mem.readInt(u64, h[0..8], .big));
}

var finisher: ?u64 = null;

fn fail(comptime reason: []const u8) noreturn {
    say("fail", .{ .reason = reason });
    // QEMU's test finisher: power off with a failure code the harness sees.
    if (finisher) |f| @as(*volatile u32, @ptrFromInt(f)).* = 0x3333 | (1 << 16);
    sbi.shutdown(.system_failure);
}

fn overlaps(a0: u64, a1: u64, b0: u64, b1: u64) bool {
    return a0 < b1 and b0 < a1;
}

export fn auroraMain(hart: usize, dtb: usize) callconv(.c) noreturn {
    const bss = @as([*]u8, @ptrCast(&__bss_start))[0 .. @intFromPtr(&__bss_end) - @intFromPtr(&__bss_start)];
    @memset(bss, 0);
    const tree = fdt.Fdt.fromPtr(@ptrFromInt(dtb)) catch fail("bad_device_tree");
    const platform = fdt.parsePlatform(tree) catch fail("unreadable_device_tree");
    finisher = platform.test_finisher;
    say("start", .{ .hart = hart, .dtb = klog.hex(dtb) });

    const base = for (platform.deviceRanges()) |r| {
        if (virtio.Device.identify(@intCast(r.base)) == blk.device_id) break r.base;
    } else fail("no_disk");
    const page = struct {
        fn of(p: *align(4096) [4096]u8) blk.Page {
            return .{ .va = @intFromPtr(p), .pa = @intFromPtr(p) };
        }
    }.of;
    disk = blk.Blk.init(@intCast(base), page(&queue_page), page(&req_page), page(&data_page), 0, 0) catch fail("disk_init");
    store.mount(&disk) catch fail("no_store");
    const was_pending = !std.mem.eql(u8, &store.sup.boot.pending, &tc.zero);
    const choice = (store.chooseBoot() catch fail("store_write")) orelse fail("no_generation");
    const trial = std.mem.eql(u8, &choice, &store.sup.boot.pending);
    if (was_pending and !trial) say("gave_up", .{ .reason = "pending_generation_never_came_up" });

    const d = store.get(choice, "", &descriptor) catch fail("descriptor_unreadable");
    const v = gen.View.parse(d) catch fail("bad_descriptor");
    const me0 = @intFromPtr(&__aurora_start);
    const me1 = @intFromPtr(&__aurora_end);
    for (v.segments) |s| {
        if (overlaps(s.paddr, s.paddr +| s.memsz, me0, me1) or overlaps(s.paddr, s.paddr +| s.memsz, dtb, dtb + tree.totalSize()) or s.paddr +| s.memsz == std.math.maxInt(u64))
            fail("generation_overlaps_aurora");
    }
    var bytes: u64 = 0;
    for (v.segments) |s| {
        const dst = @as([*]u8, @ptrFromInt(s.paddr));
        var off: u64 = 0;
        for (v.hashes[s.first_chunk..][0..s.chunks]) |h| {
            const c = store.get(h, "", &chunk) catch fail("chunk_missing_or_corrupt");
            if (off + c.len > s.filesz) fail("chunk_overruns_segment");
            @memcpy(dst[off..][0..c.len], c);
            off += c.len;
        }
        if (off != s.filesz) fail("segment_short");
        @memset(dst[s.filesz..s.memsz], 0);
        bytes += s.filesz;
    }
    say("boot", .{
        .generation = short(choice),
        .label = v.label(),
        .trial = trial,
        .tries = store.sup.boot.tries,
        .bytes = bytes,
        .entry = klog.hex(v.header.entry),
    });
    const code = @as([*]const u8, @ptrCast(&__aurora_start))[0 .. @intFromPtr(&__aurora_code_end) - @intFromPtr(&__aurora_start)];
    boot_record.m = grain.measure.measurement(code, choice);
    say("measured", .{ .chain = short(boot_record.m.chain), .loader = short(boot_record.m.loader), .generation = short(choice) });
    asm volatile ("fence.i" ::: .{ .memory = true });
    const entry: *const fn (usize, usize, usize) callconv(.c) noreturn = @ptrFromInt(v.header.entry);
    entry(hart, dtb, @intFromPtr(&boot_record));
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    say("panic", .{ .msg = msg });
    sbi.shutdown(.system_failure);
}
