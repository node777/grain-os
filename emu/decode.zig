//! RV64IMAC instruction decoding (plus Zicsr, Zifencei and the privileged
//! instructions an S-mode kernel uses). Both 32-bit and compressed (RVC)
//! instructions decode to one form, `Inst`, which the hart executes; there
//! is no re-encoding of compressed instructions.
const std = @import("std");

pub const Op = enum(u8) {
    /// Not decoded yet (an empty slot in a decoded-page cache); never
    /// returned by the decoders.
    none,
    illegal,
    lui,
    auipc,
    jal,
    jalr,
    beq,
    bne,
    blt,
    bge,
    bltu,
    bgeu,
    lb,
    lh,
    lw,
    ld,
    lbu,
    lhu,
    lwu,
    sb,
    sh,
    sw,
    sd,
    addi,
    slti,
    sltiu,
    xori,
    ori,
    andi,
    slli,
    srli,
    srai,
    addiw,
    slliw,
    srliw,
    sraiw,
    add,
    sub,
    sll,
    slt,
    sltu,
    xor,
    srl,
    sra,
    @"or",
    @"and",
    addw,
    subw,
    sllw,
    srlw,
    sraw,
    mul,
    mulh,
    mulhsu,
    mulhu,
    div,
    divu,
    rem,
    remu,
    mulw,
    divw,
    divuw,
    remw,
    remuw,
    fence,
    /// FENCE with the Zihintpause encoding: a spin-wait hint.
    pause,
    fence_i,
    ecall,
    ebreak,
    sret,
    wfi,
    sfence_vma,
    csrrw,
    csrrs,
    csrrc,
    csrrwi,
    csrrsi,
    csrrci,
    lr,
    sc,
    amoswap,
    amoadd,
    amoxor,
    amoand,
    amoor,
    amomin,
    amomax,
    amominu,
    amomaxu,
};

pub const Inst = struct {
    op: Op,
    rd: u5 = 0,
    rs1: u5 = 0,
    rs2: u5 = 0,
    /// Sign-extended immediate (every RV64 immediate fits in 32 bits); the
    /// CSR number for CSR instructions.
    imm: i32 = 0,
    /// Instruction length in bytes: 2 or 4.
    len: u8 = 4,
    /// Atomics: a word (32-bit) operation, else a doubleword.
    word: bool = false,
};

const illegal: Inst = .{ .op = .illegal };

/// Instruction length from its low 16 bits.
pub fn length(low: u16) u8 {
    return if (low & 3 == 3) 4 else 2;
}

fn bits(x: u32, hi: u5, lo: u5) u32 {
    return (x >> lo) & ((@as(u32, 1) << (hi - lo + 1)) - 1);
}

fn sext(x: u64, width: u7) i32 {
    const shift: u6 = @intCast(64 - width);
    return @intCast(@as(i64, @bitCast(x << shift)) >> shift);
}

