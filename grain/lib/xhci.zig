//! xHCI, the USB host controller, with what a personal desktop needs on it:
//! keyboards and pointing devices (USB HID).
//!
//! Bring-up: reset; a device-context array, a command ring and one event
//! ring (all single pages); run. Then each connected port is reset, given a
//! slot, addressed, and asked for its configuration; a HID interface's
//! interrupt-IN endpoint is configured and kept fed with one transfer. Its
//! reports come back as events: a keyboard's boot report (modifiers and up
//! to six keys) turned into Linux key codes and presses and releases, a
//! tablet's absolute position and buttons. So Surf takes USB input exactly
//! as it takes virtio input.
//!
//! Rings are a page of 256 TRBs, the last a link back to the first that
//! flips the cycle bit. Commands and control transfers wait for their
//! completion by watching the event ring; reports arrive in it too.
const std = @import("std");
const grain = @import("grain.zig");

pub const Page = struct { va: usize, pa: u64 };
pub const Error = error{ Timeout, CommandFailed, TransferFailed, NoPages, Unsupported };

const ring_trbs = 256;

const Trb = extern struct { param: u64, status: u32, control: u32 };

const Type = struct {
    const normal: u32 = 1;
    const setup: u32 = 2;
    const data: u32 = 3;
    const status: u32 = 4;
    const link: u32 = 6;
    const enable_slot: u32 = 9;
    const address_device: u32 = 11;
    const configure_endpoint: u32 = 12;
    const transfer_event: u32 = 32;
    const command_completion: u32 = 33;
};

const cycle: u32 = 1;
const ioc: u32 = 1 << 5;
const idt: u32 = 1 << 6;

fn trbType(t: Trb) u32 {
    return (t.control >> 10) & 0x3f;
}

/// A producer ring (commands, or one endpoint's transfers).
const Ring = struct {
    page: Page,
    index: u16 = 0,
    cycle: u1 = 1,

    fn init(p: Page) Ring {
        @memset(@as([*]u8, @ptrFromInt(p.va))[0..4096], 0);
        const trbs: *volatile [ring_trbs]Trb = @ptrFromInt(p.va);
        // The last TRB links back to the start and toggles the cycle.
        trbs[ring_trbs - 1] = .{ .param = p.pa, .status = 0, .control = Type.link << 10 | 1 << 1 };
        return .{ .page = p };
    }

    /// Put a TRB on the ring; returns its physical address.
    fn push(r: *Ring, t: Trb) u64 {
        const trbs: *volatile [ring_trbs]Trb = @ptrFromInt(r.page.va);
        const at = r.page.pa + @as(u64, r.index) * 16;
        var x = t;
        x.control = (x.control & ~cycle) | r.cycle;
        trbs[r.index] = x;
        r.index += 1;
        if (r.index == ring_trbs - 1) {
            // Hand the link over too, then wrap.
            const l = &trbs[ring_trbs - 1];
            l.control = (l.control & ~cycle) | r.cycle;
            r.index = 0;
            r.cycle ^= 1;
        }
        return at;
    }
};

/// What a HID device said.
pub const Event = union(enum) {
    /// A key went down or up (Linux key codes; shift keys included).
    key: struct { code: u16, down: bool },
    /// An absolute pointer: 0..0x7fff on each axis; button bits.
    pointer: struct { x: u16, y: u16, buttons: u8 },
};

pub const pointer_max: u16 = 0x7fff;

const Kind = enum { keyboard, tablet };

/// What Grain needs of a USB configuration: its first HID interface and
/// that interface's interrupt-IN endpoint.
pub const Hid = struct {
    config_value: u8,
    interface: u8,
    kind: Kind,
    endpoint: u8,
    max_packet: u16,
    interval: u8,
};

