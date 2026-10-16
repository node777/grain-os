//! Caravan — the Grain OS microkernel.
//!
//! Phase 0: boot on one hart, install the trap vector, prove that exceptions
//! and timer interrupts round-trip, report results as structured records, and
//! shut down with an exit status a harness can check. See docs/PLAN.md.
const std = @import("std");
const core = @import("core/core.zig");
const klog = core.klog;
const csr = @import("arch/riscv64/csr.zig");
const sbi = @import("arch/riscv64/sbi.zig");
const trap = @import("arch/riscv64/trap.zig");
const board = @import("arch/riscv64/board.zig");

comptime {
    _ = @import("arch/riscv64/boot.zig");
}

pub const panic = std.debug.FullPanic(panicHandler);

// ---------------------------------------------------------------------------
// Console

fn write(bytes: []const u8) void {
    for (bytes) |c| sbi.consolePutByte(c);
}

var log_buf: [256]u8 = undefined;

fn log(comptime event: []const u8, fields: anytype) void {
    const line = klog.format(&log_buf, event, fields) catch {
        write(klog.prefix ++ " log_truncated event=" ++ event ++ "\n");
        return;
    };
    write(line);
    write("\n");
}

fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    log("panic", .{ .pc = klog.hex(ret_addr orelse @returnAddress()), .msg = msg });
    board.exit(0xff);
}

// ---------------------------------------------------------------------------
// Traps

/// QEMU virt's timebase. Read from the device tree once DTB parsing lands.
const timebase_hz: u64 = 10_000_000;
const tick_interval: u64 = timebase_hz / 1000;

var ticks = std.atomic.Value(u32).init(0);
var ticks_wanted: u32 = 0;
var breakpoints = std.atomic.Value(u32).init(0);

export fn caravanTrap(frame: *trap.Frame) callconv(.c) void {
    const cause = trap.decode(csr.read("scause"), csr.read("stval"));
    switch (cause) {
        .timer => {
            const n = ticks.fetchAdd(1, .monotonic) + 1;
            sbi.setTimer(if (n < ticks_wanted) csr.time() + tick_interval else std.math.maxInt(u64));
        },
        .breakpoint => {
            _ = breakpoints.fetchAdd(1, .monotonic);
            frame.sepc += trap.instructionLength(frame.sepc);
        },
        else => {
            log("trap_unhandled", .{ .cause = @tagName(cause), .sepc = klog.hex(frame.sepc) });
            @panic("unhandled trap");
        },
    }
}

// ---------------------------------------------------------------------------
// Self-tests: each is a function returning true on pass.

fn testBreakpoint() bool {
    const before = breakpoints.load(.monotonic);
    asm volatile ("ebreak");
    return breakpoints.load(.monotonic) == before + 1;
}

fn testTimer() bool {
    ticks.store(0, .monotonic);
    ticks_wanted = 3;
    csr.set("sie", csr.sie_stie);
    sbi.setTimer(csr.time() + tick_interval);
    csr.set("sstatus", csr.sstatus_sie);
    const start = csr.time();
    while (ticks.load(.monotonic) < ticks_wanted) {
        if (csr.time() - start > timebase_hz) break; // 1 s of virtual time
        csr.wfi();
    }
    csr.clear("sstatus", csr.sstatus_sie);
    csr.clear("sie", csr.sie_stie);
    return ticks.load(.monotonic) == ticks_wanted;
}

const tests = .{
    .{ "breakpoint_exception", testBreakpoint },
    .{ "timer_interrupt", testTimer },
};

// ---------------------------------------------------------------------------

extern const __kernel_start: u8;
extern const __kernel_end: u8;

export fn kmain(hart_id: usize, dtb: usize) callconv(.c) noreturn {
    log("boot", .{
        .kernel = "caravan",
        .arch = .riscv64,
        .hart = hart_id,
        .dtb = klog.hex(dtb),
        .image_start = klog.hex(@intFromPtr(&__kernel_start)),
        .image_end = klog.hex(@intFromPtr(&__kernel_end)),
    });

    trap.install();

    var failed: u32 = 0;
    inline for (tests) |t| {
        const ok = t[1]();
        if (!ok) failed += 1;
        log("test", .{ .name = t[0], .result = if (ok) "pass" else "fail" });
    }
    log("summary", .{ .tests = tests.len, .failed = failed });
    log("halt", .{ .reason = if (failed == 0) "selftest_complete" else "selftest_failed" });
    board.exit(@intCast(failed));
}