pub fn decode32(x: u32) Inst {
    const opcode = x & 0x7f;
    const rd: u5 = @intCast(bits(x, 11, 7));
    const rs1: u5 = @intCast(bits(x, 19, 15));
    const rs2: u5 = @intCast(bits(x, 24, 20));
    const f3 = bits(x, 14, 12);
    const f7 = bits(x, 31, 25);
    const imm_i = sext(x >> 20, 12);
    const imm_s = sext((bits(x, 31, 25) << 5) | bits(x, 11, 7), 12);
    const imm_b = sext((bits(x, 31, 31) << 12) | (bits(x, 7, 7) << 11) | (bits(x, 30, 25) << 5) | (bits(x, 11, 8) << 1), 13);
    const imm_u = sext(x & 0xffff_f000, 32);
    const imm_j = sext((bits(x, 31, 31) << 20) | (bits(x, 19, 12) << 12) | (bits(x, 20, 20) << 11) | (bits(x, 30, 21) << 1), 21);
    const r: Inst = .{ .op = .illegal, .rd = rd, .rs1 = rs1, .rs2 = rs2 };
    return switch (opcode) {
        0x37 => .{ .op = .lui, .rd = rd, .imm = imm_u },
        0x17 => .{ .op = .auipc, .rd = rd, .imm = imm_u },
        0x6f => .{ .op = .jal, .rd = rd, .imm = imm_j },
        0x67 => if (f3 == 0) .{ .op = .jalr, .rd = rd, .rs1 = rs1, .imm = imm_i } else illegal,
        0x63 => .{ .op = switch (f3) {
            0 => .beq,
            1 => .bne,
            4 => .blt,
            5 => .bge,
            6 => .bltu,
            7 => .bgeu,
            else => return illegal,
        }, .rs1 = rs1, .rs2 = rs2, .imm = imm_b },
        0x03 => .{ .op = switch (f3) {
            0 => .lb,
            1 => .lh,
            2 => .lw,
            3 => .ld,
            4 => .lbu,
            5 => .lhu,
            6 => .lwu,
            else => return illegal,
        }, .rd = rd, .rs1 = rs1, .imm = imm_i },
        0x23 => .{ .op = switch (f3) {
            0 => .sb,
            1 => .sh,
            2 => .sw,
            3 => .sd,
            else => return illegal,
        }, .rs1 = rs1, .rs2 = rs2, .imm = imm_s },
        0x13 => switch (f3) {
            0 => .{ .op = .addi, .rd = rd, .rs1 = rs1, .imm = imm_i },
            2 => .{ .op = .slti, .rd = rd, .rs1 = rs1, .imm = imm_i },
            3 => .{ .op = .sltiu, .rd = rd, .rs1 = rs1, .imm = imm_i },
            4 => .{ .op = .xori, .rd = rd, .rs1 = rs1, .imm = imm_i },
            6 => .{ .op = .ori, .rd = rd, .rs1 = rs1, .imm = imm_i },
            7 => .{ .op = .andi, .rd = rd, .rs1 = rs1, .imm = imm_i },
            1 => if (bits(x, 31, 26) == 0) .{ .op = .slli, .rd = rd, .rs1 = rs1, .imm = @intCast(bits(x, 25, 20)) } else illegal,
            5 => switch (bits(x, 31, 26)) {
                0x00 => .{ .op = .srli, .rd = rd, .rs1 = rs1, .imm = @intCast(bits(x, 25, 20)) },
                0x10 => .{ .op = .srai, .rd = rd, .rs1 = rs1, .imm = @intCast(bits(x, 25, 20)) },
                else => illegal,
            },
            else => illegal,
        },
        0x1b => switch (f3) {
            0 => .{ .op = .addiw, .rd = rd, .rs1 = rs1, .imm = imm_i },
            1 => if (f7 == 0) .{ .op = .slliw, .rd = rd, .rs1 = rs1, .imm = rs2 } else illegal,
            5 => switch (f7) {
                0x00 => .{ .op = .srliw, .rd = rd, .rs1 = rs1, .imm = rs2 },
                0x20 => .{ .op = .sraiw, .rd = rd, .rs1 = rs1, .imm = rs2 },
                else => illegal,
            },
            else => illegal,
        },
        0x33 => blk: {
            var o = r;
            o.op = switch (f7) {
                0x00 => switch (f3) {
                    0 => .add,
                    1 => .sll,
                    2 => .slt,
                    3 => .sltu,
                    4 => .xor,
                    5 => .srl,
                    6 => .@"or",
                    7 => .@"and",
                    else => unreachable,
                },
                0x20 => switch (f3) {
                    0 => .sub,
                    5 => .sra,
                    else => break :blk illegal,
                },
                0x01 => switch (f3) {
                    0 => .mul,
                    1 => .mulh,
                    2 => .mulhsu,
                    3 => .mulhu,
                    4 => .div,
                    5 => .divu,
                    6 => .rem,
                    7 => .remu,
                    else => unreachable,
                },
                else => break :blk illegal,
            };
            break :blk o;
        },
        0x3b => blk: {
            var o = r;
            o.op = switch (f7) {
                0x00 => switch (f3) {
                    0 => .addw,
                    1 => .sllw,
                    5 => .srlw,
                    else => break :blk illegal,
                },
                0x20 => switch (f3) {
                    0 => .subw,
                    5 => .sraw,
                    else => break :blk illegal,
                },
                0x01 => switch (f3) {
                    0 => .mulw,
                    4 => .divw,
                    5 => .divuw,
                    6 => .remw,
                    7 => .remuw,
                    else => break :blk illegal,
                },
                else => break :blk illegal,
            };
            break :blk o;
        },
        0x0f => switch (f3) {
            0 => if (x == 0x0100000f) .{ .op = .pause } else .{ .op = .fence },
            1 => .{ .op = .fence_i },
            else => illegal,
        },
        0x73 => switch (f3) {
            0 => if (x == 0x00000073)
                .{ .op = .ecall }
            else if (x == 0x00100073)
                .{ .op = .ebreak }
            else if (x == 0x10200073)
                .{ .op = .sret }
            else if (x == 0x10500073)
                .{ .op = .wfi }
            else if (f7 == 0x09 and rd == 0)
                .{ .op = .sfence_vma, .rs1 = rs1, .rs2 = rs2 }
            else
                illegal,
            1 => .{ .op = .csrrw, .rd = rd, .rs1 = rs1, .imm = @intCast(x >> 20) },
            2 => .{ .op = .csrrs, .rd = rd, .rs1 = rs1, .imm = @intCast(x >> 20) },
            3 => .{ .op = .csrrc, .rd = rd, .rs1 = rs1, .imm = @intCast(x >> 20) },
            5 => .{ .op = .csrrwi, .rd = rd, .rs1 = rs1, .imm = @intCast(x >> 20) },
            6 => .{ .op = .csrrsi, .rd = rd, .rs1 = rs1, .imm = @intCast(x >> 20) },
            7 => .{ .op = .csrrci, .rd = rd, .rs1 = rs1, .imm = @intCast(x >> 20) },
            else => illegal,
        },
        0x2f => blk: {
            if (f3 != 2 and f3 != 3) break :blk illegal;
            var o = r;
            o.word = f3 == 2;
            o.op = switch (bits(x, 31, 27)) {
                0x02 => if (rs2 == 0) .lr else break :blk illegal,
                0x03 => .sc,
                0x01 => .amoswap,
                0x00 => .amoadd,
                0x04 => .amoxor,
                0x0c => .amoand,
                0x08 => .amoor,
                0x10 => .amomin,
                0x14 => .amomax,
                0x18 => .amominu,
                0x1c => .amomaxu,
                else => break :blk illegal,
            };
            break :blk o;
        },
        else => illegal,
    };
}

