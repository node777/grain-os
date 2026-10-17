//! virtio-console driver: serves console.v1 by writing to the device's
//! port 0 transmit queue.
//!
//! Writes arrive in pieces of up to 256 bytes, and several clients write at once, so
//! the driver keeps a line buffer per client (by badge) and sends only whole
//! lines (or a full buffer). Lines from different clients never interleave.
//!
//! Input: what the owner types arrives on the receive queue and is handed
//! out a line at a time by input.v1, a second service on the same endpoint.
//! Only domains the manifest wires to `input` can read it (the disk's
//! passphrase is typed here); a console.v1 capability cannot.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");
const virtio = g.virtio;
const Slot = g.domain.Slot;

pub const panic = g.panic;
comptime {
    g.exportStart();
}

const line_max = 256;

const Line = struct {
    badge: usize = 0,
    len: usize = 0,
    data: [line_max]u8 = undefined,
};

const rx_buffers = 16;
const rx_size = 256;

const Driver = struct {
    dev: virtio.Device,
    tx: virtio.Queue,
    rx: virtio.Queue,
    rx_page: virtio.Dma,
    input: [512]u8 = undefined,
    input_len: usize = 0,
    buf: virtio.Dma,
    signal: g.CPtr,
    irq: g.CPtr,
    bytes: u64 = 0,
    lines: [8]Line = @splat(.{}),

    fn lineFor(d: *Driver, badge: usize) *Line {
        for (&d.lines) |*l| if (l.badge == badge and l.len > 0) return l;
        for (&d.lines) |*l| if (l.len == 0) {
            l.badge = badge;
            return l;
        };
        // More writers than buffers: flush the first one and reuse it.
        d.flush(&d.lines[0]);
        d.lines[0].badge = badge;
        return &d.lines[0];
    }

    /// console.write
    pub fn write(d: *Driver, p: proto.console.write.Params, caller: g.idl.Caller) !proto.console.write.Results {
        const l = d.lineFor(caller.badge);
        for (p.text.slice()) |c| {
            l.data[l.len] = c;
            l.len += 1;
            if (c == '\n' or l.len == line_max) d.flush(l);
        }
        return .{};
    }

    /// input.read_line
    pub fn read_line(d: *Driver, _: proto.input.read_line.Params, _: g.idl.Caller) !proto.input.read_line.Results {
        while (d.rx.poll()) |used| {
            const id: u16 = @intCast(used.id);
            const got = d.rx_page.bytes()[id * rx_size ..][0..@min(used.len, rx_size)];
            for (got) |c| {
                if (d.input_len < d.input.len) {
                    d.input[d.input_len] = c;
                    d.input_len += 1;
                }
            }
            d.rx.submitDesc(id, d.rx_page.pa + id * rx_size, rx_size, true);
        }
        const nl = std.mem.indexOfScalar(u8, d.input[0..d.input_len], '\n') orelse {
            if (d.input_len == d.input.len) d.input_len = 0; // a line too long to keep: drop it
            return .{ .text = .{}, .ready = false };
        };
        const line = std.mem.trimEnd(u8, d.input[0..nl], "\r");
        const out: proto.input.read_line.Results = .{ .text = g.idl.Text(128).from(line), .ready = true };
        std.mem.copyForwards(u8, d.input[0..], d.input[nl + 1 .. d.input_len]);
        d.input_len -= nl + 1;
        return out;
    }

    fn flush(d: *Driver, l: *Line) void {
        if (l.len == 0) return;
        @memcpy(d.buf.bytes()[0..l.len], l.data[0..l.len]);
        if (d.tx.submit(d.buf.pa, @intCast(l.len), false)) |_| {
            _ = d.tx.wait(d.signal, d.irq);
            d.bytes += l.len;
        } else |_| {}
        l.len = 0;
    }
};

pub fn main() !u16 {
    const info = g.device("port") orelse return error.NoDevice;
    var space: g.Space = .{ .untyped = Slot.memory, .vspace = Slot.vspace, .next_slot = Slot.first_free };
    const dev: virtio.Device = .{ .base = info.mmio };
    _ = try dev.init(3, 0);
    const qpage = try virtio.Dma.alloc(&space, g.domain.Layout.heap);
    // Without the multiport feature, port 0 uses queue 0 (receive) and 1 (transmit).
    const tx = try virtio.Queue.init(dev, 1, qpage.va, qpage.pa);
    const buf = try virtio.Dma.alloc(&space, g.domain.Layout.heap + 0x1000);
    const rq = try virtio.Dma.alloc(&space, g.domain.Layout.heap + 0x2000);
    const rx = try virtio.Queue.init(dev, 0, rq.va, rq.pa);
    const rx_page = try virtio.Dma.alloc(&space, g.domain.Layout.heap + 0x3000);
    const signal = try space.retype(.signal, 0);
    if (!g.invoke(info.irq_slot, g.abi.IrqMethod.set_signal, .{signal}).ok()) return error.IrqSetup;
    dev.ready();
    g.log("driver_ready", .{ .device = "virtio_console", .mmio = g.klog.hex(info.phys), .irq = info.irq_line });
    var d: Driver = .{ .dev = dev, .tx = tx, .rx = rx, .rx_page = rx_page, .buf = buf, .signal = signal, .irq = info.irq_slot };
    for (0..rx_buffers) |i| d.rx.submitDesc(@intCast(i), rx_page.pa + i * rx_size, rx_size, true);
    // console.v1 and input.v1 share the domain's endpoint (the slots are
    // the same endpoint); the kernel tells which one each caller holds.
    _ = g.provided("input") orelse return error.NoService;
    g.idl.serveAll(.{ proto.console, proto.input }, g.provided("console") orelse return error.NoService, &d);
}
