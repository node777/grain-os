//! The machine: QEMU's RISC-V `virt` board as far as Caravan uses it, with
//! SBI provided by the machine instead of OpenSBI.
//!
//! Memory map (as QEMU's):
//!   0x0010_0000  SiFive test finisher
//!   0x0c00_0000  PLIC
//!   0x1000_0000  16550 UART (line 10)
//!   0x1000_1000  eight virtio-mmio slots, 0x1000 apart (lines 1..8)
//!   0x8000_0000  RAM; the kernel at 0x8020_0000, the device tree near the top
//!
//! Time is counted in instructions, like QEMU's `-icount shift=0,sleep=off`:
//! every instruction on any hart is one nanosecond, the timebase is 10 MHz,
//! and when every hart waits the clock jumps to the next timer deadline. A
//! run is therefore a function of its inputs alone.
//!
//! Nothing here touches the host: output and input go through `Host`, so
//! the same machine can run natively or compiled to WebAssembly.
const std = @import("std");
const hart_mod = @import("hart.zig");
const devices = @import("devices.zig");
const dtb = @import("dtb.zig");
const decode = @import("decode.zig");
pub const virtio = @import("virtio.zig");
pub const Hart = hart_mod.Hart;
/// The decoded instructions of one 4 KiB page of RAM, one slot per halfword
/// (`.none` until first executed).
pub const CodePage = [2048]decode.Inst;

pub const ram_base: u64 = 0x8000_0000;
pub const kernel_base: u64 = 0x8020_0000;
pub const timebase_hz: u64 = 10_000_000;
/// Virtual nanoseconds per time-CSR tick.
const ns_per_tick = 1_000_000_000 / timebase_hz;
pub const virtio_base: u64 = 0x1000_1000;
pub const virtio_slots = 8;
pub const max_harts = 8;
/// Instructions a hart runs before the next one gets a turn.
const quantum = 1000;

pub const DeviceSpec = struct {
    kind: virtio.Kind,
};

pub const Config = struct {
    harts: u32 = 1,
    ram_mib: u32 = 256,
    /// Virtio devices, in slot order: the first takes the highest address
    /// (0x1000_8000), as QEMU assigns `-device`s, so device-tree order is
    /// this order. Consoles are numbered 0, 1, ... in this order too.
    devices: []const DeviceSpec = &.{},
    /// Block devices: the disk's size in bytes.
    disk_bytes: u64 = 0,
    /// Time from the host's clock (real time) instead of instruction counts.
    realtime: bool = false,
};

/// What the machine needs from where it runs.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    /// The serial console (SBI console and the UART).
    console: *const fn (ctx: ?*anyopaque, bytes: []const u8) void,
    /// Output on virtio console `port`.
    port_write: *const fn (ctx: ?*anyopaque, port: u8, bytes: []const u8) void = noPort,
    /// Fill with random bytes (the entropy device).
    entropy: *const fn (ctx: ?*anyopaque, out: []u8) void = noEntropy,
    disk_read: *const fn (ctx: ?*anyopaque, offset: u64, out: []u8) bool = noRead,
    disk_write: *const fn (ctx: ?*anyopaque, offset: u64, bytes: []const u8) bool = noWrite,
    disk_flush: *const fn (ctx: ?*anyopaque) bool = noFlush,
    /// Nanoseconds since the machine started, for real-time machines.
    now_ns: *const fn (ctx: ?*anyopaque) u64 = noClock,

    fn noPort(_: ?*anyopaque, _: u8, _: []const u8) void {}
    fn noEntropy(_: ?*anyopaque, out: []u8) void {
        @memset(out, 0);
    }
    fn noRead(_: ?*anyopaque, _: u64, _: []u8) bool {
        return false;
    }
    fn noWrite(_: ?*anyopaque, _: u64, _: []const u8) bool {
        return false;
    }
    fn noFlush(_: ?*anyopaque) bool {
        return true;
    }
    fn noClock(_: ?*anyopaque) u64 {
        return 0;
    }
};

