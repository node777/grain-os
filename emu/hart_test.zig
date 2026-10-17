//! The hart's semantics, instruction by instruction: arithmetic corner cases
//! (the RISC-V spec's results for division by zero and overflow), atomics,
//! traps and privilege, Sv39 permissions, interrupts, and code that changes
//! after it has run (the decoded-page cache must notice).
const std = @import("std");
const machine = @import("machine.zig");
const Machine = machine.Machine;
const Hart = machine.Hart;
const expectEqual = std.testing.expectEqual;

fn noConsole(_: ?*anyopaque, _: []const u8) void {}

const base = machine.ram_base;

/// A one-hart machine with `code` at the start of RAM, in S-mode, paging off.
fn setup(code: []const u32) !*Machine {
    const m = try Machine.init(std.testing.allocator, .{ .harts = 1, .ram_mib = 1 }, .{ .console = noConsole });
    for (code, 0..) |w, k| std.mem.writeInt(u32, m.ram[4 * k ..][0..4], w, .little);
    const h = &m.harts[0];
    h.pc = base;
    h.started = true;
    return m;
}

fn steps(m: *Machine, n: usize) void {
    for (0..n) |_| {
        m.harts[0].step(m);
        m.ns += 1;
    }
}

// Encoders (just what the tests use).
fn R(f7: u32, rs2: u32, rs1: u32, f3: u32, rd: u32, op: u32) u32 {
    return f7 << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op;
}
fn I(imm: i32, rs1: u32, f3: u32, rd: u32, op: u32) u32 {
    return @as(u32, @bitCast(imm)) << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op;
}
fn S(imm: i32, rs2: u32, rs1: u32, f3: u32, op: u32) u32 {
    const u: u32 = @bitCast(imm);
    return (u >> 5 & 0x7f) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | (u & 0x1f) << 7 | op;
}
fn amo(f5: u32, rs2: u32, rs1: u32, f3: u32, rd: u32) u32 {
    return f5 << 27 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | 0x2f;
}
const ecall: u32 = 0x00000073;
const sret: u32 = 0x10200073;
fn csrw(csr: u32, rs1: u32) u32 {
    return csr << 20 | rs1 << 15 | 1 << 12 | 0x73;
}

const min64: u64 = 1 << 63;
const all: u64 = std.math.maxInt(u64);

test "division and remainder corner cases" {
    // a0 = min, a1 = -1, a2 = 7, a3 = 0
    const code = [_]u32{
        R(1, 11, 10, 4, 5, 0x33), // div  t0, a0, a1
        R(1, 11, 10, 6, 6, 0x33), // rem  t1, a0, a1
        R(1, 13, 12, 4, 7, 0x33), // div  t2, a2, a3
        R(1, 13, 12, 5, 28, 0x33), // divu t3, a2, a3
        R(1, 13, 12, 6, 29, 0x33), // rem  t4, a2, a3
        R(1, 13, 12, 7, 30, 0x33), // remu t5, a2, a3
        R(1, 11, 14, 4, 31, 0x3b), // divw t6, a4, a1  (a4 = 0x80000000)
        R(1, 13, 12, 5, 15, 0x3b), // divuw a5, a2, a3
        R(1, 11, 14, 6, 16, 0x3b), // remw a6, a4, a1
    };
    const m = try setup(&code);
    defer m.deinit();
    const x = &m.harts[0].x;
    x[10] = min64;
    x[11] = all;
    x[12] = 7;
    x[13] = 0;
    x[14] = 0x8000_0000;
    steps(m, code.len);
    try expectEqual(min64, x[5]);
    try expectEqual(@as(u64, 0), x[6]);
    try expectEqual(all, x[7]);
    try expectEqual(all, x[28]);
    try expectEqual(@as(u64, 7), x[29]);
    try expectEqual(@as(u64, 7), x[30]);
    try expectEqual(@as(u64, 0xffff_ffff_8000_0000), x[31]);
    try expectEqual(all, x[15]);
    try expectEqual(@as(u64, 0), x[16]);
}

