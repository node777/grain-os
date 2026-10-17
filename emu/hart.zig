//! One RISC-V hart: RV64IMAC in U and S mode, Zicsr, Zifencei, Sv39 with a
//! small software TLB. M-mode does not exist here: the machine implements
//! SBI itself, so an `ecall` from S-mode is handled by `Machine.sbi`.
//!
//! Memory accesses go through the machine (`Machine.load`/`store`), which
//! routes RAM and device registers. Misaligned loads and stores work (as on
//! QEMU); misaligned atomics trap.
const std = @import("std");
const decode = @import("decode.zig");
const Machine = @import("machine.zig").Machine;
const CodePage = @import("machine.zig").CodePage;

pub const Mode = enum(u1) { user = 0, supervisor = 1 };

pub const Cause = struct {
    pub const misaligned_fetch = 0;
    pub const fetch_access = 1;
    pub const illegal = 2;
    pub const breakpoint = 3;
    pub const misaligned_load = 4;
    pub const load_access = 5;
    pub const misaligned_store = 6;
    pub const store_access = 7;
    pub const ecall_u = 8;
    pub const ecall_s = 9;
    pub const fetch_page = 12;
    pub const load_page = 13;
    pub const store_page = 15;
    pub const interrupt: u64 = 1 << 63;
};

pub const Exception = error{Exception};

const Access = enum { fetch, load, store };

// sstatus bits
const sie_bit: u64 = 1 << 1;
const spie_bit: u64 = 1 << 5;
const spp_bit: u64 = 1 << 8;
const sum_bit: u64 = 1 << 18;
const mxr_bit: u64 = 1 << 19;
const sstatus_writable: u64 = sie_bit | spie_bit | spp_bit | sum_bit | mxr_bit;
/// UXL = 2 (64-bit user mode), read-only.
const sstatus_fixed: u64 = 2 << 32;

pub const ssip: u64 = 1 << 1;
pub const stip: u64 = 1 << 5;
pub const seip: u64 = 1 << 9;
const sie_writable: u64 = ssip | stip | seip;

const tlb_size = 256;

const TlbEntry = struct {
    /// Virtual page number + 1 (0 = empty).
    tag: u64 = 0,
    /// Physical page base.
    page: u64 = 0,
    /// The page in host memory, if it is RAM (else accesses go to devices).
    host: ?[*]u8 = null,
    /// Which accesses are allowed, for each combination of mode, SUM and
    /// MXR: bit 3 * permIndex() + (0 fetch, 1 load, 2 store). Stores are
    /// only allowed once D is set (else the walk sets it).
    allow: u32 = 0,
};

fn accessBit(acc: Access) u5 {
    return switch (acc) {
        .fetch => 0,
        .load => 1,
        .store => 2,
    };
}