/// Walk a configuration descriptor (and the interface and endpoint
/// descriptors after it) as the device sent it: nothing in it is trusted,
/// every field is read only inside its own descriptor's length.
pub fn parseConfiguration(cfg: []const u8) ?Hid {
    if (cfg.len < 9 or cfg[1] != 2) return null;
    var hid: ?Hid = null;
    var i: usize = 0;
    while (i + 2 <= cfg.len) {
        const len = cfg[i];
        if (len < 2 or i + len > cfg.len) break;
        const d = cfg[i..][0..len];
        switch (d[1]) {
            4 => if (hid == null and len >= 9 and d[5] == 3) { // a HID interface
                hid = .{ .config_value = cfg[5], .interface = d[2], .kind = if (d[7] == 1) .keyboard else .tablet, .endpoint = 0, .max_packet = 8, .interval = 10 };
            },
            5 => if (hid) |*h| if (h.endpoint == 0 and len >= 7 and d[2] & 0x80 != 0 and d[3] & 3 == 3) {
                h.endpoint = d[2];
                h.max_packet = std.mem.readInt(u16, d[4..6], .little) & 0x7ff;
                h.interval = d[6];
            },
            else => {},
        }
        i += len;
    }
    const h = hid orelse return null;
    if (h.endpoint == 0 or h.max_packet == 0) return null;
    return h;
}

const Device = struct {
    slot: u8,
    kind: Kind,
    dci: u5,
    ring: Ring,
    report: Page,
    last: [8]u8 = @splat(0),
};