/// Decode a compressed instruction (low two bits not 0b11).
pub fn decode16(c16: u16) Inst {
    const c: u32 = c16;
    const quadrant = c & 3;
    const f3 = bits(c, 15, 13);
    const rdp: u5 = @intCast(bits(c, 4, 2) + 8); // rd' / rs2'
    const rs1p: u5 = @intCast(bits(c, 9, 7) + 8); // rs1' / rd'
    const rd: u5 = @intCast(bits(c, 11, 7));
    const rs2: u5 = @intCast(bits(c, 6, 2));
    // CI-format 6-bit immediate: imm[5] = bit 12, imm[4:0] = bits 6:2.
    const ci = sext((bits(c, 12, 12) << 5) | bits(c, 6, 2), 6);
    var i: Inst = switch (quadrant) {
        0 => switch (f3) {
            0 => blk: {
                const nzuimm = (bits(c, 12, 11) << 4) | (bits(c, 10, 7) << 6) | (bits(c, 6, 6) << 2) | (bits(c, 5, 5) << 3);
                if (nzuimm == 0) break :blk illegal;
                break :blk .{ .op = .addi, .rd = rdp, .rs1 = 2, .imm = @intCast(nzuimm) };
            },
            2 => .{ .op = .lw, .rd = rdp, .rs1 = rs1p, .imm = @intCast((bits(c, 12, 10) << 3) | (bits(c, 6, 6) << 2) | (bits(c, 5, 5) << 6)) },
            3 => .{ .op = .ld, .rd = rdp, .rs1 = rs1p, .imm = @intCast((bits(c, 12, 10) << 3) | (bits(c, 6, 5) << 6)) },
            6 => .{ .op = .sw, .rs1 = rs1p, .rs2 = rdp, .imm = @intCast((bits(c, 12, 10) << 3) | (bits(c, 6, 6) << 2) | (bits(c, 5, 5) << 6)) },
            7 => .{ .op = .sd, .rs1 = rs1p, .rs2 = rdp, .imm = @intCast((bits(c, 12, 10) << 3) | (bits(c, 6, 5) << 6)) },
            else => illegal, // floating point, reserved
        },
        1 => switch (f3) {
            0 => .{ .op = .addi, .rd = rd, .rs1 = rd, .imm = ci },
            1 => if (rd != 0) .{ .op = .addiw, .rd = rd, .rs1 = rd, .imm = ci } else illegal,
            2 => .{ .op = .addi, .rd = rd, .rs1 = 0, .imm = ci },
            3 => if (rd == 2) blk: {
                const nz = sext((bits(c, 12, 12) << 9) | (bits(c, 6, 6) << 4) | (bits(c, 5, 5) << 6) | (bits(c, 4, 3) << 7) | (bits(c, 2, 2) << 5), 10);
                if (nz == 0) break :blk illegal;
                break :blk .{ .op = .addi, .rd = 2, .rs1 = 2, .imm = nz };
            } else blk: {
                const nz = sext((bits(c, 12, 12) << 17) | (bits(c, 6, 2) << 12), 18);
                if (nz == 0 or rd == 0) break :blk illegal;
                break :blk .{ .op = .lui, .rd = rd, .imm = nz };
            },
            4 => switch (bits(c, 11, 10)) {
                0 => .{ .op = .srli, .rd = rs1p, .rs1 = rs1p, .imm = @intCast((bits(c, 12, 12) << 5) | bits(c, 6, 2)) },
                1 => .{ .op = .srai, .rd = rs1p, .rs1 = rs1p, .imm = @intCast((bits(c, 12, 12) << 5) | bits(c, 6, 2)) },
                2 => .{ .op = .andi, .rd = rs1p, .rs1 = rs1p, .imm = ci },
                3 => blk: {
                    const op: Op = if (bits(c, 12, 12) == 0) switch (bits(c, 6, 5)) {
                        0 => .sub,
                        1 => .xor,
                        2 => .@"or",
                        3 => .@"and",
                        else => unreachable,
                    } else switch (bits(c, 6, 5)) {
                        0 => .subw,
                        1 => .addw,
                        else => break :blk illegal,
                    };
                    break :blk .{ .op = op, .rd = rs1p, .rs1 = rs1p, .rs2 = rdp };
                },
                else => unreachable,
            },
            5 => .{ .op = .jal, .rd = 0, .imm = cjImm(c) },
            6, 7 => .{
                .op = if (f3 == 6) .beq else .bne,
                .rs1 = rs1p,
                .rs2 = 0,
                .imm = sext((bits(c, 12, 12) << 8) | (bits(c, 11, 10) << 3) | (bits(c, 6, 5) << 6) | (bits(c, 4, 3) << 1) | (bits(c, 2, 2) << 5), 9),
            },
            else => unreachable,
        },
        2 => switch (f3) {
            0 => .{ .op = .slli, .rd = rd, .rs1 = rd, .imm = @intCast((bits(c, 12, 12) << 5) | bits(c, 6, 2)) },
            2 => if (rd != 0) .{ .op = .lw, .rd = rd, .rs1 = 2, .imm = @intCast((bits(c, 12, 12) << 5) | (bits(c, 6, 4) << 2) | (bits(c, 3, 2) << 6)) } else illegal,
            3 => if (rd != 0) .{ .op = .ld, .rd = rd, .rs1 = 2, .imm = @intCast((bits(c, 12, 12) << 5) | (bits(c, 6, 5) << 3) | (bits(c, 4, 2) << 6)) } else illegal,
            4 => if (bits(c, 12, 12) == 0)
                (if (rs2 == 0)
                    (if (rd != 0) Inst{ .op = .jalr, .rd = 0, .rs1 = rd, .imm = 0 } else illegal)
                else
                    Inst{ .op = .add, .rd = rd, .rs1 = 0, .rs2 = rs2 })
            else if (rs2 == 0)
                (if (rd == 0) Inst{ .op = .ebreak } else Inst{ .op = .jalr, .rd = 1, .rs1 = rd, .imm = 0 })
            else
                Inst{ .op = .add, .rd = rd, .rs1 = rd, .rs2 = rs2 },
            6 => .{ .op = .sw, .rs1 = 2, .rs2 = rs2, .imm = @intCast((bits(c, 12, 9) << 2) | (bits(c, 8, 7) << 6)) },
            7 => .{ .op = .sd, .rs1 = 2, .rs2 = rs2, .imm = @intCast((bits(c, 12, 10) << 3) | (bits(c, 9, 7) << 6)) },
            else => illegal, // floating point
        },
        else => unreachable,
    };
    i.len = 2;
    return i;
}

