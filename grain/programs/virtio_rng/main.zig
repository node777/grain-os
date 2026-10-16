//! virtio-rng driver: serves entropy.v1 from the device's request queue.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");
const virtio = g.virtio;
const Slot = g.domain.Slot;

pub const panic = g.panic;
comptime {
    g.exportStart();
}

const Driver = struct {
    rq: virtio.Queue,
    buf: virtio.Dma,
    signal: g.CPtr,
    irq: g.CPtr,

    /// entropy.get
    pub fn get(d: *Driver, _: proto.entropy.get.Params, _: g.idl.Caller) !proto.entropy.get.Results {
        var filled: usize = 0;
        // The device may return fewer bytes than asked; keep asking.
        while (filled < 32) {
            _ = try d.rq.submit(d.buf.pa + filled, @intCast(32 - filled), true);
            const used = d.rq.wait(d.signal, d.irq);
            if (used.len == 0) return error.Unavailable;
            filled += used.len;
        }
        return .{ .bytes = g.idl.Bytes(32).from(d.buf.bytes()[0..32]) };
    }
};

pub fn main() !u16 {
    const info = g.device("source") orelse return error.NoDevice;
    var space: g.Space = .{ .untyped = Slot.memory, .vspace = Slot.vspace, .next_slot = Slot.first_free };
    const dev: virtio.Device = .{ .base = info.mmio };
    _ = try dev.init(4, 0);
    const qpage = try virtio.Dma.alloc(&space, g.domain.Layout.heap);
    const rq = try virtio.Queue.init(dev, 0, qpage.va, qpage.pa);
    const buf = try virtio.Dma.alloc(&space, g.domain.Layout.heap + 0x1000);
    const signal = try space.retype(.signal, 0);
    if (!g.invoke(info.irq_slot, g.abi.IrqMethod.set_signal, .{signal}).ok()) return error.IrqSetup;
    dev.ready();
    g.log("driver_ready", .{ .device = "virtio_rng", .mmio = g.klog.hex(info.phys), .irq = info.irq_line });
    var d: Driver = .{ .rq = rq, .buf = buf, .signal = signal, .irq = info.irq_slot };
    g.idl.serve(proto.entropy, g.provided("entropy") orelse return error.NoService, &d);
}
