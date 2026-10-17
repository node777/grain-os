//! Flattened device tree (DTB) reader and platform discovery.
//!
//! The kernel learns the machine from the device tree the firmware hands it:
//! RAM, reserved ranges, harts, the timer frequency, the interrupt controller
//! and the few devices the kernel itself touches. This module only reads the
//! blob (no allocation, no hardware access), so it runs unchanged on the host
//! against captured DTBs.
const std = @import("std");

pub const Error = error{ BadMagic, BadVersion, Truncated, BadStructure };

const magic: u32 = 0xd00dfeed;
const token_begin_node: u32 = 1;
const token_end_node: u32 = 2;
const token_prop: u32 = 3;
const token_nop: u32 = 4;
const token_end: u32 = 9;

fn be32(bytes: []const u8, off: usize) Error!u32 {
    if (off + 4 > bytes.len) return error.Truncated;
    return std.mem.readInt(u32, bytes[off..][0..4], .big);
}

pub const Fdt = struct {
    blob: []const u8,
    structs: []const u8,
    strings: []const u8,
    rsvmap_off: usize,

    /// Validate the header. `ptr` may point at an unknown-length blob; the
    /// header's totalsize bounds every later access.
    pub fn fromPtr(ptr: [*]const u8) Error!Fdt {
        const total = try be32(ptr[0..8], 4);
        return init(ptr[0..total]);
    }

    pub fn init(blob: []const u8) Error!Fdt {
        if (try be32(blob, 0) != magic) return error.BadMagic;
        const total = try be32(blob, 4);
        if (total > blob.len) return error.Truncated;
        const b = blob[0..total];
        const off_struct = try be32(b, 8);
        const off_strings = try be32(b, 12);
        const off_rsvmap = try be32(b, 16);
        const version = try be32(b, 20);
        const size_strings = try be32(b, 32);
        const size_struct = try be32(b, 36);
        if (version < 17) return error.BadVersion;
        if (@as(u64, off_struct) + size_struct > total or @as(u64, off_strings) + size_strings > total)
            return error.Truncated;
        return .{
            .blob = b,
            .structs = b[off_struct..][0..size_struct],
            .strings = b[off_strings..][0..size_strings],
            .rsvmap_off = off_rsvmap,
        };
    }

    pub fn totalSize(self: Fdt) usize {
        return self.blob.len;
    }

    /// Entries of the memory reservation block (address, size).
    pub fn reservations(self: Fdt) ReservationIterator {
        return .{ .fdt = self, .off = self.rsvmap_off };
    }

    pub fn walk(self: Fdt) Walker {
        return .{ .fdt = self };
    }

    fn string(self: Fdt, off: u32) Error![]const u8 {
        if (off >= self.strings.len) return error.Truncated;
        const rest = self.strings[off..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse return error.Truncated;
        return rest[0..end];
    }
};

pub const ReservationIterator = struct {
    fdt: Fdt,
    off: usize,

    pub fn next(self: *ReservationIterator) Error!?Range {
        const b = self.fdt.blob;
        if (self.off + 16 > b.len) return error.Truncated;
        const addr = std.mem.readInt(u64, b[self.off..][0..8], .big);
        const size = std.mem.readInt(u64, b[self.off + 8 ..][0..8], .big);
        self.off += 16;
        if (addr == 0 and size == 0) return null;
        return .{ .base = addr, .size = size };
    }
};

pub const Range = struct {
    base: u64,
    size: u64,

    pub fn end(self: Range) u64 {
        return self.base + self.size;
    }
};

pub const Prop = struct {
    name: []const u8,
    value: []const u8,

    pub fn u32At(self: Prop, index: usize) ?u32 {
        if ((index + 1) * 4 > self.value.len) return null;
        return std.mem.readInt(u32, self.value[index * 4 ..][0..4], .big);
    }

    /// Read a big-endian number spanning `cells` 32-bit cells at cell `index`.
    pub fn cellsAt(self: Prop, index: usize, cells: u32) ?u64 {
        var v: u64 = 0;
        for (0..cells) |i| v = (v << 32) | (self.u32At(index + i) orelse return null);
        return v;
    }

    pub fn str(self: Prop) []const u8 {
        return std.mem.sliceTo(self.value, 0);
    }

    /// True if this string-list property (e.g. `compatible`) contains `s`.
    pub fn hasString(self: Prop, s: []const u8) bool {
        var it = std.mem.splitScalar(u8, self.value, 0);
        while (it.next()) |item| if (std.mem.eql(u8, item, s)) return true;
        return false;
    }
};

pub const Event = union(enum) {
    begin: []const u8,
    end,
    prop: Prop,
};

/// Linear walk of the structure block: node begins and ends, and properties.
pub const Walker = struct {
    fdt: Fdt,
    off: usize = 0,
    depth: u32 = 0,
    done: bool = false,

    pub fn next(self: *Walker) Error!?Event {
        const s = self.fdt.structs;
        while (!self.done) {
            const tok = try be32(s, self.off);
            self.off += 4;
            switch (tok) {
                token_begin_node => {
                    const rest = s[self.off..];
                    const len = std.mem.indexOfScalar(u8, rest, 0) orelse return error.Truncated;
                    self.off += std.mem.alignForward(usize, len + 1, 4);
                    self.depth += 1;
                    return .{ .begin = rest[0..len] };
                },
                token_end_node => {
                    if (self.depth == 0) return error.BadStructure;
                    self.depth -= 1;
                    return .end;
                },
                token_prop => {
                    const len = try be32(s, self.off);
                    const nameoff = try be32(s, self.off + 4);
                    self.off += 8;
                    if (self.off + len > s.len) return error.Truncated;
                    const value = s[self.off..][0..len];
                    self.off += std.mem.alignForward(usize, len, 4);
                    return .{ .prop = .{ .name = try self.fdt.string(nameoff), .value = value } };
                },
                token_nop => {},
                token_end => self.done = true,
                else => return error.BadStructure,
            }
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Platform discovery

pub const max_memory = 8;
pub const max_reserved = 16;
pub const max_harts = 16;
pub const max_devices = 32;

pub const Hart = struct {
    id: u32,
    /// phandle of this hart's interrupt-controller node (for PLIC contexts).
    intc_phandle: u32 = 0,
    /// PLIC context that routes supervisor external interrupts to this hart.
    plic_context: ?u32 = null,
};

/// Everything the kernel learns from the device tree at boot.
pub const Platform = struct {
    memory: [max_memory]Range = undefined,
    memory_len: usize = 0,
    reserved: [max_reserved]Range = undefined,
    reserved_len: usize = 0,
    harts: [max_harts]Hart = undefined,
    harts_len: usize = 0,
    timebase_hz: u64 = 0,
    plic: ?Range = null,
    plic_ndev: u32 = 0,
    test_finisher: ?u64 = null,
    uart: ?Range = null,
    uart_irq: ?u32 = null,
    /// MMIO ranges of every device node with a `reg` outside RAM, to hand to
    /// userspace as device memory.
    devices: [max_devices]Range = undefined,
    devices_len: usize = 0,

    pub fn memoryRanges(self: *const Platform) []const Range {
        return self.memory[0..self.memory_len];
    }
    pub fn reservedRanges(self: *const Platform) []const Range {
        return self.reserved[0..self.reserved_len];
    }
    pub fn hartList(self: *const Platform) []const Hart {
        return self.harts[0..self.harts_len];
    }
    pub fn deviceRanges(self: *const Platform) []const Range {
        return self.devices[0..self.devices_len];
    }

    pub fn hartIndex(self: *const Platform, hart_id: u32) ?usize {
        for (self.hartList(), 0..) |h, i| if (h.id == hart_id) return i;
        return null;
    }
};

const max_depth = 16;

/// Per-node facts gathered while walking, resolved when the node ends.
const NodeInfo = struct {
    name: []const u8 = "",
    /// Cell sizes for this node's own `reg` (declared by the parent).
    reg_cells: [2]u32 = .{ 2, 1 },
    /// Cell sizes this node declares for its children (spec defaults 2 and 1).
    child_cells: [2]u32 = .{ 2, 1 },
    reg: ?Prop = null,
    ranges: ?Prop = null,
    compatible: ?Prop = null,
    device_type: ?[]const u8 = null,
    status_ok: bool = true,
    phandle: u32 = 0,
    interrupts: ?u32 = null,
    interrupts_extended: ?Prop = null,
    ndev: u32 = 0,
    timebase: ?u64 = null,
    is_intc: bool = false,

    fn isA(self: NodeInfo, device_type: []const u8) bool {
        return self.device_type != null and std.mem.eql(u8, self.device_type.?, device_type);
    }
};

pub fn parsePlatform(fdt: Fdt) Error!Platform {
    var p: Platform = .{};
    var stack: [max_depth]NodeInfo = undefined;
    var depth: usize = 0;
    var plic_ext: ?Prop = null;
    var cpus_timebase: ?u64 = null;
    // The phandle of the interrupt-controller child seen inside the current cpu node.
    var pending_intc: u32 = 0;

    var w = fdt.walk();
    while (try w.next()) |ev| switch (ev) {
        .begin => |name| {
            if (depth == max_depth) return error.BadStructure;
            stack[depth] = .{ .name = name };
            if (depth > 0) stack[depth].reg_cells = stack[depth - 1].child_cells;
            depth += 1;
        },
        .prop => |prop| {
            if (depth == 0) return error.BadStructure;
            const n = &stack[depth - 1];
            const eql = std.mem.eql;
            if (eql(u8, prop.name, "#address-cells")) n.child_cells[0] = prop.u32At(0) orelse 2;
            if (eql(u8, prop.name, "#size-cells")) n.child_cells[1] = prop.u32At(0) orelse 1;
            if (eql(u8, prop.name, "reg")) n.reg = prop;
            if (eql(u8, prop.name, "ranges")) n.ranges = prop;
            if (eql(u8, prop.name, "compatible")) n.compatible = prop;
            if (eql(u8, prop.name, "device_type")) n.device_type = prop.str();
            if (eql(u8, prop.name, "status")) n.status_ok = eql(u8, prop.str(), "okay") or eql(u8, prop.str(), "ok");
            if (eql(u8, prop.name, "phandle")) n.phandle = prop.u32At(0) orelse 0;
            if (eql(u8, prop.name, "interrupts")) n.interrupts = prop.u32At(0);
            if (eql(u8, prop.name, "interrupts-extended")) n.interrupts_extended = prop;
            if (eql(u8, prop.name, "riscv,ndev")) n.ndev = prop.u32At(0) orelse 0;
            if (eql(u8, prop.name, "interrupt-controller")) n.is_intc = true;
            if (eql(u8, prop.name, "timebase-frequency"))
                n.timebase = if (prop.value.len == 8) prop.cellsAt(0, 2) else prop.cellsAt(0, 1);
        },
        .end => {
            if (depth == 0) return error.BadStructure;
            depth -= 1;
            const n = stack[depth];
            const parent: ?NodeInfo = if (depth >= 1) stack[depth - 1] else null;
            const parent_name = if (parent) |q| q.name else "";

            if (depth == 1 and std.mem.eql(u8, n.name, "cpus")) {
                if (n.timebase) |t| cpus_timebase = t;
            } else if (n.isA("cpu")) {
                if (n.timebase) |t| cpus_timebase = cpus_timebase orelse t;
                if (n.status_ok and p.harts_len < max_harts) if (n.reg) |r| {
                    p.harts[p.harts_len] = .{ .id = @intCast(r.cellsAt(0, n.reg_cells[0]) orelse 0), .intc_phandle = pending_intc };
                    p.harts_len += 1;
                };
                pending_intc = 0;
            } else if (n.is_intc and parent != null and parent.?.isA("cpu")) {
                pending_intc = n.phandle;
            } else if (n.isA("memory")) {
                if (n.reg) |r| appendRegs(r, n.reg_cells, &p.memory, &p.memory_len);
            } else if (depth == 2 and std.mem.eql(u8, parent_name, "reserved-memory")) {
                if (n.reg) |r| appendRegs(r, n.reg_cells, &p.reserved, &p.reserved_len);
            } else if (n.compatible) |c| {
                const first = firstReg(n.reg, n.reg_cells);
                if (c.hasString("riscv,plic0") or c.hasString("sifive,plic-1.0.0")) {
                    p.plic = first;
                    p.plic_ndev = n.ndev;
                    plic_ext = n.interrupts_extended;
                } else if (c.hasString("sifive,test0") or c.hasString("sifive,test1")) {
                    if (first) |f| p.test_finisher = f.base;
                } else if (c.hasString("ns16550a") or c.hasString("ns16550")) {
                    if (p.uart == null) {
                        p.uart = first;
                        p.uart_irq = n.interrupts;
                    }
                }
                if (first) |f| if (n.status_ok and f.size > 0 and p.devices_len < max_devices) {
                    p.devices[p.devices_len] = f;
                    p.devices_len += 1;
                };
                // A PCI host bridge's memory windows are device memory too:
                // the BARs that drivers map are assigned inside them.
                if (c.hasString("pci-host-ecam-generic") and n.status_ok) if (n.ranges) |r| {
                    var it = PciWindows{ .ranges = r, .parent_cells = n.reg_cells[0], .size_cells = n.child_cells[1] };
                    while (it.next()) |win| if (p.devices_len < max_devices) {
                        p.devices[p.devices_len] = .{ .base = win.cpu, .size = win.size };
                        p.devices_len += 1;
                    };
                };
            }
        },
    };
    if (depth != 0) return error.BadStructure;

    p.timebase_hz = cpus_timebase orelse 0;

    var rsv = fdt.reservations();
    while (try rsv.next()) |r| if (p.reserved_len < max_reserved) {
        p.reserved[p.reserved_len] = r;
        p.reserved_len += 1;
    };

    // PLIC contexts: interrupts-extended lists (intc phandle, cause) pairs in
    // context order. Cause 9 is the supervisor external interrupt.
    if (plic_ext) |ext| {
        var i: usize = 0;
        var ctx: u32 = 0;
        while (ext.u32At(i + 1)) |cause| : ({
            i += 2;
            ctx += 1;
        }) {
            const ph = ext.u32At(i).?;
            if (cause != 9) continue;
            for (p.harts[0..p.harts_len]) |*h| if (h.intc_phandle == ph) {
                h.plic_context = ctx;
            };
        }
    }
    return p;
}

/// A PCI memory window: where the bus addresses `pci` appear to the CPU.
pub const PciWindow = struct { pci: u64, cpu: u64, size: u64, prefetchable: bool, wide: bool };

/// The memory windows in a PCI host's `ranges` (I/O space is skipped).
const PciWindows = struct {
    ranges: Prop,
    parent_cells: u32,
    size_cells: u32,
    i: usize = 0,

    fn next(w: *PciWindows) ?PciWindow {
        const stride = 3 + w.parent_cells + w.size_cells;
        while (w.ranges.u32At(w.i)) |hi| {
            defer w.i += stride;
            const pci = w.ranges.cellsAt(w.i + 1, 2) orelse return null;
            const cpu = w.ranges.cellsAt(w.i + 3, w.parent_cells) orelse return null;
            const size = w.ranges.cellsAt(w.i + 3 + w.parent_cells, w.size_cells) orelse return null;
            const space = (hi >> 24) & 3; // 1 = I/O, 2 = 32-bit memory, 3 = 64-bit memory
            if (space < 2 or size == 0) continue;
            return .{ .pci = pci, .cpu = cpu, .size = size, .prefetchable = hi & 0x4000_0000 != 0, .wide = space == 3 };
        }
        return null;
    }
};

/// One line of a PCI host's `interrupt-map`: a device (bits 11..15 of the
/// address, masked) and pin (1..4) to an interrupt of its parent.
pub const PciIrq = struct { device: u32, pin: u32, irq: u32 };

pub const PciHost = struct {
    ecam: Range,
    bus_start: u8 = 0,
    bus_end: u8 = 255,
    windows: [4]PciWindow = undefined,
    windows_len: usize = 0,
    map: [32]PciIrq = undefined,
    map_len: usize = 0,
    /// Which address bits and pin bits the map looks at.
    mask_device: u32 = 0xffff_ffff,
    mask_pin: u32 = 7,

    /// The parent interrupt for `pin` (1..4) of the device at `devfn`'s slot.
    pub fn irqOf(h: *const PciHost, device: u32, pin: u32) ?u32 {
        const key = (device << 11) & h.mask_device;
        for (h.map[0..h.map_len]) |e| if (e.device == key and e.pin == (pin & h.mask_pin)) return e.irq;
        return null;
    }
};

/// The first enabled ECAM PCI host bridge, with what Steward needs to
/// enumerate it: configuration space, memory windows, interrupt routing.
/// The interrupt map is read assuming a parent with no address cells and
/// one interrupt cell (the RISC-V PLIC; most simple interrupt controllers).
pub fn findPciHost(fdt: Fdt) Error!?PciHost {
    var stack: [max_depth]NodeInfo = undefined;
    var props: [max_depth]struct { map: ?Prop = null, mask: ?Prop = null, bus: ?Prop = null } = undefined;
    var depth: usize = 0;
    var w = fdt.walk();
    while (try w.next()) |ev| switch (ev) {
        .begin => |name| {
            if (depth == max_depth) return error.BadStructure;
            stack[depth] = .{ .name = name };
            props[depth] = .{};
            if (depth > 0) stack[depth].reg_cells = stack[depth - 1].child_cells;
            depth += 1;
        },
        .prop => |prop| {
            if (depth == 0) return error.BadStructure;
            const nd = &stack[depth - 1];
            const eql = std.mem.eql;
            if (eql(u8, prop.name, "#address-cells")) nd.child_cells[0] = prop.u32At(0) orelse 2;
            if (eql(u8, prop.name, "#size-cells")) nd.child_cells[1] = prop.u32At(0) orelse 1;
            if (eql(u8, prop.name, "reg")) nd.reg = prop;
            if (eql(u8, prop.name, "ranges")) nd.ranges = prop;
            if (eql(u8, prop.name, "compatible")) nd.compatible = prop;
            if (eql(u8, prop.name, "status")) nd.status_ok = eql(u8, prop.str(), "okay") or eql(u8, prop.str(), "ok");
            if (eql(u8, prop.name, "interrupt-map")) props[depth - 1].map = prop;
            if (eql(u8, prop.name, "interrupt-map-mask")) props[depth - 1].mask = prop;
            if (eql(u8, prop.name, "bus-range")) props[depth - 1].bus = prop;
        },
        .end => {
            if (depth == 0) return error.BadStructure;
            depth -= 1;
            const nd = stack[depth];
            const c = nd.compatible orelse continue;
            if (!c.hasString("pci-host-ecam-generic") or !nd.status_ok) continue;
            var h: PciHost = .{ .ecam = firstReg(nd.reg, nd.reg_cells) orelse continue };
            if (props[depth].bus) |b| {
                h.bus_start = @truncate(b.u32At(0) orelse 0);
                h.bus_end = @truncate(b.u32At(1) orelse 255);
            }
            if (nd.ranges) |r| {
                var it = PciWindows{ .ranges = r, .parent_cells = nd.reg_cells[0], .size_cells = nd.child_cells[1] };
                while (it.next()) |win| if (h.windows_len < h.windows.len) {
                    h.windows[h.windows_len] = win;
                    h.windows_len += 1;
                };
            }
            if (props[depth].mask) |m| {
                h.mask_device = m.u32At(0) orelse h.mask_device;
                h.mask_pin = m.u32At(3) orelse h.mask_pin;
            }
            if (props[depth].map) |m| {
                // child address (3) + pin (1) + parent phandle (1) + parent irq (1)
                var i: usize = 0;
                while (m.u32At(i + 5)) |irq| : (i += 6) {
                    if (h.map_len == h.map.len) break;
                    h.map[h.map_len] = .{ .device = m.u32At(i).?, .pin = m.u32At(i + 3).?, .irq = irq };
                    h.map_len += 1;
                }
            }
            return h;
        },
    };
    return null;
}

fn firstReg(reg: ?Prop, cells: [2]u32) ?Range {
    const r = reg orelse return null;
    const base = r.cellsAt(0, cells[0]) orelse return null;
    const size = r.cellsAt(cells[0], cells[1]) orelse return null;
    return .{ .base = base, .size = size };
}

fn appendRegs(reg: Prop, cells: [2]u32, out: []Range, len: *usize) void {
    const stride = cells[0] + cells[1];
    if (stride == 0) return;
    var i: usize = 0;
    while (reg.cellsAt(i, cells[0])) |base| : (i += stride) {
        const size = reg.cellsAt(i + cells[0], cells[1]) orelse break;
        if (len.* == out.len) return;
        out[len.*] = .{ .base = base, .size = size };
        len.* += 1;
    }
}

// ---------------------------------------------------------------------------

const virt_dtb = @embedFile("testdata/qemu-virt-smp2.dtb");

test "parse QEMU virt (2 harts, 256 MiB)" {
    const fdt = try Fdt.init(virt_dtb);
    const p = try parsePlatform(fdt);
    try std.testing.expectEqual(@as(usize, 1), p.memory_len);
    try std.testing.expectEqual(Range{ .base = 0x8000_0000, .size = 0x1000_0000 }, p.memory[0]);
    try std.testing.expectEqual(@as(u64, 10_000_000), p.timebase_hz);
    try std.testing.expectEqual(@as(usize, 2), p.harts_len);
    try std.testing.expectEqual(@as(u32, 0), p.harts[0].id);
    try std.testing.expectEqual(@as(u32, 1), p.harts[1].id);
    try std.testing.expectEqual(@as(?u32, 1), p.harts[0].plic_context);
    try std.testing.expectEqual(@as(?u32, 3), p.harts[1].plic_context);
    try std.testing.expectEqual(@as(?u64, 0x100000), p.test_finisher);
    try std.testing.expectEqual(Range{ .base = 0x0c00_0000, .size = 0x60_0000 }, p.plic.?);
    try std.testing.expectEqual(@as(u32, 0x5f), p.plic_ndev);
    try std.testing.expectEqual(Range{ .base = 0x1000_0000, .size = 0x100 }, p.uart.?);
    try std.testing.expectEqual(@as(?u32, 10), p.uart_irq);
    try std.testing.expect(p.devices_len >= 4);
}

test "the PCI host: configuration space, windows, interrupt routing" {
    const fdt = try Fdt.init(virt_dtb);
    const h = (try findPciHost(fdt)).?;
    try std.testing.expectEqual(Range{ .base = 0x3000_0000, .size = 0x1000_0000 }, h.ecam);
    try std.testing.expectEqual(@as(usize, 2), h.windows_len);
    try std.testing.expectEqual(@as(u64, 0x4000_0000), h.windows[0].cpu);
    try std.testing.expectEqual(@as(u64, 0x4000_0000), h.windows[0].size);
    try std.testing.expect(!h.windows[0].wide and h.windows[1].wide);
    try std.testing.expectEqual(@as(u64, 0x4_0000_0000), h.windows[1].cpu);
    // Swizzled: slot 1 pin A is the line slot 0 pin B uses.
    try std.testing.expectEqual(@as(?u32, 0x20), h.irqOf(0, 1));
    try std.testing.expectEqual(@as(?u32, 0x21), h.irqOf(1, 1));
    try std.testing.expectEqual(@as(?u32, 0x20), h.irqOf(1, 4));
    try std.testing.expectEqual(@as(?u32, 0x23), h.irqOf(4, 4)); // slot 4 masks to slot 0
    // The kernel offers the windows as device memory.
    const p = try parsePlatform(fdt);
    var found: usize = 0;
    for (p.deviceRanges()) |r| found += @intFromBool(r.base == 0x4000_0000 or r.base == 0x4_0000_0000);
    try std.testing.expectEqual(@as(usize, 2), found);
}

test "reject bad blobs" {
    try std.testing.expectError(error.BadMagic, Fdt.init("\x00\x00\x00\x00\x00\x00\x00\x40"));
    try std.testing.expectError(error.Truncated, Fdt.init(virt_dtb[0..100]));
}

test "walker balances begin and end" {
    const fdt = try Fdt.init(virt_dtb);
    var w = fdt.walk();
    var depth: i32 = 0;
    var props: usize = 0;
    while (try w.next()) |ev| switch (ev) {
        .begin => depth += 1,
        .end => depth -= 1,
        .prop => props += 1,
    };
    try std.testing.expectEqual(@as(i32, 0), depth);
    try std.testing.expect(props > 50);
}

test "memreserve, reserved-memory, multiple memory ranges, disabled harts" {
    const fdt = try Fdt.init(@embedFile("testdata/reserved.dtb"));
    const p = try parsePlatform(fdt);
    try std.testing.expectEqual(@as(usize, 2), p.memory_len);
    try std.testing.expectEqual(Range{ .base = 0x1_0000_0000, .size = 0x1000_0000 }, p.memory[1]);
    try std.testing.expectEqual(@as(usize, 2), p.reserved_len);
    try std.testing.expectEqual(Range{ .base = 0x8000_0000, .size = 0x4_0000 }, p.reserved[0]);
    try std.testing.expectEqual(Range{ .base = 0x8000_0000, .size = 0x20_0000 }, p.reserved[1]);
    try std.testing.expectEqual(@as(usize, 1), p.harts_len);
    try std.testing.expectEqual(@as(u64, 1_000_000), p.timebase_hz);
}

/// A device node matched by `compatible`: its first register range and
/// first interrupt.
pub const DeviceNode = struct { reg: Range, irq: ?u32 };

/// Every enabled node whose `compatible` list contains `compat`, in tree order.
pub fn findCompatible(fdt: Fdt, compat: []const u8, out: []DeviceNode) Error![]DeviceNode {
    var n: usize = 0;
    var stack: [max_depth]NodeInfo = undefined;
    var depth: usize = 0;
    var w = fdt.walk();
    while (try w.next()) |ev| switch (ev) {
        .begin => |name| {
            if (depth == max_depth) return error.BadStructure;
            stack[depth] = .{ .name = name };
            if (depth > 0) stack[depth].reg_cells = stack[depth - 1].child_cells;
            depth += 1;
        },
        .prop => |prop| {
            if (depth == 0) return error.BadStructure;
            const nd = &stack[depth - 1];
            if (std.mem.eql(u8, prop.name, "#address-cells")) nd.child_cells[0] = prop.u32At(0) orelse 2;
            if (std.mem.eql(u8, prop.name, "#size-cells")) nd.child_cells[1] = prop.u32At(0) orelse 1;
            if (std.mem.eql(u8, prop.name, "reg")) nd.reg = prop;
            if (std.mem.eql(u8, prop.name, "compatible")) nd.compatible = prop;
            if (std.mem.eql(u8, prop.name, "interrupts")) nd.interrupts = prop.u32At(0);
            if (std.mem.eql(u8, prop.name, "status")) nd.status_ok = std.mem.eql(u8, prop.str(), "okay") or std.mem.eql(u8, prop.str(), "ok");
        },
        .end => {
            if (depth == 0) return error.BadStructure;
            depth -= 1;
            const nd = stack[depth];
            if (nd.compatible) |c| if (c.hasString(compat) and nd.status_ok and n < out.len) {
                if (firstReg(nd.reg, nd.reg_cells)) |r| {
                    out[n] = .{ .reg = r, .irq = nd.interrupts };
                    n += 1;
                }
            };
        },
    };
    return out[0..n];
}

test "find the virtio-mmio transports" {
    const fdt = try Fdt.init(virt_dtb);
    var buf: [16]DeviceNode = undefined;
    const nodes = try findCompatible(fdt, "virtio,mmio", &buf);
    try std.testing.expectEqual(@as(usize, 8), nodes.len);
    for (nodes) |nd| {
        try std.testing.expect(nd.reg.base >= 0x1000_1000 and nd.reg.base <= 0x1000_8000);
        try std.testing.expectEqual(@as(u64, 0x1000), nd.reg.size);
        try std.testing.expect(nd.irq.? >= 1 and nd.irq.? <= 8);
    }
}