fn cjImm(c: u32) i32 {
    const v = (bits(c, 12, 12) << 11) | (bits(c, 11, 11) << 4) | (bits(c, 10, 9) << 8) | (bits(c, 8, 8) << 10) |
        (bits(c, 7, 7) << 6) | (bits(c, 6, 6) << 7) | (bits(c, 5, 3) << 1) | (bits(c, 2, 2) << 5);
    return sext(v, 12);
}

test "32-bit encodings" {
    const t = std.testing;
    // addi a0, a0, -1
    try t.expectEqual(Inst{ .op = .addi, .rd = 10, .rs1 = 10, .imm = -1 }, decode32(0xfff50513));
    // lui t0, 0x80000 (sign-extends on RV64)
    try t.expectEqual(@as(i32, -0x8000_0000), decode32(0x800002b7).imm);
    // jal ra, -8
    const j = decode32(0xff9ff0ef);
    try t.expectEqual(Op.jal, j.op);
    try t.expectEqual(@as(i32, -8), j.imm);
    // beq a0, a1, 16
    const b = decode32(0x00b50863);
    try t.expectEqual(Op.beq, b.op);
    try t.expectEqual(@as(i32, 16), b.imm);
    // sd ra, 8(sp)
    const s = decode32(0x00113423);
    try t.expectEqual(Op.sd, s.op);
    try t.expectEqual(@as(i32, 8), s.imm);
    // srai a0, a0, 63
    try t.expectEqual(Inst{ .op = .srai, .rd = 10, .rs1 = 10, .imm = 63 }, decode32(0x43f55513));
    // csrrw zero, satp, t1
    try t.expectEqual(Inst{ .op = .csrrw, .rd = 0, .rs1 = 6, .imm = 0x180 }, decode32(0x18031073));
    // amoswap.w.aq a0, a1, (a2)
    const a = decode32(0x0cb6252f);
    try t.expectEqual(Op.amoswap, a.op);
    try t.expect(a.word);
    try t.expectEqual(Op.sret, decode32(0x10200073).op);
    try t.expectEqual(Op.pause, decode32(0x0100000f).op);
    try t.expectEqual(Op.sfence_vma, decode32(0x12000073).op);
}

