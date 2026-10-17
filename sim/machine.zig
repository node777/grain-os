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
    /// The protocol id of the sender's capability (a7 bits 32..47).
    protocol: u16,
    /// The bound signal ended the receive (a7 bit 63); its bits are word 0.
    signalled: bool = false,
};

pub const Machine = struct {
    k: *K,
    now: u64 = 1000,
    root: *Thread,

    pub fn boot(harts: u32, ram_size: usize) !Machine {
        return bootOn(harts, ram_size, arch.platform(harts, ram_size));
    }

    /// Boot on a platform the test changed (from `arch.platform`).
    pub fn bootOn(harts: u32, ram_size: usize, plat: core.fdt.Platform) !Machine {
        const elf_bytes = arch.fakeRootElf();
        return bootWith(harts, ram_size, plat, &elf_bytes, &.{}, .{});
    }

    /// Boot with any root task image and device tree (the fuzzer's way in).
    pub fn bootWith(harts: u32, ram_size: usize, plat: core.fdt.Platform, root_elf: []const u8, dtb: []const u8, measurement: abi.Measurement) !Machine {
        try arch.init(ram_size);
        errdefer arch.deinit();
        const k = try std.heap.page_allocator.create(K);
        errdefer std.heap.page_allocator.destroy(k);
        k.* = .{};
        try k.boot(.{ .platform = &plat, .reserved = &.{}, .root_elf = root_elf, .dtb = dtb, .measurement = measurement, .now = 1000, .root_budget_ticks = 100_000 });
        for (0..harts) |h| k.hartOnline(@intCast(h), 1000);
        return .{ .k = k, .root = k.currentThread(0).? };
    }

    /// Read the root task's memory at `va` (through its page tables).
    pub fn readUser(m: *Machine, va: u64, out: []u8) !void {
        const P = arch.Paging;
        for (out, 0..) |*b, i| {
            const a = va + i;
            var table_pa = m.k.vspaceRoot(m.root) orelse return error.NoVSpace;
            var level: usize = P.levels;
            const pte = while (level > 0) {
                level -= 1;
                const ptes: *const [P.entries]u64 = @ptrFromInt(arch.physToVirt(table_pa));
                const e = ptes[P.index(a, level)];
                if (!P.isValid(e)) return error.NotMapped;
                if (P.isLeaf(e)) break e;
                table_pa = P.address(e);
            } else return error.NotMapped;
            const page = P.address(pte) & ~((@as(u64, 1) << P.levelShift(level)) - 1);
            const off = a & ((@as(u64, 1) << P.levelShift(level)) - 1);
            b.* = @as(*const u8, @ptrFromInt(arch.physToVirt(page + off))).*;
        }
    }

    pub fn deinit(m: *Machine) void {
        std.heap.page_allocator.destroy(m.k);
        arch.deinit();
    }

    pub fn current(m: *const Machine, hart: u32) ?*Thread {
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
            .badge = t.ctx.get(.a7) & 0xffff_ffff,
            .protocol = @truncate(t.ctx.get(.a7) >> 32),
            .signalled = t.ctx.get(.a7) & abi.recv_signalled != 0,
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