pub const Hart = struct {
    id: u32,
    x: [32]u64 = @splat(0),
    pc: u64 = 0,
    mode: Mode = .supervisor,
    started: bool = false,
    /// In WFI: skipped until an interrupt is pending.
    waiting: bool = false,
    /// End this hart's time slice (WFI, pause).
    yield: bool = false,

    sstatus: u64 = 0,
    sie: u64 = 0,
    /// Software-writable pending bits (SSIP); STIP and SEIP are computed.
    sip: u64 = 0,
    stvec: u64 = 0,
    sscratch: u64 = 0,
    sepc: u64 = 0,
    scause: u64 = 0,
    stval: u64 = 0,
    satp: u64 = 0,
    scounteren: u64 = 0,
    /// SBI set_timer deadline (time CSR units).
    timer: u64 = std.math.maxInt(u64),
    instret: u64 = 0,

    /// The timer deadline in virtual nanoseconds, and whether it has been
    /// seen due (then it is pending until set again).
    timer_ns: u64 = std.math.maxInt(u64),
    timer_seen: bool = false,
    /// From this virtual time on, look at interrupts before each instruction
    /// (0: something that decides them changed; else the timer deadline).
    next_event: u64 = 0,
    /// 3 * permIndex(): where this mode's bits start in a TLB entry's `allow`.
    perm_shift: u5 = 12,

    /// The page instructions are being fetched from: virtual page number,
    /// its host memory and its decoded instructions (one slot per halfword).
    /// While the pc stays on it, a fetch is an array index.
    fetch_vpn: u64 = std.math.maxInt(u64),
    fetch_base: [*]u8 = undefined,
    fetch_code: *CodePage = undefined,
    /// An instruction split across two pages is decoded here each time.
    split: decode.Inst = .{ .op = .none },

    /// LR/SC reservation (physical address), if any.
    reservation: ?u64 = null,

    exc_cause: u64 = 0,
    exc_tval: u64 = 0,

    tlb: [tlb_size]TlbEntry = @splat(.{}),

    pub fn flushTlb(h: *Hart) void {
        for (&h.tlb) |*e| e.tag = 0;
        h.fetch_vpn = std.math.maxInt(u64);
    }

    pub fn setTimer(h: *Hart, deadline: u64) void {
        h.timer = deadline;
        h.timer_ns = deadline *| (1_000_000_000 / @import("machine.zig").timebase_hz);
        h.timer_seen = false;
        h.recheck();
    }

    /// Something that decides interrupts changed: look before the next instruction.
    pub inline fn recheck(h: *Hart) void {
        h.next_event = 0;
    }

    /// The mode or sstatus changed: recompute where permissions are looked up.
    pub fn updatePerm(h: *Hart) void {
        h.perm_shift = 3 * h.permIndex();
    }

    fn permIndex(h: *const Hart) u5 {
        return @intCast(@as(u32, @intFromEnum(h.mode)) * 4 + @as(u32, @intFromBool(h.sstatus & sum_bit != 0)) * 2 + @intFromBool(h.sstatus & mxr_bit != 0));
    }

    fn raise(h: *Hart, cause: u64, tval: u64) Exception {
        h.exc_cause = cause;
        h.exc_tval = tval;
        return error.Exception;
    }

    /// Take a trap into S-mode.
    pub fn trap(h: *Hart, cause: u64, tval: u64) void {
        h.sepc = h.pc;
        h.scause = cause;
        h.stval = tval;
        var s = h.sstatus;
        s = if (h.mode == .supervisor) s | spp_bit else s & ~spp_bit;
        s = if (s & sie_bit != 0) s | spie_bit else s & ~spie_bit;
        s &= ~sie_bit;
        h.sstatus = s;
        h.mode = .supervisor;
        h.updatePerm();
        h.fetch_vpn = std.math.maxInt(u64);
        const base = h.stvec & ~@as(u64, 3);
        h.pc = if (h.stvec & 3 == 1 and cause & Cause.interrupt != 0) base + 4 * (cause & 0xff) else base;
    }

    /// Interrupts pending and enabled at the moment, as sip bits.
    pub fn pendingInterrupts(h: *const Hart, m: *const Machine) u64 {
        var p = h.sip;
        if (m.timeNow() >= h.timer) p |= stip;
        if (m.plic.pendingFor(h.id)) p |= seip;
        return p & h.sie;
    }

    /// Take an interrupt if one is pending and enabled; returns whether it did.
    pub fn checkInterrupts(h: *Hart, m: *const Machine) bool {
        if (m.ns >= h.timer_ns) h.timer_seen = true;
        h.next_event = if (h.timer_seen) std.math.maxInt(u64) else h.timer_ns;
        const p = h.pendingInterrupts(m);
        if (p == 0) return false;
        h.waiting = false;
        if (h.mode == .supervisor and h.sstatus & sie_bit == 0) return false;
        const cause: u64 = if (p & seip != 0) 9 else if (p & ssip != 0) 1 else 5;
        h.trap(Cause.interrupt | cause, 0);
        return true;
    }

    // -----------------------------------------------------------------
    // Address translation

    fn translate(h: *Hart, m: *Machine, va: u64, acc: Access) Exception!u64 {
        if (h.satp >> 60 != 8) return va;
        const fault: u64 = switch (acc) {
            .fetch => Cause.fetch_page,
            .load => Cause.load_page,
            .store => Cause.store_page,
        };
        // Bits 63..39 must copy bit 38.
        const top = @as(i64, @bitCast(va)) >> 38;
        if (top != 0 and top != -1) return h.raise(fault, va);
        const vpn = (va >> 12) & ((1 << 27) - 1);
        const e = &h.tlb[vpn % tlb_size];
        const bit: u5 = h.perm_shift + accessBit(acc);
        if (e.tag == vpn + 1 and (e.allow >> bit) & 1 != 0) return e.page | (va & 0xfff);
        var table = (h.satp & ((1 << 44) - 1)) << 12;
        var level: u6 = 3;
        while (level > 0) {
            level -= 1;
            const pte_addr = table + ((va >> (12 + 9 * level)) & 0x1ff) * 8;
            var pte = m.ramLoad64(pte_addr) orelse return h.raise(switch (acc) {
                .fetch => Cause.fetch_access,
                .load => Cause.load_access,
                .store => Cause.store_access,
            }, va);
            const v = pte & 1 != 0;
            const r = pte & 2 != 0;
            const w = pte & 4 != 0;
            const x = pte & 8 != 0;
            const u = pte & 16 != 0;
            if (!v or (!r and w)) return h.raise(fault, va);
            const ppn = (pte >> 10) & ((1 << 44) - 1);
            if (!r and !x) {
                table = ppn << 12;
                continue;
            }
            if (!h.permitted(acc, r, w, x, u)) return h.raise(fault, va);
            // A superpage's lower PPN bits must be zero.
            const low_mask = (@as(u64, 1) << (9 * level)) - 1;
            if (ppn & low_mask != 0) return h.raise(fault, va);
            // Hardware A/D updates (as QEMU does).
            const want: u64 = 64 | (if (acc == .store) @as(u64, 128) else 0);
            if (pte & want != want) {
                pte |= want;
                _ = m.ramStore64(pte_addr, pte);
            }
            const page = ((ppn | ((va >> 12) & low_mask)) << 12);
            var allow: u32 = 0;
            for (0..8) |idx| {
                const pm: Mode = if (idx >= 4) .supervisor else .user;
                const sum = idx & 2 != 0;
                const mxr = idx & 1 != 0;
                if (permittedIn(.fetch, pm, sum, mxr, r, w, x, u)) allow |= @as(u32, 1) << @intCast(3 * idx);
                if (permittedIn(.load, pm, sum, mxr, r, w, x, u)) allow |= @as(u32, 2) << @intCast(3 * idx);
                if (pte & 128 != 0 and permittedIn(.store, pm, sum, mxr, r, w, x, u)) allow |= @as(u32, 4) << @intCast(3 * idx);
            }
            e.* = .{ .tag = vpn + 1, .page = page, .host = m.ramPage(page), .allow = allow };
            return page | (va & 0xfff);
        }
        return h.raise(fault, va);
    }

    fn permitted(h: *const Hart, acc: Access, r: bool, w: bool, x: bool, u: bool) bool {
        return permittedIn(acc, h.mode, h.sstatus & sum_bit != 0, h.sstatus & mxr_bit != 0, r, w, x, u);
    }

    // -----------------------------------------------------------------
    // Memory

    /// The TLB entry for `size` bytes at `va`, if it has the page, allows
    /// the access, the page is RAM and the bytes stay on it (the common case).
    inline fn fast(h: *Hart, va: u64, size: u8, comptime acc: Access) ?*TlbEntry {
        if (h.satp >> 60 != 8) return null;
        if ((va & 0xfff) + size > 0x1000) return null;
        const vpn = (va >> 12) & ((1 << 27) - 1);
        const e = &h.tlb[vpn % tlb_size];
        if (e.tag != vpn + 1 or (e.allow >> (h.perm_shift + comptime accessBit(acc))) & 1 == 0) return null;
        if (e.host == null) return null;
        return e;
    }

    inline fn loadFast(h: *Hart, m: *Machine, va: u64, comptime T: type) Exception!u64 {
        if (h.fast(va, @sizeOf(T), .load)) |e| return std.mem.readInt(T, (e.host.? + (va & 0xfff))[0..@sizeOf(T)], .little);
        return h.load(m, va, @sizeOf(T));
    }

    inline fn storeFast(h: *Hart, m: *Machine, va: u64, comptime T: type, v: u64) Exception!void {
        if (m.reservations == 0) if (h.fast(va, @sizeOf(T), .store)) |e| {
            std.mem.writeInt(T, (e.host.? + (va & 0xfff))[0..@sizeOf(T)], @truncate(v), .little);
            m.wroteRam(e.page);
            return;
        };
        return h.store(m, va, @sizeOf(T), v);
    }

    fn load(h: *Hart, m: *Machine, va: u64, size: u8) Exception!u64 {
        if (va & (size - 1) != 0 and (va & 0xfff) + size > 0x1000) {
            // Misaligned across a page: a byte at a time.
            var v: u64 = 0;
            for (0..size) |i| v |= try h.load(m, va + i, 1) << @intCast(8 * i);
            return v;
        }
        const pa = try h.translate(m, va, .load);
        return m.load(pa, size) orelse h.raise(Cause.load_access, va);
    }

    fn store(h: *Hart, m: *Machine, va: u64, size: u8, value: u64) Exception!void {
        if (va & (size - 1) != 0 and (va & 0xfff) + size > 0x1000) {
            for (0..size) |i| try h.store(m, va + i, 1, value >> @intCast(8 * i));
            return;
        }
        const pa = try h.translate(m, va, .store);
        if (!m.store(pa, size, value)) return h.raise(Cause.store_access, va);
    }

    inline fn fetch(h: *Hart, m: *Machine) Exception!*const decode.Inst {
        const pc = h.pc;
        if (pc >> 12 == h.fetch_vpn) {
            const slot = &h.fetch_code[(pc & 0xfff) >> 1];
            if (slot.op != .none) return slot;
        }
        return h.fetchSlow(m);
    }

    fn fetchSlow(h: *Hart, m: *Machine) Exception!*const decode.Inst {
        const pc = h.pc;
        const off = pc & 0xfff;
        if (pc & 1 != 0) return h.raise(Cause.misaligned_fetch, pc);
        if (pc >> 12 != h.fetch_vpn) {
            const pa = try h.translate(m, pc, .fetch);
            const page = pa & ~@as(u64, 0xfff);
            const host = m.ramPage(page) orelse return h.raise(Cause.fetch_access, pc);
            // Fetch from this page through its decoded slots until something changes.
            h.fetch_vpn = pc >> 12;
            h.fetch_base = host;
            h.fetch_code = (m.codePage(page) catch null) orelse return h.raise(Cause.fetch_access, pc);
        }
        const low = std.mem.readInt(u16, h.fetch_base[off..][0..2], .little);
        const slot = &h.fetch_code[off >> 1];
        if (low & 3 != 3) {
            slot.* = m.compressed[low];
            return slot;
        }
        if (off == 0xffe) {
            // Split across two pages: decoded each time, never cached.
            const pa_hi = try h.translate(m, pc + 2, .fetch);
            const high = m.fetch16(pa_hi) orelse return h.raise(Cause.fetch_access, pc);
            h.split = decode.decode32(@as(u32, high) << 16 | low);
            return &h.split;
        }
        slot.* = decode.decode32(@as(u32, std.mem.readInt(u16, h.fetch_base[off + 2 ..][0..2], .little)) << 16 | low);
        return slot;
    }

    // -----------------------------------------------------------------
    // CSRs

    fn csrRead(h: *Hart, m: *const Machine, csr: u12) Exception!u64 {
        // Counters: user mode needs scounteren.
        if (csr >= 0xc00 and csr <= 0xc02) {
            if (h.mode == .user and (h.scounteren >> @intCast(csr - 0xc00)) & 1 == 0) return h.raise(Cause.illegal, 0);
            return switch (csr) {
                0xc00, 0xc02 => h.instret,
                0xc01 => m.timeNow(),
                else => unreachable,
            };
        }
        if (h.mode == .user) return h.raise(Cause.illegal, 0);
        return switch (csr) {
            0x100 => h.sstatus | sstatus_fixed,
            0x104 => h.sie,
            0x105 => h.stvec,
            0x106 => h.scounteren,
            0x10a => 0, // senvcfg
            0x140 => h.sscratch,
            0x141 => h.sepc,
            0x142 => h.scause,
            0x143 => h.stval,
            0x144 => h.sip | (if (m.timeNow() >= h.timer) stip else 0) | (if (m.plic.pendingFor(h.id)) seip else 0),
            0x180 => h.satp,
            else => h.raise(Cause.illegal, 0),
        };
    }

    fn csrWrite(h: *Hart, csr: u12, v: u64) Exception!void {
        if (h.mode == .user or csr >> 10 == 3) return h.raise(Cause.illegal, 0);
        switch (csr) {
            0x100 => {
                h.sstatus = v & sstatus_writable;
                h.updatePerm();
                h.recheck();
            },
            0x104 => {
                h.sie = v & sie_writable;
                h.recheck();
            },
            0x105 => h.stvec = v & ~@as(u64, 2),
            0x106 => h.scounteren = v & 7,
            0x10a => {},
            0x140 => h.sscratch = v,
            0x141 => h.sepc = v & ~@as(u64, 1),
            0x142 => h.scause = v,
            0x143 => h.stval = v,
            0x144 => {
                h.sip = (h.sip & ~ssip) | (v & ssip);
                h.recheck();
            },
            0x180 => {
                const mode = v >> 60;
                if (mode == 0 or mode == 8) {
                    h.satp = v & ~(@as(u64, 0xffff) << 44); // ASIDs: none
                    h.flushTlb();
                }
            },
            else => return h.raise(Cause.illegal, 0),
        }
    }

    // -----------------------------------------------------------------
    // Execution

    /// Run one instruction (or take one interrupt).
    pub inline fn step(h: *Hart, m: *Machine) void {
        if (m.ns >= h.next_event) {
            if (h.checkInterrupts(m)) return;
        }
        h.exec(m) catch {
            h.trap(h.exc_cause, h.exc_tval);
        };
    }

    fn exec(h: *Hart, m: *Machine) Exception!void {
        const i = try h.fetch(m);
        const x = &h.x;
        const a = x[i.rs1];
        const b = x[i.rs2];
        const imm: u64 = @bitCast(@as(i64, i.imm));
        var next = h.pc +% i.len;
        var rd: u64 = 0;
        var writes = true;
        switch (i.op) {
            .lui => rd = imm,
            .auipc => rd = h.pc +% imm,
            .jal => {
                rd = next;
                next = h.pc +% imm;
            },
            .jalr => {
                rd = next;
                next = (a +% imm) & ~@as(u64, 1);
            },
            .beq, .bne, .blt, .bge, .bltu, .bgeu => {
                writes = false;
                const sa: i64 = @bitCast(a);
                const sb: i64 = @bitCast(b);
                const taken = switch (i.op) {
                    .beq => a == b,
                    .bne => a != b,
                    .blt => sa < sb,
                    .bge => sa >= sb,
                    .bltu => a < b,
                    .bgeu => a >= b,
                    else => unreachable,
                };
                if (taken) next = h.pc +% imm;
            },
            .lb => rd = sx(try h.loadFast(m, a +% imm, u8), 8),
            .lh => rd = sx(try h.loadFast(m, a +% imm, u16), 16),
            .lw => rd = sx(try h.loadFast(m, a +% imm, u32), 32),
            .ld => rd = try h.loadFast(m, a +% imm, u64),
            .lbu => rd = try h.loadFast(m, a +% imm, u8),
            .lhu => rd = try h.loadFast(m, a +% imm, u16),
            .lwu => rd = try h.loadFast(m, a +% imm, u32),
            .sb => {
                writes = false;
                try h.storeFast(m, a +% imm, u8, b);
            },
            .sh => {
                writes = false;
                try h.storeFast(m, a +% imm, u16, b);
            },
            .sw => {
                writes = false;
                try h.storeFast(m, a +% imm, u32, b);
            },
            .sd => {
                writes = false;
                try h.storeFast(m, a +% imm, u64, b);
            },
            .addi => rd = a +% imm,
            .slti => rd = @intFromBool(@as(i64, @bitCast(a)) < @as(i64, i.imm)),
            .sltiu => rd = @intFromBool(a < imm),
            .xori => rd = a ^ imm,
            .ori => rd = a | imm,
            .andi => rd = a & imm,
            .slli => rd = a << @intCast(imm & 63),
            .srli => rd = a >> @intCast(imm & 63),
            .srai => rd = @bitCast(@as(i64, @bitCast(a)) >> @intCast(imm & 63)),
            .addiw => rd = sx(a +% imm, 32),
            .slliw => rd = sx(@as(u32, @truncate(a)) << @intCast(imm & 31), 32),
            .srliw => rd = sx(@as(u32, @truncate(a)) >> @intCast(imm & 31), 32),
            .sraiw => rd = @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(a)))) >> @intCast(imm & 31))),
            .add => rd = a +% b,
            .sub => rd = a -% b,
            .sll => rd = a << @intCast(b & 63),
            .slt => rd = @intFromBool(@as(i64, @bitCast(a)) < @as(i64, @bitCast(b))),
            .sltu => rd = @intFromBool(a < b),
            .xor => rd = a ^ b,
            .srl => rd = a >> @intCast(b & 63),
            .sra => rd = @bitCast(@as(i64, @bitCast(a)) >> @intCast(b & 63)),
            .@"or" => rd = a | b,
            .@"and" => rd = a & b,
            .addw => rd = sx(a +% b, 32),
            .subw => rd = sx(a -% b, 32),
            .sllw => rd = sx(@as(u32, @truncate(a)) << @intCast(b & 31), 32),
            .srlw => rd = sx(@as(u32, @truncate(a)) >> @intCast(b & 31), 32),
            .sraw => rd = @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(a)))) >> @intCast(b & 31))),
            .mul => rd = a *% b,
            .mulh => rd = @truncate(@as(u128, @bitCast(@as(i128, @as(i64, @bitCast(a))) * @as(i128, @as(i64, @bitCast(b))))) >> 64),
            .mulhsu => rd = @truncate(@as(u128, @bitCast(@as(i128, @as(i64, @bitCast(a))) *% @as(i128, b))) >> 64),
            .mulhu => rd = @truncate((@as(u128, a) * @as(u128, b)) >> 64),
            .div => rd = @bitCast(divS(@bitCast(a), @bitCast(b))),
            .divu => rd = if (b == 0) std.math.maxInt(u64) else a / b,
            .rem => rd = @bitCast(remS(@bitCast(a), @bitCast(b))),
            .remu => rd = if (b == 0) a else a % b,
            .mulw => rd = sx(a *% b, 32),
            .divw => rd = @bitCast(@as(i64, divS32(@bitCast(@as(u32, @truncate(a))), @bitCast(@as(u32, @truncate(b)))))),
            .divuw => {
                const ua: u32 = @truncate(a);
                const ub: u32 = @truncate(b);
                rd = sx(if (ub == 0) std.math.maxInt(u32) else ua / ub, 32);
            },
            .remw => rd = @bitCast(@as(i64, remS32(@bitCast(@as(u32, @truncate(a))), @bitCast(@as(u32, @truncate(b)))))),
            .remuw => {
                const ua: u32 = @truncate(a);
                const ub: u32 = @truncate(b);
                rd = sx(if (ub == 0) ua else ua % ub, 32);
            },
            // The rest is rarer: kept out of this function so the common path stays small.
            .illegal, .none, .fence, .pause, .fence_i, .ecall, .ebreak, .sret, .wfi, .sfence_vma, .csrrw, .csrrs, .csrrc, .csrrwi, .csrrsi, .csrrci, .lr, .sc, .amoswap, .amoadd, .amoxor, .amoand, .amoor, .amomin, .amomax, .amominu, .amomaxu => return h.execRare(m, i),
        }
        if (writes and i.rd != 0) x[i.rd] = rd;
        h.pc = next;
        h.instret +%= 1;
    }

    noinline fn execRare(h: *Hart, m: *Machine, i: *const decode.Inst) Exception!void {
        const x = &h.x;
        const a = x[i.rs1];
        const b = x[i.rs2];
        var next = h.pc +% i.len;
        var rd: u64 = 0;
        var writes = true;
        switch (i.op) {
            .illegal, .none => return h.raise(Cause.illegal, 0),
            .fence => writes = false,
            .pause => {
                writes = false;
                h.yield = true;
            },
            .fence_i => writes = false, // the decode cache is keyed by instruction bits
            .ecall => {
                writes = false;
                if (h.mode == .user) return h.raise(Cause.ecall_u, 0);
                m.sbi(h);
            },
            .ebreak => return h.raise(Cause.breakpoint, h.pc),
            .sret => {
                writes = false;
                if (h.mode == .user) return h.raise(Cause.illegal, 0);
                const s = h.sstatus;
                h.mode = if (s & spp_bit != 0) .supervisor else .user;
                var ns = s & ~spp_bit;
                ns = if (s & spie_bit != 0) ns | sie_bit else ns & ~sie_bit;
                ns |= spie_bit;
                h.sstatus = ns;
                h.updatePerm();
                h.recheck();
                h.fetch_vpn = std.math.maxInt(u64);
                next = h.sepc;
            },
            .wfi => {
                writes = false;
                if (h.mode == .user) return h.raise(Cause.illegal, 0);
                if (h.pendingInterrupts(m) == 0) h.waiting = true;
                h.yield = true;
            },
            .sfence_vma => {
                writes = false;
                if (h.mode == .user) return h.raise(Cause.illegal, 0);
                h.flushTlb();
            },
            .csrrw, .csrrs, .csrrc, .csrrwi, .csrrsi, .csrrci => {
                const csr: u12 = @intCast(i.imm & 0xfff);
                const src: u64 = switch (i.op) {
                    .csrrw, .csrrs, .csrrc => a,
                    else => i.rs1,
                };
                const write_only = (i.op == .csrrw or i.op == .csrrwi) and i.rd == 0;
                const old = if (write_only) 0 else try h.csrRead(m, csr);
                switch (i.op) {
                    .csrrw, .csrrwi => try h.csrWrite(csr, src),
                    .csrrs, .csrrsi => if (i.rs1 != 0) try h.csrWrite(csr, old | src),
                    .csrrc, .csrrci => if (i.rs1 != 0) try h.csrWrite(csr, old & ~src),
                    else => unreachable,
                }
                rd = old;
            },
            .lr => {
                const size: u8 = if (i.word) 4 else 8;
                if (a & (size - 1) != 0) return h.raise(Cause.misaligned_load, a);
                const pa = try h.translate(m, a, .load);
                const v = m.ramLoad(pa, size) orelse return h.raise(Cause.load_access, a);
                rd = if (i.word) sx(v, 32) else v;
                m.setReservation(h, pa);
            },
            .sc => {
                const size: u8 = if (i.word) 4 else 8;
                if (a & (size - 1) != 0) return h.raise(Cause.misaligned_store, a);
                const pa = try h.translate(m, a, .store);
                if (h.reservation != null and h.reservation.? == pa) {
                    if (!m.ramStore(pa, size, b)) return h.raise(Cause.store_access, a);
                    rd = 0;
                } else rd = 1;
                m.setReservation(h, null);
            },
            .amoswap, .amoadd, .amoxor, .amoand, .amoor, .amomin, .amomax, .amominu, .amomaxu => {
                const size: u8 = if (i.word) 4 else 8;
                if (a & (size - 1) != 0) return h.raise(Cause.misaligned_store, a);
                const pa = try h.translate(m, a, .store);
                const raw = m.ramLoad(pa, size) orelse return h.raise(Cause.store_access, a);
                const old = if (i.word) sx(raw, 32) else raw;
                const src = if (i.word) sx(b, 32) else b;
                const new: u64 = switch (i.op) {
                    .amoswap => src,
                    .amoadd => old +% src,
                    .amoxor => old ^ src,
                    .amoand => old & src,
                    .amoor => old | src,
                    .amomin => if (@as(i64, @bitCast(old)) < @as(i64, @bitCast(src))) old else src,
                    .amomax => if (@as(i64, @bitCast(old)) > @as(i64, @bitCast(src))) old else src,
                    .amominu => if (cmpU(old, src, i.word)) old else src,
                    .amomaxu => if (cmpU(old, src, i.word)) src else old,
                    else => unreachable,
                };
                _ = m.ramStore(pa, size, new);
                rd = old;
            },
            else => unreachable,
        }
        if (writes and i.rd != 0) x[i.rd] = rd;
        h.pc = next;
        h.instret +%= 1;
    }
};