test "compressed encodings" {
    const t = std.testing;
    // c.addi16sp sp, -64  (0x7139)
    try t.expectEqual(Inst{ .op = .addi, .rd = 2, .rs1 = 2, .imm = -64, .len = 2 }, decode16(0x7139));
    // c.sdsp ra, 56(sp)  (0xfc06)
    try t.expectEqual(Inst{ .op = .sd, .rs1 = 2, .rs2 = 1, .imm = 56, .len = 2 }, decode16(0xfc06));
    // c.ldsp ra, 56(sp)  (0x70e2)
    try t.expectEqual(Inst{ .op = .ld, .rd = 1, .rs1 = 2, .imm = 56, .len = 2 }, decode16(0x70e2));
    // c.li a0, -1  (0x557d)
    try t.expectEqual(Inst{ .op = .addi, .rd = 10, .rs1 = 0, .imm = -1, .len = 2 }, decode16(0x557d));
    // c.mv a0, a1 (0x852e)
    try t.expectEqual(Inst{ .op = .add, .rd = 10, .rs1 = 0, .rs2 = 11, .len = 2 }, decode16(0x852e));
    // c.ret = c.jr ra (0x8082)
    try t.expectEqual(Inst{ .op = .jalr, .rd = 0, .rs1 = 1, .len = 2 }, decode16(0x8082));
    // c.j -2 (0xbffd)
    try t.expectEqual(@as(i32, -2), decode16(0xbffd).imm);
    // c.beqz a0, 8 (0xc501)
    const b = decode16(0xc501);
    try t.expectEqual(Op.beq, b.op);
    try t.expectEqual(@as(i32, 8), b.imm);
    // c.lw a5, 4(a0) (0x415c)
    try t.expectEqual(Inst{ .op = .lw, .rd = 15, .rs1 = 10, .imm = 4, .len = 2 }, decode16(0x415c));
    // c.lui a0, 0x1 (0x6505)
    try t.expectEqual(Inst{ .op = .lui, .rd = 10, .imm = 0x1000, .len = 2 }, decode16(0x6505));
    // c.addi4spn a0, sp, 16 (0x0808)
    try t.expectEqual(Inst{ .op = .addi, .rd = 10, .rs1 = 2, .imm = 16, .len = 2 }, decode16(0x0808));
    try t.expectEqual(Op.ebreak, decode16(0x9002).op);
    try t.expectEqual(Op.illegal, decode16(0x0000).op);
}
