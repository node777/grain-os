//! mycelium: the network below Comlink. It drives the network device itself
//! and speaks just enough IPv4 to carry datagrams between instances on one
//! link: a link-local address taken from the device's MAC, ARP to find
//! neighbours (and learning from every frame that arrives), and UDP ports,
//! one per client, with a queue each.
//!
//! One thread serves clients and the device: its interrupt is a signal bound
//! to the thread, so a receive returns for a call or for a frame.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");
const P = proto.mycelium;
const idl = g.idl;
const D = g.domain;
const net = g.net;

pub const panic = g.panic;
pub const std_options = g.std_options;
comptime {
    g.exportStart();
}

/// Whatever network device Steward handed over: virtio-net or an Intel
/// 8254x, one interface.
const Nic = union(enum) {
    virtio: g.virtio_net.Net,
    e1000: g.e1000.E1000,

    fn send(n: *Nic, f: []const u8) !void {
        return switch (n.*) {
            inline else => |*x| x.send(f),
        };
    }
    fn recv(n: *Nic, out: []u8) ?[]u8 {
        return switch (n.*) {
            inline else => |*x| x.recv(out),
        };
    }
    fn ack(n: *Nic) void {
        switch (n.*) {
            .virtio => |*x| _ = x.dev.ackInterrupt(),
            .e1000 => |*x| x.ack(),
        }
    }
    fn hwAddress(n: *const Nic) net.Mac {
        return switch (n.*) {
            inline else => |x| x.mac,
        };
    }
};
var nic: Nic = undefined;
var nic_irq: g.CPtr = 0;
var mac: net.Mac = undefined;
var address: net.Ip = 0;
var counters: struct { sent: u64 = 0, received: u64 = 0, dropped: u64 = 0 } = .{};

// ---------------------------------------------------------------------------
// Neighbours: address to MAC, learnt from ARP and from every frame.

const Neighbour = struct { ip: net.Ip = 0, mac: net.Mac = @splat(0) };
var neighbours: [16]Neighbour = @splat(.{});
var next_neighbour: usize = 0;

fn learn(ip: net.Ip, m: net.Mac) void {
    if (ip == 0 or ip == net.broadcast_ip) return;
    for (&neighbours) |*n| if (n.ip == ip) {
        n.mac = m;
        return;
    };
    neighbours[next_neighbour] = .{ .ip = ip, .mac = m };
    next_neighbour = (next_neighbour + 1) % neighbours.len;
    flushPending(ip, m);
}

fn macOf(ip: net.Ip) ?net.Mac {
    if (ip == net.broadcast_ip or ip == (address | 0xffff)) return net.broadcast_mac;
    for (neighbours) |n| if (n.ip == ip) return n.mac;
    return null;
}

/// Datagrams waiting for an ARP answer: the newest few.
const Pending = struct { used: bool = false, to: net.Ip = 0, sport: u16 = 0, dport: u16 = 0, len: u16 = 0, data: [P.max_data]u8 = undefined };
var pending: [4]Pending = @splat(.{});

fn flushPending(ip: net.Ip, m: net.Mac) void {
    for (&pending) |*p| if (p.used and p.to == ip) {
        p.used = false;
        transmit(m, ip, p.sport, p.dport, p.data[0..p.len]);
    };
}

var frame: [1514]u8 = undefined;

fn transmit(to_mac: net.Mac, to: net.Ip, sport: u16, dport: u16, data: []const u8) void {
    const f = net.udp(&frame, mac, to_mac, address, to, sport, dport, data);
    nic.send(f) catch {
        counters.dropped += 1;
        return;
    };
    counters.sent += 1;
}

fn sendDatagram(to: net.Ip, sport: u16, dport: u16, data: []const u8) void {
    if (macOf(to)) |m| return transmit(m, to, sport, dport, data);
    // Ask who has it, and hold the datagram until the answer comes.
    var slot = &pending[0];
    for (&pending) |*p| if (!p.used) {
        slot = p;
        break;
    };
    slot.* = .{ .used = true, .to = to, .sport = sport, .dport = dport, .len = @intCast(data.len) };
    @memcpy(slot.data[0..data.len], data);
    const a = net.arp(&frame, .request, mac, address, @splat(0), to);
    nic.send(a) catch {};
}

// ---------------------------------------------------------------------------
// Ports

const Datagram = struct { from: net.Ip, port: u16, len: u16, data: [P.max_data]u8 };

const Socket = struct {
    used: bool = false,
    badge: usize = 0,
    port: u16 = 0,
    listener: g.CPtr = 0,
    queue: [16]Datagram = undefined,
    head: u8 = 0,
    len: u8 = 0,
};
var sockets: [4]Socket = @splat(.{});

fn socketOf(badge: usize) ?*Socket {
    for (&sockets) |*s| if (s.used and s.badge == badge) return s;
    return null;
}

fn deliver(from: net.Ip, sport: u16, dport: u16, data: []const u8) void {
    const s = for (&sockets) |*s| {
        if (s.used and s.port == dport) break s;
    } else {
        counters.dropped += 1;
        return;
    };
    if (s.len == s.queue.len or data.len > P.max_data) {
        counters.dropped += 1;
        return;
    }
    const d = &s.queue[(s.head + s.len) % s.queue.len];
    d.from = from;
    d.port = sport;
    d.len = @intCast(data.len);
    @memcpy(d.data[0..data.len], data);
    s.len += 1;
    counters.received += 1;
    if (s.listener != 0) _ = g.signal(s.listener);
}

var rx: [2048]u8 = undefined;

