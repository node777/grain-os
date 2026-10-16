//! Test bench around the kernel core: boots a simulated machine and lets a
//! test act as whichever user thread is current on a hart.
const std = @import("std");
const core = @import("core");
const abi = @import("abi");
pub const arch = @import("sim_arch.zig");

pub const K = core.Kernel(arch);
pub const Thread = K.Thread;

pub const Result = struct {
    status: abi.Status,
    tag: abi.Tag,
    words: [5]u64,
    badge: u64,
};

pub const Machine = struct {
    k: *K,
    now: u64 = 1000,
    root: *Thread,

    pub fn boot(harts: u32, ram_size: usize) !Machine {
        try arch.init(ram_size);
        const k = try std.heap.page_allocator.create(K);
        k.* = .{};
        const plat = arch.platform(harts, ram_size);
        const elf_bytes = arch.fakeRootElf();
        try k.boot(.{ .platform = &plat, .reserved = &.{}, .root_elf = &elf_bytes, .now = 1000, .root_budget_ticks = 100_000 });
        for (0..harts) |h| k.hartOnline(@intCast(h), 1000);
        return .{ .k = k, .root = k.currentThread(0).? };
    }

    pub fn deinit(m: *Machine) void {
        std.heap.page_allocator.destroy(m.k);
        arch.deinit();
    }

    pub fn current(m: *Machine, hart: u32) ?*Thread {
        return m.k.currentThread(hart);
    }

    pub fn check(m: *Machine) !void {
        if (m.k.checkInvariants()) |msg| {
            std.debug.print("invariant violated: {s}\n", .{msg});
            return error.InvariantViolated;
        }
    }

    /// Make a system call as the thread currently running on `hart`.
    /// Returns that thread's registers afterwards (meaningful only if it
    /// did not block).
    pub fn sys(m: *Machine, hart: u32, call: abi.Syscall, a0: u64, a1: u64, args: []const u64) !*Thread {
        const t = m.current(hart) orelse return error.NoCurrentThread;
        t.ctx.set(.a7, @backingInt(call));
        t.ctx.set(.a0, a0);
        t.ctx.set(.a1, a1);
        const regs = [_]core.kernel.Reg{ .a2, .a3, .a4, .a5, .a6 };
        for (regs, 0..) |r, i| t.ctx.set(r, if (i < args.len) args[i] else 0);
        m.k.handle(hart, m.now, .syscall);
        try m.check();
        return t;
    }

    pub fn result(t: *Thread) Result {
        return .{
            .status = @fromBackingInt(@intCast(t.ctx.get(.a0))),
            .tag = @bitCast(t.ctx.get(.a1)),
            .words = .{ t.ctx.get(.a2), t.ctx.get(.a3), t.ctx.get(.a4), t.ctx.get(.a5), t.ctx.get(.a6) },
            .badge = t.ctx.get(.a7),
        };
    }

    pub fn invoke(m: *Machine, hart: u32, cptr: u64, method: anytype, args: []const u64) !Result {
        const t = try m.sys(hart, .invoke, cptr, @backingInt(method), args);
        return result(t);
    }

    /// Advance time; deliver a timer interrupt if the hart's deadline passed.
    pub fn advance(m: *Machine, hart: u32, dt: u64) !void {
        m.now += dt;
        if (arch.timer[hart] <= m.now) {
            m.k.handle(hart, m.now, .timer);
            try m.check();
        }
    }

    pub fn fault(m: *Machine, hart: u32, f: core.kernel.Fault) !void {
        m.k.handle(hart, m.now, .{ .fault = f });
        try m.check();
    }

    pub fn irq(m: *Machine, line: u32) !void {
        m.k.handle(0, m.now, .{ .irq = line });
        try m.check();
    }
};