test "multiply high, shifts, comparisons, word arithmetic" {
    const code = [_]u32{
        R(1, 10, 10, 1, 5, 0x33), // mulh   t0, a0, a0   (-1 * -1: high 0)
        R(1, 11, 11, 3, 6, 0x33), // mulhu  t1, a1, a1   (max * max: high max-1)
        R(1, 11, 10, 2, 7, 0x33), // mulhsu t2, a0, a1   (-1 * max: high -1)
        R(0x20, 13, 12, 5, 28, 0x3b), // sraw t3, a2, a3 (0x80000000 >> 4)
        R(0, 13, 12, 5, 29, 0x3b), // srlw t4, a2, a3
        I(-1, 14, 3, 30, 0x13), // sltiu t5, a4, -1   (5 < max)
        I(1, 15, 0, 31, 0x1b), // addiw t6, a5, 1     (0x7fffffff + 1 wraps)
        I(-1, 14, 2, 16, 0x13), // slti a6, a4, -1    (5 < -1: no)
    };
    const m = try setup(&code);
    defer m.deinit();
    const x = &m.harts[0].x;
    x[10] = all;
    x[11] = all;
    x[12] = 0x8000_0000;
    x[13] = 4;
    x[14] = 5;
    x[15] = 0x7fff_ffff;
    steps(m, code.len);
    try expectEqual(@as(u64, 0), x[5]);
    try expectEqual(all - 1, x[6]);
    try expectEqual(all, x[7]);
    try expectEqual(@as(u64, 0xffff_ffff_f800_0000), x[28]);
    try expectEqual(@as(u64, 0x0800_0000), x[29]);
    try expectEqual(@as(u64, 1), x[30]);
    try expectEqual(@as(u64, 0xffff_ffff_8000_0000), x[31]);
    try expectEqual(@as(u64, 0), x[16]);
}

test "LR/SC and AMOs" {
    // a0 = address of a word in RAM
    const code = [_]u32{
        amo(0x02, 0, 10, 3, 5), // lr.d t0, (a0)
        amo(0x03, 11, 10, 3, 6), // sc.d t1, a1, (a0)  succeeds: 0
        amo(0x03, 11, 10, 3, 7), // sc.d t2, a1, (a0)  no reservation: 1
        amo(0x00, 12, 10, 2, 28), // amoadd.w t3, a2, (a0)  old sign-extended
        amo(0x1c, 13, 10, 2, 29), // amomaxu.w t4, a3, (a0) unsigned compare
        I(0, 10, 2, 30, 0x03), // lw t5, 0(a0)
    };
    const m = try setup(&code);
    defer m.deinit();
    const x = &m.harts[0].x;
    x[10] = base + 0x800;
    std.mem.writeInt(u64, m.ram[0x800..][0..8], 5, .little);
    x[11] = 0x8000_0000; // after sc: low word 0x80000000
    x[12] = 1;
    x[13] = 0x7fff_ffff;
    steps(m, code.len);
    try expectEqual(@as(u64, 5), x[5]);
    try expectEqual(@as(u64, 0), x[6]);
    try expectEqual(@as(u64, 1), x[7]);
    try expectEqual(@as(u64, 0xffff_ffff_8000_0000), x[28]);
    // 0x80000001 vs 0x7fffffff unsigned: the old value stays
    try expectEqual(@as(u64, 0xffff_ffff_8000_0001), x[29]);
    try expectEqual(@as(u64, 0xffff_ffff_8000_0001), x[30]);
    try expectEqual(@as(u32, 0), m.reservations);
}

test "an ecall from user mode traps to S-mode; sret goes back" {
    const code = [_]u32{
        csrw(0x105, 10), // stvec = a0
        csrw(0x141, 11), // sepc = a1
        sret, // to user mode at a1 (SPP = 0)
        0, // (padding)
        ecall, // at base + 16: user ecall
    };
    const m = try setup(&code);
    defer m.deinit();
    const h = &m.harts[0];
    h.x[10] = base + 0x400;
    h.x[11] = base + 16;
    steps(m, 3);
    try expectEqual(@import("hart.zig").Mode.user, h.mode);
    try expectEqual(base + 16, h.pc);
    steps(m, 1);
    try expectEqual(@import("hart.zig").Mode.supervisor, h.mode);
    try expectEqual(@as(u64, 8), h.scause);
    try expectEqual(base + 16, h.sepc);
    try expectEqual(base + 0x400, h.pc);
}

