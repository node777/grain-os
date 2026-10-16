//! The RISC-V Sv39 page-table format, as pure data: no CSRs, no fences. The
//! kernel's riscv64 layer and the host simulator both use it, so the
//! simulator exercises real page-table encodings.
pub const levels = 3;
pub const entries = 512;
pub const page_shift = 12;
/// User addresses are the lower half of the 39-bit space.
pub const user_top: u64 = 1 << 38;
/// Root-table slots below this index belong to user space.
pub const user_root_entries = 256;

pub const pte_v: u64 = 1 << 0;
pub const pte_r: u64 = 1 << 1;
pub const pte_w: u64 = 1 << 2;
pub const pte_x: u64 = 1 << 3;
pub const pte_u: u64 = 1 << 4;
pub const pte_g: u64 = 1 << 5;
pub const pte_a: u64 = 1 << 6;
pub const pte_d: u64 = 1 << 7;

pub fn levelShift(level: usize) u6 {
    return @intCast(page_shift + 9 * level);
}

pub fn index(va: u64, level: usize) usize {
    return @intCast((va >> levelShift(level)) & (entries - 1));
}

pub fn makeTable(pa: u64) u64 {
    return ((pa >> page_shift) << 10) | pte_v;
}

/// A user leaf. A and D are preset: hardware without Svadu would otherwise
/// fault on first access.
pub fn makeLeaf(pa: u64, r: bool, w: bool, x: bool) u64 {
    return ((pa >> page_shift) << 10) | perms(r, w, x) | pte_u | pte_a | pte_d | pte_v;
}

/// A global kernel leaf (no U bit).
pub fn makeKernelLeaf(pa: u64, r: bool, w: bool, x: bool) u64 {
    return ((pa >> page_shift) << 10) | perms(r, w, x) | pte_g | pte_a | pte_d | pte_v;
}

fn perms(r: bool, w: bool, x: bool) u64 {
    return (if (r) pte_r else 0) | (if (w) pte_w else 0) | (if (x) pte_x else 0);
}

pub fn isValid(pte: u64) bool {
    return pte & pte_v != 0;
}

pub fn isLeaf(pte: u64) bool {
    return pte & (pte_r | pte_w | pte_x) != 0;
}

pub fn address(pte: u64) u64 {
    return ((pte >> 10) & ((1 << 44) - 1)) << page_shift;
}

test "encode and decode" {
    const std = @import("std");
    const l = makeLeaf(0x8020_3000, true, true, false);
    try std.testing.expect(isValid(l) and isLeaf(l));
    try std.testing.expectEqual(@as(u64, 0x8020_3000), address(l));
    try std.testing.expect(l & pte_u != 0 and l & pte_x == 0);
    const t = makeTable(0x8040_0000);
    try std.testing.expect(isValid(t) and !isLeaf(t));
    try std.testing.expectEqual(@as(usize, 2), index(0x8040_0000, 2));
    try std.testing.expectEqual(@as(usize, 510), index(0xffff_ffff_8020_0000, 2));
}