fn permittedIn(acc: Access, mode: Mode, sum: bool, mxr: bool, r: bool, w: bool, x: bool, u: bool) bool {
    if (mode == .user) {
        if (!u) return false;
    } else if (u) {
        if (acc == .fetch or !sum) return false;
    }
    return switch (acc) {
        .fetch => x,
        .load => r or (x and mxr),
        .store => w,
    };
}

fn sx(v: u64, comptime width: u7) u64 {
    const shift: u6 = 64 - width;
    return @bitCast(@as(i64, @bitCast(v << shift)) >> shift);
}

fn cmpU(a: u64, b: u64, word: bool) bool {
    return if (word) @as(u32, @truncate(a)) < @as(u32, @truncate(b)) else a < b;
}

fn divS(a: i64, b: i64) i64 {
    if (b == 0) return -1;
    if (a == std.math.minInt(i64) and b == -1) return a;
    return @divTrunc(a, b);
}

fn remS(a: i64, b: i64) i64 {
    if (b == 0) return a;
    if (a == std.math.minInt(i64) and b == -1) return 0;
    return @rem(a, b);
}

fn divS32(a: i32, b: i32) i32 {
    if (b == 0) return -1;
    if (a == std.math.minInt(i32) and b == -1) return a;
    return @divTrunc(a, b);
}

fn remS32(a: i32, b: i32) i32 {
    if (b == 0) return a;
    if (a == std.math.minInt(i32) and b == -1) return 0;
    return @rem(a, b);
}