test "Sv39: user permissions, SUM, and page faults" {
    // Root table at +0x10000, level-1 at +0x11000, level-0 at +0x12000:
    // VA 0x1000 -> PA base+0x20000, user R/W; VA 0x2000 -> PA base+0x21000, user R only.
    const m = try setup(&.{});
    defer m.deinit();
    const root = base + 0x10000;
    const l1 = base + 0x11000;
    const l0 = base + 0x12000;
    const pte = struct {
        fn table(pa: u64) u64 {
            return (pa >> 12) << 10 | 1;
        }
        fn leaf(pa: u64, flags: u64) u64 {
            return (pa >> 12) << 10 | flags | 1 | 64 | 128;
        }
    };
    _ = m.ramStore64(root, pte.table(l1));
    _ = m.ramStore64(l1, pte.table(l0));
    _ = m.ramStore64(l0 + 8, pte.leaf(base + 0x20000, 2 | 4 | 16));
    _ = m.ramStore64(l0 + 16, pte.leaf(base + 0x21000, 2 | 16));
    // Code at PA base (identity: in bare mode first), then paging on.
    const code = [_]u32{
        csrw(0x180, 10), // satp = a0
        I(0, 11, 3, 5, 0x03), // ld t0, 0(a1)       S-mode, U page, SUM=0: load fault
    };
    for (code, 0..) |w, k| std.mem.writeInt(u32, m.ram[4 * k ..][0..4], w, .little);
    const h = &m.harts[0];
    h.x[10] = (8 << 60) | (root >> 12);
    h.x[11] = 0x1000;
    h.stvec = base + 0x400;
    // The code page itself must be mapped once paging is on: map VA base -> PA base
    // as a kernel gigapage in root entry 2.
    _ = m.ramStore64(root + 16, (base >> 12) << 10 | 2 | 4 | 8 | 1 | 64 | 128);
    steps(m, 2);
    try expectEqual(@as(u64, 13), h.scause);
    try expectEqual(@as(u64, 0x1000), h.stval);
    // With SUM the same load works.
    std.mem.writeInt(u64, m.ram[0x20000..][0..8], 0xabcd, .little);
    h.sstatus |= 1 << 18;
    h.updatePerm();
    h.pc = base + 4;
    steps(m, 1);
    try expectEqual(@as(u64, 0xabcd), h.x[5]);
    // A store to the read-only user page faults (15), from S-mode with SUM.
    std.mem.writeInt(u32, m.ram[8..][0..4], S(0, 5, 12, 3, 0x23), .little); // sd t0, 0(a2)
    h.x[12] = 0x2000;
    h.pc = base + 8;
    steps(m, 1);
    try expectEqual(@as(u64, 15), h.scause);
    try expectEqual(@as(u64, 0x2000), h.stval);
    // A non-canonical address faults too.
    h.x[12] = 0x0000_8000_0000_0000;
    h.pc = base + 8;
    steps(m, 1);
    try expectEqual(@as(u64, 15), h.scause);
}

test "a due timer interrupts when enabled, not before" {
    const m = try setup(&[_]u32{ I(0, 0, 0, 0, 0x13), I(0, 0, 0, 0, 0x13), I(0, 0, 0, 0, 0x13), I(0, 0, 0, 0, 0x13) });
    defer m.deinit();
    const h = &m.harts[0];
    h.stvec = base + 0x400;
    h.sie = 1 << 5;
    h.setTimer(0); // due now
    steps(m, 1);
    try expectEqual(base + 4, h.pc); // SIE off in S-mode: masked
    h.sstatus |= 1 << 1;
    h.recheck();
    steps(m, 1);
    try expectEqual(base + 0x400, h.pc);
    try expectEqual((@as(u64, 1) << 63) | 5, h.scause);
}

test "code written after it ran is run as written" {
    // addi a0, zero, 1 ; then overwritten with addi a0, zero, 2 by a store.
    const code = [_]u32{
        I(1, 0, 0, 10, 0x13), // addi a0, zero, 1
        S(0, 12, 11, 2, 0x23), // sw a2, 0(a1)    overwrites the first instruction
        I(0, 0, 0, 0, 0x13),
    };
    const m = try setup(&code);
    defer m.deinit();
    const h = &m.harts[0];
    h.x[11] = base;
    h.x[12] = I(2, 0, 0, 10, 0x13);
    steps(m, 2);
    try expectEqual(@as(u64, 1), h.x[10]);
    h.pc = base;
    steps(m, 1);
    try expectEqual(@as(u64, 2), h.x[10]);
}

test "compressed instructions run" {
    // c.li a0, 5 ; c.addi a0, -1 ; c.mv a1, a0
    const words = [_]u16{ 0x4515, 0x157d, 0x85aa };
    const m = try setup(&.{});
    defer m.deinit();
    for (words, 0..) |w, k| std.mem.writeInt(u16, m.ram[2 * k ..][0..2], w, .little);
    steps(m, 3);
    try expectEqual(@as(u64, 4), m.harts[0].x[10]);
    try expectEqual(@as(u64, 4), m.harts[0].x[11]);
    try expectEqual(base + 6, m.harts[0].pc);
}