pub const Stop = enum {
    /// The guest powered off; see `exit_code`.
    exited,
    /// Every hart waits and nothing is due: only input can wake it.
    idle,
    /// Real time: every hart waits until `wake_ns` (or input).
    waiting,
    /// The instruction budget ran out.
    budget,
};

pub const Machine = struct {
    gpa: std.mem.Allocator,
    host: Host,
    ram: []u8,
    harts: []Hart,
    plic: devices.Plic = .{},
    uart: devices.Uart = .{},
    /// Virtual time, in nanoseconds (one per instruction).
    ns: u64 = 0,
    exit_code: ?u32 = null,
    dtb_addr: u64 = 0,
    /// Every compressed instruction, decoded (indexed by its 16 bits).
    compressed: []decode.Inst,
    /// Per RAM page: its decoded instructions, if it has been executed from
    /// since it was last written. Any write to the page drops them.
    code: []?*CodePage,
    /// Dropped pages, for reuse.
    code_free: std.ArrayList(*CodePage) = .empty,
    code_drops: u64 = 0,
    /// Harts holding an LR reservation (stores must look only when > 0).
    reservations: u32 = 0,
    /// Virtio slots (index = slot; slot s is at virtio_base + s * 0x1000, line s + 1).
    slots: [virtio_slots]?virtio.Device = @splat(null),
    realtime: bool = false,
    /// With `.waiting`: when the earliest timer is due.
    wake_ns: u64 = 0,


    pub fn init(gpa: std.mem.Allocator, config: Config, host: Host) !*Machine {
        std.debug.assert(config.harts >= 1 and config.harts <= max_harts);
        const m = try gpa.create(Machine);
        const ram = try gpa.alloc(u8, @as(usize, config.ram_mib) << 20);
        @memset(ram, 0);
        const harts = try gpa.alloc(Hart, config.harts);
        for (harts, 0..) |*h, i| h.* = .{ .id = @intCast(i) };
        const compressed = try gpa.alloc(decode.Inst, 1 << 16);
        for (compressed, 0..) |*inst, raw| inst.* = if (raw & 3 == 3) .{ .op = .illegal } else decode.decode16(@intCast(raw));
        const code = try gpa.alloc(?*CodePage, ram.len / 0x1000);
        @memset(code, null);
        m.* = .{ .gpa = gpa, .host = host, .ram = ram, .harts = harts, .compressed = compressed, .code = code, .realtime = config.realtime };
        if (config.devices.len > virtio_slots) return error.TooManyDevices;
        var consoles: u8 = 0;
        for (config.devices, 0..) |spec, k| {
            var d: virtio.Device = .{ .kind = spec.kind };
            if (spec.kind == .console) {
                d.port = consoles;
                consoles += 1;
            }
            if (spec.kind == .blk) d.sectors = config.disk_bytes / 512;
            m.slots[virtio_slots - 1 - k] = d;
        }
        return m;
    }

    pub fn deinit(m: *Machine) void {
        m.gpa.free(m.ram);
        m.gpa.free(m.harts);
        for (m.code) |p| if (p) |page| m.gpa.destroy(page);
        for (m.code_free.items) |page| m.gpa.destroy(page);
        m.code_free.deinit(m.gpa);
        m.gpa.free(m.code);
        m.gpa.free(m.compressed);
        m.gpa.destroy(m);
    }

    pub fn timeNow(m: *const Machine) u64 {
        return m.ns / ns_per_tick;
    }

    // -----------------------------------------------------------------
    // Boot

    /// Load an ELF image at its physical addresses. Returns the entry point:
    /// the lowest load address, as QEMU uses for a kernel.
    pub fn loadElf(m: *Machine, image: []const u8) !u64 {
        if (image.len < 64 or !std.mem.eql(u8, image[0..4], "\x7fELF") or image[4] != 2) return error.NotElf64;
        const phoff = std.mem.readInt(u64, image[32..40], .little);
        const phentsize = std.mem.readInt(u16, image[54..56], .little);
        const phnum = std.mem.readInt(u16, image[56..58], .little);
        var lowest: u64 = std.math.maxInt(u64);
        for (0..phnum) |k| {
            const off = phoff + k * phentsize;
            if (off + 56 > image.len) return error.BadElf;
            const ph = image[@intCast(off)..][0..56];
            if (std.mem.readInt(u32, ph[0..4], .little) != 1) continue; // PT_LOAD
            const p_offset = std.mem.readInt(u64, ph[8..16], .little);
            const p_paddr = std.mem.readInt(u64, ph[24..32], .little);
            const p_filesz = std.mem.readInt(u64, ph[32..40], .little);
            const p_memsz = std.mem.readInt(u64, ph[40..48], .little);
            if (p_memsz == 0) continue;
            if (p_paddr < ram_base or p_paddr - ram_base + p_memsz > m.ram.len or p_filesz > p_memsz) return error.OutsideRam;
            if (p_offset + p_filesz > image.len) return error.BadElf;
            const dst = m.ram[@intCast(p_paddr - ram_base)..][0..@intCast(p_memsz)];
            const filesz: usize = @intCast(p_filesz);
            @memcpy(dst[0..filesz], image[@intCast(p_offset)..][0..filesz]);
            @memset(dst[filesz..], 0);
            lowest = @min(lowest, p_paddr);
        }
        if (lowest == std.math.maxInt(u64)) return error.NothingToLoad;
        return lowest;
    }

    /// Write the device tree near the top of RAM (where QEMU puts it) and
    /// start hart 0 at `entry` with a0 = 0, a1 = the tree.
    pub fn boot(m: *Machine, entry: u64) !void {
        const blob = try m.deviceTree();
        defer m.gpa.free(blob);
        const top = ram_base + m.ram.len;
        m.dtb_addr = std.mem.alignBackward(u64, top - blob.len, 2 << 20);
        @memcpy(m.ram[@intCast(m.dtb_addr - ram_base)..][0..blob.len], blob);
        const h = &m.harts[0];
        h.pc = entry;
        h.x[10] = 0;
        h.x[11] = m.dtb_addr;
        h.x[12] = 0;
        h.mode = .supervisor;
        h.started = true;
    }

    fn deviceTree(m: *Machine) ![]u8 {
        var w = dtb.Writer.init(m.gpa);
        defer w.deinit();
        const plic_phandle: u32 = 1;
        const intc = struct {
            fn phandle(i: usize) u32 {
                return @intCast(2 + i);
            }
        };
        try w.beginNode("");
        try w.cell("#address-cells", 2);
        try w.cell("#size-cells", 2);
        try w.string("compatible", "riscv-virtio");
        try w.string("model", "riscv-virtio,grain-emu");

        try w.beginNode("chosen");
        try w.string("stdout-path", "/soc/serial@10000000");
        try w.endNode();

        try w.beginNode("memory@80000000");
        try w.string("device_type", "memory");
        try w.reg64(ram_base, m.ram.len);
        try w.endNode();

        try w.beginNode("cpus");
        try w.cell("#address-cells", 1);
        try w.cell("#size-cells", 0);
        try w.cell("timebase-frequency", timebase_hz);
        var name_buf: [32]u8 = undefined;
        for (m.harts, 0..) |_, i| {
            try w.beginNode(try std.fmt.bufPrint(&name_buf, "cpu@{d}", .{i}));
            try w.string("device_type", "cpu");
            try w.cell("reg", @intCast(i));
            try w.string("status", "okay");
            try w.string("compatible", "riscv");
            try w.string("riscv,isa", "rv64imac_zicsr_zifencei_zihintpause");
            try w.string("mmu-type", "riscv,sv39");
            try w.beginNode("interrupt-controller");
            try w.cell("#interrupt-cells", 1);
            try w.empty("interrupt-controller");
            try w.string("compatible", "riscv,cpu-intc");
            try w.cell("phandle", intc.phandle(i));
            try w.endNode();
            try w.endNode();
        }
        try w.endNode();

        try w.beginNode("soc");
        try w.cell("#address-cells", 2);
        try w.cell("#size-cells", 2);
        try w.string("compatible", "simple-bus");
        try w.empty("ranges");

        try w.beginNode("test@100000");
        try w.strings_("compatible", &.{ "sifive,test1", "sifive,test0", "syscon" });
        try w.reg64(devices.finisher_base, devices.finisher_size);
        try w.endNode();

        try w.beginNode("plic@c000000");
        try w.cell("phandle", plic_phandle);
        try w.cell("riscv,ndev", devices.plic_ndev);
        try w.reg64(devices.plic_base, devices.plic_size);
        var ext: [4 * max_harts]u32 = undefined;
        for (m.harts, 0..) |_, i| {
            ext[4 * i ..][0..4].* = .{ intc.phandle(i), 11, intc.phandle(i), 9 };
        }
        try w.cells("interrupts-extended", ext[0 .. 4 * m.harts.len]);
        try w.empty("interrupt-controller");
        try w.strings_("compatible", &.{ "sifive,plic-1.0.0", "riscv,plic0" });
        try w.cell("#address-cells", 0);
        try w.cell("#interrupt-cells", 1);
        try w.endNode();

        try w.beginNode("serial@10000000");
        try w.cell("interrupts", devices.uart_irq);
        try w.cell("interrupt-parent", plic_phandle);
        try w.cell("clock-frequency", 0x384000);
        try w.reg64(devices.uart_base, devices.uart_size);
        try w.string("compatible", "ns16550a");
        try w.endNode();

        // Highest address first, as QEMU lists them.
        var slot: usize = virtio_slots;
        while (slot > 0) {
            slot -= 1;
            const base = virtio_base + slot * 0x1000;
            try w.beginNode(try std.fmt.bufPrint(&name_buf, "virtio_mmio@{x}", .{base}));
            try w.cell("interrupts", @intCast(slot + 1));
            try w.cell("interrupt-parent", plic_phandle);
            try w.reg64(base, 0x1000);
            try w.string("compatible", "virtio,mmio");
            try w.endNode();
        }
        try w.endNode(); // soc
        try w.endNode(); // root
        return w.finish(m.gpa, 0);
    }

    // -----------------------------------------------------------------
    // Running

    /// Run until the guest exits, every hart idles with nothing due, or
    /// `budget` instructions have run.
    pub fn run(m: *Machine, budget: u64) Stop {
        const end = m.ns +| budget;
        while (m.exit_code == null) {
            if (m.ns >= end) return .budget;
            var ran = false;
            if (m.realtime) m.ns = @max(m.ns, m.host.now_ns(m.host.ctx));
            for (m.harts) |*h| {
                if (!h.started) continue;
                if (h.waiting) {
                    if (h.pendingInterrupts(m) == 0) continue;
                    h.waiting = false;
                    h.recheck();
                }
                ran = true;
                h.yield = false;
                var n: u32 = 0;
                while (n < quantum and !h.yield) : (n += 1) {
                    h.step(m);
                    m.ns += 1;
                }
                if (m.exit_code != null) break;
            }
            if (!ran) {
                // Everyone waits: jump to the earliest timer.
                var next: u64 = std.math.maxInt(u64);
                for (m.harts) |*h| if (h.started) {
                    next = @min(next, h.timer);
                };
                if (next == std.math.maxInt(u64)) return .idle;
                if (m.realtime) {
                    m.wake_ns = next *| ns_per_tick;
                    return .waiting;
                }
                m.ns = @max(m.ns, next *| ns_per_tick);
            }
        }
        return .exited;
    }

    /// The decoded-instruction page for the RAM page at `page`.
    pub fn codePage(m: *Machine, page: u64) !?*CodePage {
        if (page < ram_base or page - ram_base >= m.ram.len) return null;
        const idx = (page - ram_base) >> 12;
        if (m.code[@intCast(idx)]) |p| return p;
        const p = m.code_free.pop() orelse try m.gpa.create(CodePage);
        @memset(p, .{ .op = .none });
        m.code[@intCast(idx)] = p;
        return p;
    }

    /// RAM at physical page `page` (any address in it) was written: its
    /// decoded instructions, if any, are stale.
    pub inline fn wroteRam(m: *Machine, pa: u64) void {
        const idx = (pa -% ram_base) >> 12;
        if (idx < m.code.len) if (m.code[@intCast(idx)]) |p| m.dropCode(@intCast(idx), p);
    }

    fn dropCode(m: *Machine, idx: usize, p: *CodePage) void {
        m.code[idx] = null;
        m.code_drops += 1;
        m.code_free.append(m.gpa, p) catch m.gpa.destroy(p);
        for (m.harts) |*h| if (h.fetch_vpn != std.math.maxInt(u64) and h.fetch_code == p) {
            h.fetch_vpn = std.math.maxInt(u64);
        };
    }

    fn dmaWritten(ctx: *anyopaque, pa: u64, len: u64) void {
        const m: *Machine = @ptrCast(@alignCast(ctx));
        var page = pa & ~@as(u64, 0xfff);
        while (page < pa + len) : (page += 0x1000) m.wroteRam(page);
    }

    fn updateIrqs(m: *Machine) void {
        m.plic.setLevel(devices.uart_irq, m.uart.interrupt());
        for (&m.slots, 0..) |*slot, s| if (slot.*) |*d| {
            m.plic.setLevel(@intCast(s + 1), d.interrupt_status != 0);
        };
        m.interruptsChanged();
    }

    /// An interrupt source changed: every hart looks again.
    fn interruptsChanged(m: *Machine) void {
        for (m.harts) |*h| h.recheck();
    }

    pub fn setReservation(m: *Machine, h: *Hart, pa: ?u64) void {
        if (h.reservation != null) m.reservations -= 1;
        h.reservation = pa;
        if (pa != null) m.reservations += 1;
    }

    /// The host memory of the 4 KiB RAM page at `page`, if it is RAM.
    pub fn ramPage(m: *Machine, page: u64) ?[*]u8 {
        const s = m.ramSlice(page, 0x1000) orelse return null;
        return s.ptr;
    }

    fn dma(m: *Machine) virtio.Dma {
        return .{ .ram = m.ram, .base = ram_base, .ctx = m, .written = dmaWritten };
    }

    fn deviceIo(m: *Machine) virtio.Device.Io {
        return .{
            .ctx = m.host.ctx,
            .entropy = m.host.entropy,
            .port_write = m.host.port_write,
            .disk_read = m.host.disk_read,
            .disk_write = m.host.disk_write,
            .disk_flush = m.host.disk_flush,
        };
    }

    /// Bytes from outside for virtio console `port`. Returns how many it
    /// took (the rest should be offered again later).
    pub fn consoleInput(m: *Machine, port: u8, bytes: []const u8) usize {
        for (&m.slots) |*slot| if (slot.*) |*d| {
            if (d.kind != .console or d.port != port) continue;
            const n = d.receive(bytes);
            d.deliver(m.dma());
            m.updateIrqs();
            return n;
        };
        return bytes.len;
    }

    /// Bytes for the UART's receiver (the serial console's input).
    pub fn serialInput(m: *Machine, bytes: []const u8) usize {
        var n: usize = 0;
        while (n < bytes.len and m.uart.receive(bytes[n])) n += 1;
        m.updateIrqs();
        return n;
    }

    fn slotAt(m: *Machine, pa: u64) ?*virtio.Device {
        const s = (pa - virtio_base) / 0x1000;
        return if (m.slots[@intCast(s)]) |*d| d else null;
    }

    fn console(m: *Machine, bytes: []const u8) void {
        m.host.console(m.host.ctx, bytes);
    }

    // -----------------------------------------------------------------
    // Physical memory

    fn ramSlice(m: *Machine, pa: u64, size: u64) ?[]u8 {
        if (pa < ram_base) return null;
        const off = pa - ram_base;
        if (off + size > m.ram.len) return null;
        return m.ram[@intCast(off)..][0..@intCast(size)];
    }

    pub fn ramLoad(m: *Machine, pa: u64, size: u8) ?u64 {
        const s = m.ramSlice(pa, size) orelse return null;
        return switch (size) {
            1 => s[0],
            2 => std.mem.readInt(u16, s[0..2], .little),
            4 => std.mem.readInt(u32, s[0..4], .little),
            8 => std.mem.readInt(u64, s[0..8], .little),
            else => unreachable,
        };
    }

    pub fn ramStore(m: *Machine, pa: u64, size: u8, v: u64) bool {
        const s = m.ramSlice(pa, size) orelse return false;
        switch (size) {
            1 => s[0] = @truncate(v),
            2 => std.mem.writeInt(u16, s[0..2], @truncate(v), .little),
            4 => std.mem.writeInt(u32, s[0..4], @truncate(v), .little),
            8 => std.mem.writeInt(u64, s[0..8], v, .little),
            else => unreachable,
        }
        m.wroteRam(pa);
        // A store ends other harts' reservations on that doubleword.
        if (m.reservations > 0) for (m.harts) |*h| if (h.reservation) |r| {
            if (r >> 3 == pa >> 3) m.setReservation(h, null);
        };
        return true;
    }

    pub fn ramLoad64(m: *Machine, pa: u64) ?u64 {
        return m.ramLoad(pa, 8);
    }

    pub fn ramStore64(m: *Machine, pa: u64, v: u64) bool {
        return m.ramStore(pa, 8, v);
    }

    pub fn fetch16(m: *Machine, pa: u64) ?u16 {
        const v = m.ramLoad(pa, 2) orelse return null;
        return @truncate(v);
    }

    pub fn load(m: *Machine, pa: u64, size: u8) ?u64 {
        if (pa >= ram_base) return m.ramLoad(pa, size);
        if (inRange(pa, devices.plic_base, devices.plic_size)) {
            if (size != 4) return null;
            const v = m.plic.read(pa - devices.plic_base);
            m.interruptsChanged(); // a claim changes what is pending
            return v;
        }
        if (inRange(pa, devices.uart_base, devices.uart_size)) {
            const v = m.uart.read(pa - devices.uart_base);
            m.updateIrqs();
            return v;
        }
        if (inRange(pa, virtio_base, virtio_slots * 0x1000)) {
            const off = (pa - virtio_base) % 0x1000;
            const word = if (m.slotAt(pa)) |d| d.read(off & ~@as(u64, 3)) else emptyVirtio(off & ~@as(u64, 3));
            return switch (size) {
                4 => word,
                1, 2 => (word >> @intCast(8 * (off & 3))) & ((@as(u64, 1) << @intCast(8 * size)) - 1),
                else => null,
            };
        }
        if (inRange(pa, devices.finisher_base, devices.finisher_size)) return 0;
        return null;
    }

    pub fn store(m: *Machine, pa: u64, size: u8, v: u64) bool {
        if (pa >= ram_base) return m.ramStore(pa, size, v);
        if (inRange(pa, devices.plic_base, devices.plic_size)) {
            if (size != 4) return false;
            m.plic.write(pa - devices.plic_base, @truncate(v));
            m.interruptsChanged();
            return true;
        }
        if (inRange(pa, devices.uart_base, devices.uart_size)) {
            if (m.uart.write(pa - devices.uart_base, @truncate(v))) |c| m.console(&.{c});
            m.updateIrqs();
            return true;
        }
        if (inRange(pa, virtio_base, virtio_slots * 0x1000)) {
            const d = m.slotAt(pa) orelse return true;
            if (size != 4) return true;
            if (d.write((pa - virtio_base) % 0x1000, @truncate(v))) |queue| d.process(queue, m.dma(), m.deviceIo());
            m.updateIrqs();
            return true;
        }
        if (inRange(pa, devices.finisher_base, devices.finisher_size)) {
            switch (devices.finisherWrite(@truncate(v))) {
                .pass, .reset => m.exit(0),
                .fail => |code| m.exit(code),
                .none => {},
            }
            return true;
        }
        return false;
    }

    fn exit(m: *Machine, code: u32) void {
        if (m.exit_code == null) m.exit_code = code;
        for (m.harts) |*h| h.yield = true;
    }

    // -----------------------------------------------------------------
    // SBI (v2.0): base, TIME, IPI, RFENCE, HSM, SRST, DBCN, legacy console

    const ext_base = 0x10;
    const ext_time = 0x54494D45;
    const ext_ipi = 0x735049;
    const ext_rfence = 0x52464E43;
    const ext_hsm = 0x48534D;
    const ext_srst = 0x53525354;
    const ext_dbcn = 0x4442434E;

    const sbi_not_supported: i64 = -2;
    const sbi_invalid_param: i64 = -3;
    const sbi_already: i64 = -6;

    pub fn sbi(m: *Machine, h: *Hart) void {
        const ext = h.x[17];
        const fid = h.x[16];
        const a0 = h.x[10];
        const a1 = h.x[11];
        const a2 = h.x[12];
        var err: i64 = 0;
        var value: u64 = 0;
        switch (ext) {
            0x00 => { // legacy set_timer
                h.setTimer(a0);
                h.x[10] = 0;
                return;
            },
            0x01 => { // legacy console_putchar
                m.console(&.{@truncate(a0)});
                h.x[10] = 0;
                return;
            },
            ext_base => switch (fid) {
                0 => value = 0x0200_0000, // SBI 2.0
                1 => value = 0x4752, // implementation id: grain-emu
                2 => value = 1,
                3 => value = @intFromBool(switch (a0) {
                    ext_base, ext_time, ext_ipi, ext_rfence, ext_hsm, ext_srst, ext_dbcn => true,
                    else => false,
                }),
                4, 5, 6 => value = 0,
                else => err = sbi_not_supported,
            },
            ext_time => if (fid == 0) {
                h.setTimer(a0);
            } else {
                err = sbi_not_supported;
            },
            ext_ipi => if (fid == 0) {
                for (m.harts) |*t| if (inMask(a0, a1, t.id)) {
                    t.sip |= hart_mod.ssip;
                    t.recheck();
                };
            } else {
                err = sbi_not_supported;
            },
            ext_rfence => switch (fid) {
                0 => {}, // remote fence.i: no instruction cache to flush
                1, 2 => for (m.harts) |*t| if (inMask(a0, a1, t.id)) t.flushTlb(),
                else => err = sbi_not_supported,
            },
            ext_hsm => switch (fid) {
                0 => {
                    if (a0 >= m.harts.len) {
                        err = sbi_invalid_param;
                    } else {
                        const t = &m.harts[@intCast(a0)];
                        if (t.started) {
                            err = sbi_already;
                        } else {
                            if (t.reservation != null) m.setReservation(t, null);
                            t.* = .{ .id = t.id };
                            t.pc = a1;
                            t.x[10] = a0;
                            t.x[11] = a2;
                            t.started = true;
                        }
                    }
                },
                1 => {
                    h.started = false;
                    h.yield = true;
                },
                2 => {
                    if (a0 >= m.harts.len) err = sbi_invalid_param else value = if (m.harts[@intCast(a0)].started) 0 else 1;
                },
                else => err = sbi_not_supported,
            },
            ext_srst => if (fid == 0) m.exit(0) else {
                err = sbi_not_supported;
            },
            ext_dbcn => switch (fid) {
                0 => {
                    // console_write(num_bytes, base_lo, base_hi): physical memory
                    if (m.ramSlice(a1, a0)) |bytes| {
                        m.console(bytes);
                        value = a0;
                    } else err = sbi_invalid_param;
                },
                1 => value = 0, // console_read: nothing
                2 => m.console(&.{@truncate(a0)}),
                else => err = sbi_not_supported,
            },
            else => err = sbi_not_supported,
        }
        h.x[10] = @bitCast(err);
        h.x[11] = value;
    }
};

fn inMask(mask: u64, base: u64, id: u32) bool {
    if (base == std.math.maxInt(u64)) return true;
    if (id < base or id - base >= 64) return false;
    return (mask >> @intCast(id - base)) & 1 != 0;
}

fn inRange(pa: u64, base: u64, size: u64) bool {
    return pa >= base and pa - base < size;
}

/// An empty virtio-mmio slot: version 2, device id 0 (nothing there).
fn emptyVirtio(off: u64) u64 {
    return switch (off % 0x1000) {
        0x000 => 0x74726976,
        0x004 => 2,
        0x00c => 0x554d4551,
        else => 0,
    };
}
