//! Caravan — the Grain OS microkernel: entry and glue, for every architecture.
//!
//! This file connects the hardware to the portable kernel core: it brings up
//! harts, turns every trap into a `core.Event`, runs `handle` under the
//! kernel lock, then resumes whichever thread the core chose (or idles).
//!
//! Besides the core's interface (core/kernel.zig), `arch` gives this file:
//!
//!   HartLocal, harts, hart_count, self(), relax()
//!   bootRootPhys(), switchRoot(h, pa), serviceRequests(h)
//!   name                    the architecture, for the boot record
//!   kernel_offset           virtual minus physical address of the image
//!   now(), instret()        the platform timer; instructions retired
//!   setupHart(h)            per-hart registers (trap vector, interrupts)
//!   initPlatform(p, id)     harts and interrupt controller from the device tree
//!   platformRecord(p)       fields for the `platform` record
//!   startHart(h)            start a secondary hart at kmainSecondary
//!   sendIpi(h)              make hart h trap into the kernel
//!   trapCause(kind, pc)     why we trapped (`kind` comes from the entry code)
//!   skipSyscall(ctx)        step a thread past its system-call instruction
//!   interruptEvent(h, raw, *claimed)  the core event for an interrupt
//!   completeIrq(h, line)    finish a claimed device interrupt
//!   resumeThread(ctx)       load a thread's registers and drop to user mode
//!   idle(h)                 wait for interrupts on this hart's stack
//!   exit(code)              power off, reporting `code` if the board can
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const abi = @import("abi");
const klog = core.klog;
const arch = switch (builtin.cpu.arch) {
    .riscv64 => @import("arch/riscv64/arch.zig"),
    .aarch64 => @import("arch/aarch64/arch.zig"),
    else => @compileError("no Caravan port for this architecture"),
};

comptime {
    _ = arch.boot;
}

pub const panic = std.debug.FullPanic(panicHandler);

const Kernel = core.Kernel(arch);
var kernel: Kernel = .{};
var platform: core.fdt.Platform = .{};

const root_elf = @embedFile("root_task.elf");
/// Root task time slice: 10 ms at the platform timebase.
const root_slice_ms = 10;

// ---------------------------------------------------------------------------
// Kernel lock. Kernel entries are short and non-preemptible, so one lock
// serialises them (as seL4 does on SMP). Waiting harts keep servicing
// lock-free requests so a hart holding the lock can rely on them.

var lock_word = std.atomic.Value(u32).init(0);

fn lock(h: *arch.HartLocal) void {
    while (lock_word.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        arch.serviceRequests(h);
        arch.relax();
    }
}

fn unlock() void {
    lock_word.store(0, .release);
}

// ---------------------------------------------------------------------------
// Logging outside the core (boot and panics).

var log_buf: [256]u8 = undefined;

fn log(comptime event: []const u8, fields: anytype) void {
    const line = klog.format(&log_buf, event, fields) catch return;
    arch.debugWrite(line);
    arch.debugWrite("\n");
}

fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    log("panic", .{ .pc = klog.hex(ret_addr orelse @returnAddress()), .msg = msg });
    arch.exit(0xff);
}

// ---------------------------------------------------------------------------
// Self-profile: instructions spent in the kernel core per kind of entry,
// printed as records when the system halts.

const ProfileKind = enum { syscall_call, syscall_reply_recv, syscall_invoke, syscall_other, fault, timer, irq, ipi };
var profile_count: [std.meta.fieldNames(ProfileKind).len]u64 = @splat(0);
var profile_instret: [std.meta.fieldNames(ProfileKind).len]u64 = @splat(0);

fn profileKind(ev: core.kernel.Event, ctx: ?*arch.Context) ProfileKind {
    return switch (ev) {
        .syscall => switch (@as(abi.Syscall, @fromBackingInt(@intCast(ctx.?.get(.a7))))) {
            .call => .syscall_call,
            .reply_recv => .syscall_reply_recv,
            .invoke => .syscall_invoke,
            else => .syscall_other,
        },
        .fault => .fault,
        .timer => .timer,
        .irq => .irq,
        .ipi => .ipi,
    };
}

fn handleProfiled(h: *arch.HartLocal, ev: core.kernel.Event, ctx: ?*arch.Context) void {
    const kind = @backingInt(profileKind(ev, ctx));
    const start = arch.instret();
    kernel.handle(h.index, arch.now(), ev);
    profile_instret[kind] += arch.instret() - start;
    profile_count[kind] += 1;
}