fn drain() void {
    while (nic.recv(&rx)) |f| switch (net.parse(f)) {
        .arp => |a| {
            learn(a.sender, a.sender_mac);
            if (a.op == .request and a.target == address) nic.send(net.arp(&frame, .reply, mac, address, a.sender_mac, a.sender)) catch {};
        },
        .udp => |u| {
            if (u.dst != address and u.dst != net.broadcast_ip and u.dst != (address | 0xffff)) continue;
            learn(u.src, u.src_mac);
            deliver(u.src, u.sport, u.dport, u.payload);
        },
        .other => {},
    };
}

// ---------------------------------------------------------------------------

var space: g.Space = undefined;

const Server = struct {
    pub fn onSignal(_: *Server, _: u64) void {
        drain();
        nic.ack();
        _ = g.invoke(nic_irq, g.abi.IrqMethod.ack, .{});
        drain();
    }

    pub fn bind(_: *Server, p: P.bind.Params, c: idl.Caller) !P.bind.Results {
        if (p.port == 0) return error.InvalidArgs;
        for (&sockets) |*s| if (s.used and s.port == p.port and s.badge != c.badge) return error.Unavailable;
        const s = socketOf(c.badge) orelse for (&sockets) |*s| {
            if (!s.used) break s;
        } else return error.Unavailable;
        s.used = true;
        s.badge = c.badge;
        s.port = p.port;
        return .{ .address = address };
    }

    pub fn listen(_: *Server, p: P.listen.Params, c: idl.Caller) !P.listen.Results {
        const s = socketOf(c.badge) orelse return error.NotFound;
        if (p.signal.slot == 0) return error.InvalidArgs;
        if (s.listener == 0) s.listener = space.slot() catch return error.Unavailable;
        _ = g.invoke(D.Slot.cnode, g.abi.CNodeMethod.delete, .{s.listener});
        if (!g.invoke(D.Slot.cnode, g.abi.CNodeMethod.move, .{ s.listener, p.signal.slot }).ok()) return error.Failed;
        if (s.len > 0) _ = g.signal(s.listener);
        return .{};
    }

    pub fn send(_: *Server, p: P.send.Params, c: idl.Caller) !P.send.Results {
        const s = socketOf(c.badge) orelse return error.NotFound;
        sendDatagram(p.to, s.port, p.port, p.data.slice());
        return .{};
    }

    pub fn recv(_: *Server, _: P.recv.Params, c: idl.Caller) !P.recv.Results {
        const s = socketOf(c.badge) orelse return error.NotFound;
        // Frames may have come since the last interrupt was taken.
        drain();
        if (s.len == 0) return .{ .found = false, .from = 0, .port = 0, .data = .{} };
        const d = &s.queue[s.head];
        s.head = @intCast((s.head + 1) % s.queue.len);
        s.len -= 1;
        return .{ .found = true, .from = d.from, .port = d.port, .data = P.Data.from(d.data[0..d.len]) };
    }

    pub fn info(_: *Server, _: P.info.Params, _: idl.Caller) !P.info.Results {
        return .{ .address = address, .mac = idl.Bytes(6).from(&mac), .sent = counters.sent, .received = counters.received, .dropped = counters.dropped };
    }
};

fn page(va: usize) !g.virtio_net.Page {
    const d = try g.virtio.Dma.alloc(&space, va);
    return .{ .va = d.va, .pa = d.pa };
}

pub fn main() !u16 {
    space = .{ .untyped = D.Slot.memory, .vspace = D.Slot.vspace, .next_slot = D.Slot.first_free };
    const dev = g.device("nic") orelse return error.NoDevice;
    const base = D.Layout.heap;
    var rx_pages: [8]g.virtio_net.Page = undefined;
    var tx_pages: [4]g.virtio_net.Page = undefined;
    for (&rx_pages, 0..) |*p, i| p.* = try page(base + (2 + i) * 0x1000);
    for (&tx_pages, 0..) |*p, i| p.* = try page(base + (10 + i) * 0x1000);
    const sig = try space.retype(.signal, 0);
    if (!g.invoke(dev.irq_slot, g.abi.IrqMethod.set_signal, .{sig}).ok()) return error.IrqSetup;
    nic_irq = dev.irq_slot;
    nic = switch (dev.bus) {
        .virtio => .{ .virtio = try g.virtio_net.Net.init(dev.mmio, try page(base), try page(base + 0x1000), rx_pages, tx_pages) },
        .pci => blk: {
            if (!g.e1000.supports(dev.vendor, dev.device_id)) return error.UnsupportedNic;
            var rx_bufs: [8]g.e1000.Page = undefined;
            var tx_bufs: [4]g.e1000.Page = undefined;
            for (rx_pages, 0..) |p, i| rx_bufs[i] = .{ .va = p.va, .pa = p.pa };
            for (tx_pages, 0..) |p, i| tx_bufs[i] = .{ .va = p.va, .pa = p.pa };
            const rings = try page(base);
            break :blk .{ .e1000 = try g.e1000.E1000.init(dev.mmio, .{ .va = rings.va, .pa = rings.pa }, rx_bufs, tx_bufs) };
        },
        .absent => unreachable, // g.device() returns only present devices
    };
    mac = nic.hwAddress();
    address = net.linkLocal(mac);
    if (g.bindSignal(sig) != .ok) return error.BindFailed;
    var ip_text: [15]u8 = undefined;
    g.log("mycelium_ready", .{ .address = net.formatIp(address, &ip_text), .mac = g.klog.hex(std.mem.readInt(u48, &mac, .big)), .nic = @tagName(nic) });
    idl.recv_slot = try space.slot();
    var s: Server = .{};
    idl.serve(P, g.provided("mycelium") orelse return error.NoService, &s);
}
