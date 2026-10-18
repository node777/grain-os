//! grain-emu as a WebAssembly module, for the web page (web/). The page's
//! worker loads it, hands it a kernel image, and runs it a slice at a time.
//!
//! Imports (module "env"), provided by web/worker.js:
//!   host_console(ptr, len)        serial console output (the system log)
//!   host_port(port, ptr, len)     output on virtio console `port`
//!   host_entropy(ptr, len)        fill with random bytes (crypto.getRandomValues)
//!   host_now_ms() f64             a monotonic clock (performance.now)
//!   host_disk_flushed()           the guest flushed its disk: save what changed
//!
//! The disk lives in this module's memory; the page loads it from browser
//! storage before booting and saves the blocks `grain_dirty_next` reports.
const std = @import("std");
const emu = @import("machine.zig");

extern "env" fn host_console(ptr: [*]const u8, len: usize) void;
extern "env" fn host_port(port: u32, ptr: [*]const u8, len: usize) void;
extern "env" fn host_entropy(ptr: [*]u8, len: usize) void;
extern "env" fn host_now_ms() f64;
extern "env" fn host_disk_flushed() void;

const gpa = std.heap.wasm_allocator;

pub const disk_block = 4096;

var machine: ?*emu.Machine = null;
var disk: []u8 = &.{};
/// One bit per 4 KiB disk block written since the page last saved it.
var dirty: []u8 = &.{};
var start_ms: f64 = 0;

fn console(_: ?*anyopaque, bytes: []const u8) void {
    host_console(bytes.ptr, bytes.len);
}

fn portWrite(_: ?*anyopaque, port: u8, bytes: []const u8) void {
    host_port(port, bytes.ptr, bytes.len);
}

fn entropy(_: ?*anyopaque, out: []u8) void {
    host_entropy(out.ptr, out.len);
}

fn diskRead(_: ?*anyopaque, offset: u64, out: []u8) bool {
    if (offset > disk.len or out.len > disk.len - offset) return false;
    const o: usize = @intCast(offset);
    @memcpy(out, disk[o..][0..out.len]);
    return true;
}

fn diskWrite(_: ?*anyopaque, offset: u64, bytes: []const u8) bool {
    if (offset > disk.len or bytes.len > disk.len - offset) return false;
    const o: usize = @intCast(offset);
    @memcpy(disk[o..][0..bytes.len], bytes);
    var b = o / disk_block;
    while (b * disk_block < o + bytes.len) : (b += 1) dirty[b / 8] |= @as(u8, 1) << @intCast(b % 8);
    return true;
}

fn diskFlush(_: ?*anyopaque) bool {
    host_disk_flushed();
    return true;
}

fn nowNs(_: ?*anyopaque) u64 {
    const ms = host_now_ms() - start_ms;
    return if (ms <= 0) 0 else @intFromFloat(ms * 1_000_000);
}

/// Memory for the page to copy into (a kernel image, input).
export fn grain_alloc(len: usize) ?[*]u8 {
    const s = gpa.alloc(u8, len) catch return null;
    return s.ptr;
}

export fn grain_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

/// A zeroed disk of `bytes` (a multiple of 4 KiB); returns where it is, so
/// the page can fill in the blocks it saved before.
export fn grain_disk(bytes: usize) ?[*]u8 {
    if (bytes % disk_block != 0) return null;
    disk = gpa.alloc(u8, bytes) catch return null;
    @memset(disk, 0);
    dirty = gpa.alloc(u8, (bytes / disk_block + 7) / 8) catch return null;
    @memset(dirty, 0);
    return disk.ptr;
}

export fn grain_disk_ptr() ?[*]u8 {
    return if (disk.len > 0) disk.ptr else null;
}

/// The next block written since it was last reported, from `from` on, or
/// -1. Reporting clears it.
export fn grain_dirty_next(from: i32) i32 {
    var b: usize = @intCast(@max(from, 0));
    const blocks = disk.len / disk_block;
    while (b < blocks) : (b += 1) {
        if (dirty[b / 8] == 0) {
            b |= 7;
            continue;
        }
        const bit = @as(u8, 1) << @intCast(b % 8);
        if (dirty[b / 8] & bit != 0) {
            dirty[b / 8] &= ~bit;
            return @intCast(b);
        }
    }
    return -1;
}

/// Devices, as bits: 1 entropy, 2 disk (grain_disk first), 4 console,
/// 8 a second console (Envoy's). They take virtio slots in that order, as
/// on QEMU. Returns 0, or a negative error.
export fn grain_start(image: [*]const u8, image_len: usize, harts: u32, ram_mib: u32, devices: u32, realtime: bool) i32 {
    if (machine != null) return -1;
    var specs: [4]emu.DeviceSpec = undefined;
    var n: usize = 0;
    if (devices & 1 != 0) {
        specs[n] = .{ .kind = .rng };
        n += 1;
    }
    if (devices & 2 != 0) {
        if (disk.len == 0) return -2;
        specs[n] = .{ .kind = .blk };
        n += 1;
    }
    if (devices & 4 != 0) {
        specs[n] = .{ .kind = .console };
        n += 1;
    }
    if (devices & 8 != 0) {
        specs[n] = .{ .kind = .console };
        n += 1;
    }
    start_ms = host_now_ms();
    const m = emu.Machine.init(gpa, .{
        .harts = harts,
        .ram_mib = ram_mib,
        .devices = specs[0..n],
        .disk_bytes = disk.len,
        .realtime = realtime,
    }, .{
        .console = console,
        .port_write = portWrite,
        .entropy = entropy,
        .disk_read = diskRead,
        .disk_write = diskWrite,
        .disk_flush = diskFlush,
        .now_ns = nowNs,
    }) catch return -3;
    const entry = m.loadElf(image[0..image_len]) catch {
        m.deinit();
        return -4;
    };
    m.boot(entry) catch {
        m.deinit();
        return -5;
    };
    machine = m;
    return 0;
}

/// Run up to `budget` instructions. Returns 0 exited (see grain_exit_code),
/// 1 idle (only input can wake it), 2 waiting (see grain_wake_ms), 3 the
/// budget ran out, -1 not started.
export fn grain_run(budget: u32) i32 {
    const m = machine orelse return -1;
    return switch (m.run(budget)) {
        .exited => 0,
        .idle => 1,
        .waiting => 2,
        .budget => 3,
    };
}

export fn grain_exit_code() u32 {
    const m = machine orelse return 0;
    return m.exit_code orelse 0;
}

/// When waiting: milliseconds until the earliest timer is due.
export fn grain_wake_ms() f64 {
    const m = machine orelse return 0;
    const now = nowNs(null);
    return if (m.wake_ns > now) @as(f64, @floatFromInt(m.wake_ns - now)) / 1_000_000 else 0;
}

/// Bytes for virtio console `port`; returns how many it took.
export fn grain_input(port: u32, ptr: [*]const u8, len: usize) usize {
    const m = machine orelse return 0;
    return m.consoleInput(@intCast(port), ptr[0..len]);
}

/// Instructions retired so far, on all harts.
export fn grain_instructions() f64 {
    const m = machine orelse return 0;
    var n: u64 = 0;
    for (m.harts) |*h| n += h.instret;
    return @floatFromInt(n);
}

/// BLAKE3 of `len` bytes at `ptr`, into 32 bytes at `out` (the page checks
/// Envoy's audit chain with it, as tools/envoy.py does).
export fn grain_blake3(ptr: [*]const u8, len: usize, out: [*]u8) void {
    std.crypto.hash.Blake3.hash(ptr[0..len], out[0..32], .{});
}