fn printProfile() void {
    inline for (comptime std.meta.fieldNames(ProfileKind), 0..) |name, i| {
        if (profile_count[i] != 0) log("profile", .{ .entry = name, .count = profile_count[i], .core_instret_avg = profile_instret[i] / profile_count[i] });
    }
}

// ---------------------------------------------------------------------------
// Running threads

/// Resume the thread the core chose for this hart, or idle. Called with the
/// kernel lock held; releases it.
fn enterNext(h: *arch.HartLocal) noreturn {
    deliverKicks(h);
    if (kernel.exitRequested()) |code| {
        printProfile();
        arch.exit(code);
    }
    if (kernel.currentThread(h.index)) |t| {
        const root = kernel.vspaceRoot(t).?;
        if (h.active_root.raw != root) arch.switchRoot(h, root);
        t.ctx.kernel_sp = h.stack_top;
        t.ctx.hart_local = @intFromPtr(h);
        h.in_user.store(true, .release);
        unlock();
        arch.resumeThread(&t.ctx);
    }
    if (kernel.stuck()) {
        if (!stuck_reported) {
            stuck_reported = true;
            log("stuck", .{ .reason = "no_runnable_threads_and_no_timer" });
            kernel.logThreads();
        }
        // Everything waits on a device. Keep a heartbeat timer: under QEMU
        // -icount, a machine with every hart halted and no timer armed never
        // receives the host's I/O completion (a flush can wait forever); a
        // pending deadline keeps QEMU's clock, and so its I/O, moving. On
        // hardware it costs one interrupt per 10 ms while fully idle.
        arch.setTimer(h.index, arch.now() + platform.timebase_hz / 100);
    }
    // Idle on the kernel's own table, so no user root stays live here.
    if (h.active_root.raw != arch.bootRootPhys()) arch.switchRoot(h, arch.bootRootPhys());
    unlock();
    arch.idle(h);
}

var stuck_reported = false;

/// Make other harts notice changes to their state, and wait until any hart
/// that was running user code has trapped into the kernel. After this, no
/// hart still executes a thread the core just took away from it.
fn deliverKicks(h: *arch.HartLocal) void {
    const mask = kernel.takeKicks();
    if (mask == 0) return;
    var snap: [arch.max_harts]u64 = undefined;
    for (arch.harts[0..arch.hart_count], 0..) |*o, i| {
        if (mask & (@as(u32, 1) << @intCast(i)) == 0 or o == h or !o.online) continue;
        snap[i] = o.epoch.load(.acquire);
        arch.sendIpi(o);
    }
    for (arch.harts[0..arch.hart_count], 0..) |*o, i| {
        if (mask & (@as(u32, 1) << @intCast(i)) == 0 or o == h or !o.online) continue;
        while (o.in_user.load(.acquire) and o.epoch.load(.acquire) == snap[i]) arch.relax();
    }
}

fn eventFor(h: *arch.HartLocal, cause: arch.Cause, claimed: *?u32) core.kernel.Event {
    return switch (cause) {
        .syscall => .syscall,
        .fault => |f| .{ .fault = f },
        .interrupt => |raw| arch.interruptEvent(h, raw, claimed),
    };
}

/// `kind` is set by the entry code where the hardware has no register
/// that tells a synchronous exception from an interrupt.
export fn caravanUserTrap(ctx: *arch.Context, kind: usize) callconv(.c) noreturn {
    const h = arch.self();
    // The entry code has saved every register into ctx; from here another
    // hart may tear the thread down, so ctx is only touched under the lock
    // and only if the thread is still ours.
    _ = h.epoch.fetchAdd(1, .acq_rel);
    h.in_user.store(false, .release);
    arch.serviceRequests(h);
    var claimed: ?u32 = null;
    lock(h);
    const ours = if (kernel.currentThread(h.index)) |t| &t.ctx == ctx else false;
    var cause = arch.trapCause(kind, if (ours) ctx.get(.pc) else 0);
    if (!ours and cause != .interrupt) cause = .{ .interrupt = arch.stale_trap }; // stale: just reschedule
    if (cause == .syscall) arch.skipSyscall(ctx);
    const ev = eventFor(h, cause, &claimed);
    handleProfiled(h, ev, if (ours) ctx else null);
    if (claimed) |line| arch.completeIrq(h, line);
    enterNext(h);
}

