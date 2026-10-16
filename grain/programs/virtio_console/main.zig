//! virtio-console driver: serves console.v1 by writing to the device's
//! port 0 transmit queue.
//!
//! Writes arrive in pieces of up to 256 bytes, and several clients write at once, so
//! the driver keeps a line buffer per client (by badge) and sends only whole
//! lines (or a full buffer). Lines from different clients never interleave.
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

const Driver = struct {
    dev: virtio.Device,
    tx: virtio.Queue,
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
    const signal = try space.retype(.signal, 0);
    if (!g.invoke(info.irq_slot, g.abi.IrqMethod.set_signal, .{signal}).ok()) return error.IrqSetup;
    dev.ready();
    g.log("driver_ready", .{ .device = "virtio_console", .mmio = g.klog.hex(info.phys), .irq = info.irq_line });
    var d: Driver = .{ .dev = dev, .tx = tx, .buf = buf, .signal = signal, .irq = info.irq_slot };
    g.idl.serve(proto.console, g.provided("console") orelse return error.NoService, &d);
}
