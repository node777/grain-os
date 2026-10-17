//! The AArch64 stage-1 translation format (4 KiB granule, 39-bit addresses,
//! three levels), as pure data: no system registers, no barriers.
//!
//! User address spaces live in TTBR0 and the kernel in TTBR1, so a user root
//! table holds user mappings only; the core's layout is the same as Sv39's.
pub const levels = 3;
pub const entries = 512;
pub const page_shift = 12;
/// User addresses: the same range as on RISC-V, so programs link alike.
pub const user_top: u64 = 1 << 38;
pub const user_root_entries = 256;

pub const valid: u64 = 1 << 0;
/// Levels 1 and 2: a table (set) or a block (clear). Level 0: set for a page.
pub const table_or_page: u64 = 1 << 1;
/// MAIR index 0: normal write-back memory; index 1: device-nGnRnE.
pub const attr_normal: u64 = 0 << 2;
pub const attr_device: u64 = 1 << 2;
pub const ap_el0: u64 = 1 << 6;
pub const ap_read_only: u64 = 1 << 7;
pub const sh_inner: u64 = 3 << 8;
pub const af: u64 = 1 << 10;
pub const not_global: u64 = 1 << 11;
pub const pxn: u64 = 1 << 53;
pub const uxn: u64 = 1 << 54;

const address_mask: u64 = 0x0000_ffff_ffff_f000;

/// A user leaf: what the core asks for, in any format.
pub const Leaf = struct {
    pa: u64,
    /// 0 for a page, 1 for a 2 MiB block, 2 for a 1 GiB block.
    level: u8,
    read: bool,
    write: bool,
    execute: bool,
    device: bool,
};

pub fn levelShift(level: usize) u6 {
    return @intCast(page_shift + 9 * level);
}

pub fn index(va: u64, level: usize) usize {
    return @intCast((va >> levelShift(level)) & (entries - 1));
}

pub fn makeTable(pa: u64) u64 {
    return (pa & address_mask) | table_or_page | valid;
}

/// Readable is implied: AArch64 has no unreadable user pages. The kernel
/// never executes user memory (PXN).
pub fn makeLeaf(l: Leaf) u64 {
    var e = (l.pa & address_mask) | valid | af | not_global | ap_el0 | pxn;
    if (l.level == 0) e |= table_or_page;
    if (!l.write) e |= ap_read_only;
    if (!l.execute) e |= uxn;
    e |= if (l.device) attr_device else attr_normal | sh_inner;
    return e;
}

/// A global kernel block (EL1 only, never executable from EL0).
pub fn makeKernelBlock(pa: u64, device: bool) u64 {
    return (pa & address_mask) | valid | af | uxn | (if (device) attr_device | pxn else attr_normal | sh_inner);
}

pub fn isValid(pte: u64) bool {
    return pte & valid != 0;
}

pub fn isLeaf(pte: u64, level: usize) bool {
    return level == 0 or pte & table_or_page == 0;
}

pub fn address(pte: u64) u64 {
    return pte & address_mask;
}

test "encode and decode" {
    const std = @import("std");
    const page = makeLeaf(.{ .pa = 0x4020_3000, .level = 0, .read = true, .write = true, .execute = false, .device = false });
    try std.testing.expect(isValid(page) and isLeaf(page, 0));
    try std.testing.expectEqual(@as(u64, 0x4020_3000), address(page));
    try std.testing.expect(page & uxn != 0 and page & ap_read_only == 0 and page & ap_el0 != 0);
    const code = makeLeaf(.{ .pa = 0x4020_4000, .level = 0, .read = true, .write = false, .execute = true, .device = false });
    try std.testing.expect(code & uxn == 0 and code & ap_read_only != 0);
    const block = makeLeaf(.{ .pa = 0x1000_0000, .level = 1, .read = true, .write = true, .execute = false, .device = true });
    try std.testing.expect(isLeaf(block, 1) and block & table_or_page == 0 and block & attr_device != 0);
    const t = makeTable(0x4040_0000);
    try std.testing.expect(isValid(t) and !isLeaf(t, 1));
    try std.testing.expectEqual(@as(usize, 1), index(0x4040_0000, 2));
}