/// Traps taken in kernel mode: expected only while idling (interrupts).
export fn caravanKernelTrap(frame: *arch.Frame, kind: usize) callconv(.c) void {
    const h = arch.self();
    const cause = arch.trapCause(kind, frame.pc());
    if (cause != .interrupt) {
        log("kernel_fault", arch.kernelFaultRecord(frame));
        @panic("fault in kernel mode");
    }
    arch.serviceRequests(h);
    var claimed: ?u32 = null;
    const ev = eventFor(h, cause, &claimed);
    lock(h);
    handleProfiled(h, ev, null);
    if (claimed) |line| arch.completeIrq(h, line);
    enterNext(h);
}

// ---------------------------------------------------------------------------
// Boot

extern const __kernel_start: u8;
extern const __kernel_end: u8;

/// The loader's measurement, if the third boot register points at one in
/// RAM (firmware leaves anything there; only the magic is believed).
fn readMeasurement(pa: usize) abi.Measurement {
    if (pa == 0 or pa % 8 != 0) return .{};
    const size = @sizeOf(abi.BootMeasurement);
    for (platform.memoryRanges()) |r| {
        if (pa >= r.base and pa <= r.end() -| size) {
            const rec: *const abi.BootMeasurement = @ptrFromInt(arch.physToVirt(pa));
            return if (rec.magic == abi.boot_measurement_magic) rec.m else .{};
        }
    }
    return .{};
}

export fn kmain(hart_id: usize, dtb_pa: usize, measure_pa: usize) callconv(.c) noreturn {
    // Hart-local block 0 is the boot hart until the device tree says more.
    const h0 = &arch.harts[0];
    h0.* = .{ .hart_id = @intCast(hart_id), .stack_top = arch.stackTop(0) };
    arch.setupHart(h0);

    const fdt = core.fdt.Fdt.fromPtr(@ptrFromInt(arch.physToVirt(dtb_pa))) catch @panic("bad device tree");
    platform = core.fdt.parsePlatform(fdt) catch @panic("unreadable device tree");
    // Logical hart 0 is whichever hart booted us; the others follow in
    // device-tree order. Manifests and the core only see logical indices.
    arch.initPlatform(&platform, @intCast(hart_id)) catch |e| {
        log("platform_failed", .{ .err = @errorName(e) });
        @panic("unsupported platform");
    };
    arch.setupHart(h0);
    // Read before anything is allocated: the record lives in the loader's memory.
    const measurement = readMeasurement(measure_pa);

    log("boot", .{
        .kernel = "caravan",
        .arch = arch.name,
        .hart = hart_id,
        .harts = arch.hart_count,
        .timebase_hz = platform.timebase_hz,
        .dtb = klog.hex(dtb_pa),
        .image = klog.hex(@intFromPtr(&__kernel_start) - arch.kernel_offset),
        .measured = measurement.measured(),
    });
    log("platform", arch.platformRecord(&platform));

    const image_pa = @intFromPtr(&__kernel_start) - arch.kernel_offset;
    const image_end = @intFromPtr(&__kernel_end) - arch.kernel_offset;
    const reserved = [_]core.fdt.Range{
        .{ .base = image_pa, .size = image_end - image_pa },
        .{ .base = dtb_pa, .size = fdt.totalSize() },
    };
    kernel.boot(.{
        .platform = &platform,
        .reserved = &reserved,
        .root_elf = root_elf,
        .dtb = @as([*]const u8, @ptrFromInt(arch.physToVirt(dtb_pa)))[0..fdt.usedSize()],
        .measurement = measurement,
        .now = arch.now(),
        .root_budget_ticks = platform.timebase_hz / 1000 * root_slice_ms,
    }) catch |e| {
        log("boot_failed", .{ .err = @errorName(e) });
        @panic("kernel boot failed");
    };

    lock(h0);
    h0.online = true;
    kernel.hartOnline(0, arch.now());
    // Start the other harts once this one is online (else the first to
    // join sees no hart running anything); each joins at kmainSecondary,
    // waiting for the lock this one holds.
    for (arch.harts[1..arch.hart_count]) |*h| {
        arch.startHart(h) catch {
            log("hart_start_failed", .{ .hart = h.hart_id });
            continue;
        };
    }
    enterNext(h0);
}

export fn kmainSecondary(hart_id: usize, index: usize) callconv(.c) noreturn {
    const h = &arch.harts[index];
    arch.setupHart(h);
    lock(h);
    h.online = true;
    log("hart_online", .{ .hart = hart_id, .index = index });
    kernel.hartOnline(@intCast(index), arch.now());
    enterNext(h);
}