pub const Xhci = struct {
    base: usize,
    op: usize,
    rt: usize,
    db: usize,
    ctx_size: usize,
    dcbaa: Page,
    cmd: Ring,
    events: Page,
    ev_index: u16 = 0,
    ev_cycle: u1 = 1,
    /// Pages for device contexts, rings and buffers, handed out in turn.
    pages: []const Page,
    next_page: usize,
    devices: [4]Device = undefined,
    device_count: usize = 0,
    /// The pending transfer completions we already saw for the control
    /// transfer under way.
    signal: grain.CPtr,
    irq: grain.CPtr,

    /// `pages`: at least 4 + 6 per device. The controller's registers are `base`.
    pub fn init(base: usize, pages: []const Page, signal: grain.CPtr, irq: grain.CPtr) Error!Xhci {
        if (pages.len < 4) return error.NoPages;
        const caplength = @as(*volatile u8, @ptrFromInt(base)).*;
        var x: Xhci = .{
            .base = base,
            .op = base + caplength,
            .rt = base + (rd(base, 0x18) & ~@as(u32, 0x1f)),
            .db = base + (rd(base, 0x14) & ~@as(u32, 3)),
            .ctx_size = if (rd(base, 0x10) & 4 != 0) 64 else 32,
            .dcbaa = pages[0],
            .cmd = Ring.init(pages[1]),
            .events = pages[2],
            .pages = pages,
            .next_page = 4,
            .signal = signal,
            .irq = irq,
        };
        const hcs2 = rd(base, 0x08);
        if (((hcs2 >> 21) & 0x1f) | ((hcs2 >> 27) & 0x1f) != 0) return error.Unsupported; // wants scratchpads
        // Stop and reset.
        x.opw(0x00, x.opr(0x00) & ~@as(u32, 1));
        try x.until(0x04, 1, 1); // halted
        x.opw(0x00, 2);
        try x.until(0x00, 2, 0); // reset done
        try x.until(0x04, 1 << 11, 0); // controller ready
        const slots = rd(base, 0x04) & 0xff;
        x.opw(0x38, @min(slots, 8));
        @memset(@as([*]u8, @ptrFromInt(x.dcbaa.va))[0..4096], 0);
        x.opw64(0x30, x.dcbaa.pa);
        x.opw64(0x18, x.cmd.page.pa | 1);
        // One event ring segment, described by a one-entry table.
        @memset(@as([*]u8, @ptrFromInt(x.events.va))[0..4096], 0);
        const erst: *volatile [2]u64 = @ptrFromInt(pages[3].va);
        erst[0] = x.events.pa;
        erst[1] = ring_trbs;
        const ir = x.rt + 0x20;
        wr(ir, 0x08, 1);
        wr64(ir, 0x18, x.events.pa);
        wr64(ir, 0x10, pages[3].pa);
        wr(ir, 0x04, 0); // no moderation
        wr(ir, 0x00, 0b11); // clear pending, enable
        x.opw(0x00, 1 | 1 << 2); // run, interrupts on
        try x.until(0x04, 1, 0);
        return x;
    }

    fn rd(base: usize, off: usize) u32 {
        return @as(*volatile u32, @ptrFromInt(base + off)).*;
    }
    fn wr(base: usize, off: usize, v: u32) void {
        @as(*volatile u32, @ptrFromInt(base + off)).* = v;
    }
    fn wr64(base: usize, off: usize, v: u64) void {
        wr(base, off, @truncate(v));
        wr(base, off + 4, @truncate(v >> 32));
    }
    fn opr(x: *const Xhci, off: usize) u32 {
        return rd(x.op, off);
    }
    fn opw(x: *const Xhci, off: usize, v: u32) void {
        wr(x.op, off, v);
    }
    fn opw64(x: *const Xhci, off: usize, v: u64) void {
        wr64(x.op, off, v);
    }

    fn until(x: *const Xhci, off: usize, mask: u32, want: u32) Error!void {
        var spins: usize = 0;
        while (x.opr(off) & mask != (if (want != 0) mask else 0)) : (spins += 1) {
            if (spins > 5_000_000) return error.Timeout;
            grain.yield();
        }
    }

    fn page(x: *Xhci) Error!Page {
        if (x.next_page == x.pages.len) return error.NoPages;
        const p = x.pages[x.next_page];
        x.next_page += 1;
        @memset(@as([*]u8, @ptrFromInt(p.va))[0..4096], 0);
        return p;
    }

    // --- The event ring ----------------------------------------------------

    /// The next event, if the controller has posted one.
    fn nextEvent(x: *Xhci) ?Trb {
        grain.fence();
        const trbs: *volatile [ring_trbs]Trb = @ptrFromInt(x.events.va);
        const t = trbs[x.ev_index];
        if (@as(u1, @truncate(t.control)) != x.ev_cycle) return null;
        x.ev_index += 1;
        if (x.ev_index == ring_trbs) {
            x.ev_index = 0;
            x.ev_cycle ^= 1;
        }
        // Tell the controller how far we have read (and clear "busy").
        wr64(x.rt + 0x20, 0x18, (x.events.pa + @as(u64, x.ev_index) * 16) | 1 << 3);
        return t;
    }

    /// Wait for the completion of the TRB at `trb` (a command or a transfer),
    /// keeping any reports that arrive meanwhile.
    fn waitFor(x: *Xhci, kind: u32, trb: u64) Error!Trb {
        var spins: usize = 0;
        while (true) : (spins += 1) {
            while (x.nextEvent()) |e| {
                if (trbType(e) == kind and e.param == trb) {
                    const code = e.status >> 24;
                    if (code != 1 and code != 13) return if (kind == Type.command_completion) error.CommandFailed else error.TransferFailed;
                    return e;
                }
                x.held(e);
            }
            if (spins > 5_000_000) return error.Timeout;
            grain.yield();
        }
    }

    fn command(x: *Xhci, t: Trb) Error!Trb {
        const at = x.cmd.push(t);
        wr(x.db, 0, 0);
        return x.waitFor(Type.command_completion, at);
    }

    fn doorbell(x: *Xhci, slot: u8, target: u32) void {
        wr(x.db, @as(usize, slot) * 4, target);
    }

    // --- Devices -----------------------------------------------------------

    /// Find, address and configure every HID keyboard and tablet on the
    /// root ports. Returns how many it found.
    pub fn probe(x: *Xhci) Error!usize {
        const ports = rd(x.base, 0x04) >> 24;
        var p: u8 = 1;
        while (p <= ports) : (p += 1) {
            const sc_off = 0x400 + (@as(usize, p) - 1) * 0x10;
            var sc = x.opr(sc_off);
            if (sc & 1 == 0) continue; // nothing connected
            if (sc & 2 == 0) {
                // A USB 2 port: reset it, which enables it.
                x.opw(sc_off, (sc & 0x0e00_c3e0) | 1 << 4);
                var spins: usize = 0;
                while (x.opr(sc_off) & (1 << 21) == 0) : (spins += 1) {
                    if (spins > 5_000_000) return error.Timeout;
                    grain.yield();
                }
                sc = x.opr(sc_off);
                x.opw(sc_off, (sc & 0x0e00_c3e0) | 1 << 21); // acknowledge the reset
            }
            sc = x.opr(sc_off);
            if (sc & 2 == 0) continue;
            const speed: u4 = @truncate(sc >> 10);
            x.attach(p, speed) catch continue;
        }
        return x.device_count;
    }

    fn inputContext(x: *Xhci, input: Page, index: usize) [*]volatile u32 {
        return @ptrFromInt(input.va + index * x.ctx_size);
    }

    fn attach(x: *Xhci, port: u8, speed: u4) Error!void {
        if (x.device_count == x.devices.len) return;
        const done = try x.command(.{ .param = 0, .status = 0, .control = Type.enable_slot << 10 });
        const slot: u8 = @truncate(done.control >> 24);
        const output = try x.page();
        const input = try x.page();
        var ep0 = Ring.init(try x.page());
        const buf = try x.page();
        const dcbaa: *volatile [256]u64 = @ptrFromInt(x.dcbaa.va);
        dcbaa[slot] = output.pa;
        const mps: u32 = switch (speed) {
            2 => 8, // low
            3 => 64, // high
            4 => 512, // super
            else => 8, // full: 8 until the descriptor says otherwise
        };
        // Address the device: slot and default control endpoint.
        const ctl = x.inputContext(input, 0);
        ctl[1] = 0b11; // add slot, ep0
        const sl = x.inputContext(input, 1);
        sl[0] = @as(u32, speed) << 20 | 1 << 27;
        sl[1] = @as(u32, port) << 16;
        const e0 = x.inputContext(input, 2);
        e0[1] = 3 << 1 | 4 << 3 | mps << 16; // three retries, control
        e0[2] = @truncate(ep0.page.pa | 1);
        e0[3] = @truncate(ep0.page.pa >> 32);
        e0[4] = 8;
        _ = try x.command(.{ .param = input.pa, .status = 0, .control = Type.address_device << 10 | @as(u32, slot) << 24 });

        // Its configuration: interfaces and endpoints.
        const cfg: [*]const u8 = @ptrFromInt(buf.va);
        try x.control(slot, &ep0, 0x80, 6, 0x0200, 0, 9, buf.pa);
        const total = @min(std.mem.readInt(u16, cfg[2..4], .little), 256);
        try x.control(slot, &ep0, 0x80, 6, 0x0200, 0, total, buf.pa);
        const hid = parseConfiguration(cfg[0..total]) orelse return error.Unsupported;
        const k = hid.kind;
        const config_value = hid.config_value;
        const interface = hid.interface;
        const ep_addr = hid.endpoint;
        const ep_mps = hid.max_packet;
        const ep_interval = hid.interval;
        try x.control(slot, &ep0, 0x00, 9, config_value, 0, 0, 0); // SET_CONFIGURATION
        if (k == .keyboard) try x.control(slot, &ep0, 0x21, 0x0b, 0, interface, 0, 0); // SET_PROTOCOL: boot

        // Its interrupt-IN endpoint.
        const dci: u5 = @intCast((ep_addr & 0xf) * 2 + 1);
        const ring = Ring.init(try x.page());
        @memset(@as([*]volatile u8, @ptrFromInt(input.va))[0 .. 33 * x.ctx_size], 0);
        ctl[1] = 1 | @as(u32, 1) << dci;
        sl[0] = @as(u32, speed) << 20 | @as(u32, dci) << 27;
        sl[1] = @as(u32, port) << 16;
        const ep = x.inputContext(input, @as(usize, dci) + 1);
        // Interval: 2^n units of 125 us; full and low speed count in frames.
        const interval: u32 = if (speed >= 3) @max(ep_interval, 1) - 1 else std.math.log2_int(u32, @as(u32, @max(ep_interval, 1)) * 8);
        ep[0] = @as(u32, @min(interval, 15)) << 16;
        ep[1] = 3 << 1 | 7 << 3 | @as(u32, ep_mps) << 16; // interrupt IN
        ep[2] = @truncate(ring.page.pa | 1);
        ep[3] = @truncate(ring.page.pa >> 32);
        ep[4] = ep_mps;
        _ = try x.command(.{ .param = input.pa, .status = 0, .control = Type.configure_endpoint << 10 | @as(u32, slot) << 24 });

        x.devices[x.device_count] = .{ .slot = slot, .kind = k, .dci = dci, .ring = ring, .report = buf };
        x.device_count += 1;
        x.feed(&x.devices[x.device_count - 1]);
    }

    /// A control transfer on endpoint 0 (`length` bytes in, or none).
    fn control(x: *Xhci, slot: u8, ep0: *Ring, request_type: u8, request: u8, value: u16, index: u16, length: u16, buf: u64) Error!void {
        const setup = @as(u64, request_type) | @as(u64, request) << 8 | @as(u64, value) << 16 | @as(u64, index) << 32 | @as(u64, length) << 48;
        const transfer_type: u32 = if (length == 0) 0 else 3; // none, or in
        _ = ep0.push(.{ .param = setup, .status = 8, .control = Type.setup << 10 | idt | transfer_type << 16 });
        if (length > 0) _ = ep0.push(.{ .param = buf, .status = length, .control = Type.data << 10 | 1 << 16 });
        const status_dir: u32 = if (length > 0) 0 else 1; // the other way
        const at = ep0.push(.{ .param = 0, .status = 0, .control = Type.status << 10 | ioc | status_dir << 16 });
        x.doorbell(slot, 1);
        _ = try x.waitFor(Type.transfer_event, at);
    }

    /// Keep one transfer waiting on a device's interrupt endpoint.
    fn feed(x: *Xhci, d: *Device) void {
        _ = d.ring.push(.{ .param = d.report.pa, .status = 8, .control = Type.normal << 10 | ioc | 1 << 2 });
        x.doorbell(d.slot, d.dci);
    }

    // --- Reports -----------------------------------------------------------

    var pending: [32]Event = undefined;
    var pending_len: usize = 0;

    fn emit(e: Event) void {
        if (pending_len < pending.len) {
            pending[pending_len] = e;
            pending_len += 1;
        }
    }

    /// An event that is not the completion being waited for: a report.
    fn held(x: *Xhci, e: Trb) void {
        if (trbType(e) != Type.transfer_event) return;
        const slot: u8 = @truncate(e.control >> 24);
        for (x.devices[0..x.device_count]) |*d| if (d.slot == slot) {
            const report: *const [8]u8 = @ptrFromInt(d.report.va);
            switch (d.kind) {
                .keyboard => keyboardReport(d, report.*),
                .tablet => emit(.{ .pointer = .{
                    .buttons = report[0],
                    .x = std.mem.readInt(u16, report[1..3], .little),
                    .y = std.mem.readInt(u16, report[3..5], .little),
                } }),
            }
            x.feed(d);
            return;
        };
    }

    fn keyboardReport(d: *Device, r: [8]u8) void {
        // Shift keys are modifier bits; letters are usages in bytes 2..7.
        const shifts = [_]struct { bit: u8, code: u16 }{ .{ .bit = 1 << 1, .code = 42 }, .{ .bit = 1 << 5, .code = 54 } };
        for (shifts) |s| if ((r[0] ^ d.last[0]) & s.bit != 0) emit(.{ .key = .{ .code = s.code, .down = r[0] & s.bit != 0 } });
        for (d.last[2..]) |u| if (u != 0 and std.mem.indexOfScalar(u8, r[2..], u) == null) {
            if (linuxCode(u)) |c| emit(.{ .key = .{ .code = c, .down = false } });
        };
        for (r[2..]) |u| if (u > 3 and std.mem.indexOfScalar(u8, d.last[2..], u) == null) {
            if (linuxCode(u)) |c| emit(.{ .key = .{ .code = c, .down = true } });
        };
        d.last = r;
    }

    /// Reports that arrived since the last call (after the controller's
    /// interrupt, or at any time).
    pub fn poll(x: *Xhci, out: []Event) []Event {
        // Clear the interrupt: the status bit, then the interrupter's.
        x.opw(0x04, 1 << 3);
        wr(x.rt + 0x20, 0x00, 0b11);
        while (x.nextEvent()) |e| x.held(e);
        const n = @min(pending_len, out.len);
        @memcpy(out[0..n], pending[0..n]);
        pending_len = 0;
        return out[0..n];
    }
};

/// HID keyboard usage to Linux key code (US layout; letters, digits,
/// punctuation, enter, escape, backspace, tab, space).
pub fn linuxCode(usage: u8) ?u16 {
    const letters = [26]u16{ 30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44 };
    if (usage >= 0x04 and usage <= 0x1d) return letters[usage - 0x04];
    if (usage >= 0x1e and usage <= 0x27) return 2 + @as(u16, usage - 0x1e); // 1..9, 0
    return switch (usage) {
        0x28 => 28, // enter
        0x29 => 1, // escape
        0x2a => 14, // backspace
        0x2b => 15, // tab
        0x2c => 57, // space
        0x2d => 12, // -
        0x2e => 13, // =
        0x2f => 26, // [
        0x30 => 27, // ]
        0x31 => 43, // backslash
        0x33 => 39, // ;
        0x34 => 40, // '
        0x35 => 41, // `
        0x36 => 51, // ,
        0x37 => 52, // .
        0x38 => 53, // /
        else => null,
    };
}

test "a keyboard's configuration, and damaged ones" {
    // QEMU's usb-kbd: configuration, interface (HID, boot, keyboard), HID
    // class descriptor, interrupt-IN endpoint 1.
    const kbd = [_]u8{ 9, 2, 34, 0, 1, 1, 0, 0xa0, 50, 9, 4, 0, 0, 1, 3, 1, 1, 0, 9, 0x21, 0x11, 1, 0, 1, 0x22, 63, 0, 7, 5, 0x81, 3, 8, 0, 7 };
    const h = parseConfiguration(&kbd).?;
    try std.testing.expectEqual(Kind.keyboard, h.kind);
    try std.testing.expectEqual(@as(u8, 0x81), h.endpoint);
    try std.testing.expectEqual(@as(u16, 8), h.max_packet);
    try std.testing.expectEqual(@as(u8, 1), h.config_value);
    // The endpoint descriptor cut short, or claiming to run past the end.
    try std.testing.expect(parseConfiguration(kbd[0..30]) == null);
    var long = kbd;
    long[27] = 40;
    try std.testing.expect(parseConfiguration(&long) == null);
}

test "HID usages map to the Linux codes the virtio keyboard sends" {
    const vin = @import("virtio_input.zig");
    const pairs = [_]struct { usage: u8, char: u8 }{ .{ .usage = 0x04, .char = 'a' }, .{ .usage = 0x1d, .char = 'z' }, .{ .usage = 0x1e, .char = '1' }, .{ .usage = 0x27, .char = '0' }, .{ .usage = 0x28, .char = '\n' }, .{ .usage = 0x2c, .char = ' ' }, .{ .usage = 0x38, .char = '/' }, .{ .usage = 0x0c, .char = 'i' }, .{ .usage = 0x1a, .char = 'w' } };
    for (pairs) |p| try std.testing.expectEqual(p.char, vin.char(linuxCode(p.usage).?, false));
    try std.testing.expect(linuxCode(0x3a) == null); // F1
}
