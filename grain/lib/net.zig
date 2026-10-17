//! Ethernet, ARP, IPv4 and UDP: building and reading frames. Pure (no
//! devices), so the host tests every byte.
//!
//! Only what Mycelium needs: IPv4 without options or fragments, UDP with
//! its checksum, ARP for IPv4 over Ethernet. Multi-byte fields are big-endian
//! on the wire, as the RFCs say.
const std = @import("std");

pub const Mac = [6]u8;
pub const broadcast_mac: Mac = @splat(0xff);
/// IPv4 addresses as numbers, 0xA9FE0A0B for 169.254.10.11.
pub const Ip = u32;
pub const broadcast_ip: Ip = 0xffff_ffff;

pub const ether_header = 14;
pub const ip_header = 20;
pub const udp_header = 8;
pub const arp_length = 28;
/// The largest UDP payload in one standard frame.
pub const max_payload = 1500 - ip_header - udp_header;

const ethertype_ip: u16 = 0x0800;
const ethertype_arp: u16 = 0x0806;
const proto_udp: u8 = 17;

/// A link-local address (RFC 3927 space) from the low bytes of a MAC.
pub fn linkLocal(mac: Mac) Ip {
    return 0xA9FE_0000 | @as(Ip, mac[4]) << 8 | mac[5];
}

pub fn formatIp(ip: Ip, buf: *[15]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip >> 24, (ip >> 16) & 0xff, (ip >> 8) & 0xff, ip & 0xff }) catch unreachable;
}

fn put16(b: []u8, v: u16) void {
    std.mem.writeInt(u16, b[0..2], v, .big);
}
fn put32(b: []u8, v: u32) void {
    std.mem.writeInt(u32, b[0..4], v, .big);
}
fn get16(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .big);
}
fn get32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

/// The Internet checksum: ones' complement of the ones'-complement sum.
fn sum(acc: u32, bytes: []const u8) u32 {
    var s = acc;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) s += get16(bytes[i..]);
    if (bytes.len % 2 == 1) s += @as(u32, bytes[bytes.len - 1]) << 8;
    return s;
}

fn fold(s0: u32) u16 {
    var s = s0;
    while (s >> 16 != 0) s = (s & 0xffff) + (s >> 16);
    return ~@as(u16, @truncate(s));
}

fn udpChecksum(src: Ip, dst: Ip, datagram: []const u8) u16 {
    const c = fold(sum(sum(0, &pseudoHeader(src, dst, @intCast(datagram.len))), datagram));
    return if (c == 0) 0xffff else c;
}

fn ether(buf: []u8, dst: Mac, src: Mac, ethertype: u16) void {
    @memcpy(buf[0..6], &dst);
    @memcpy(buf[6..12], &src);
    put16(buf[12..], ethertype);
}

/// A UDP datagram in a frame; returns the frame (`buf` must hold
/// 42 + payload bytes).
pub fn udp(buf: []u8, src_mac: Mac, dst_mac: Mac, src: Ip, dst: Ip, sport: u16, dport: u16, payload: []const u8) []u8 {
    const total = ether_header + ip_header + udp_header + payload.len;
    ether(buf, dst_mac, src_mac, ethertype_ip);
    const h = buf[ether_header..][0..ip_header];
    h[0] = 0x45; // version 4, 5 words
    h[1] = 0;
    put16(h[2..], @intCast(ip_header + udp_header + payload.len));
    put16(h[4..], 0); // identification
    put16(h[6..], 0x4000); // don't fragment
    h[8] = 64; // ttl
    h[9] = proto_udp;
    put16(h[10..], 0);
    put32(h[12..], src);
    put32(h[16..], dst);
    put16(h[10..], fold(sum(0, h)));
    const u = buf[ether_header + ip_header ..][0 .. udp_header + payload.len];
    put16(u[0..], sport);
    put16(u[2..], dport);
    put16(u[4..], @intCast(u.len));
    put16(u[6..], 0);
    @memcpy(u[udp_header..], payload);
    put16(u[6..], udpChecksum(src, dst, u));
    return buf[0..total];
}

pub const ArpOp = enum(u16) { request = 1, reply = 2 };

pub fn arp(buf: []u8, op: ArpOp, src_mac: Mac, src: Ip, target_mac: Mac, target: Ip) []u8 {
    ether(buf, if (op == .request) broadcast_mac else target_mac, src_mac, ethertype_arp);
    const a = buf[ether_header..][0..arp_length];
    put16(a[0..], 1); // Ethernet
    put16(a[2..], ethertype_ip);
    a[4] = 6;
    a[5] = 4;
    put16(a[6..], @backingInt(op));
    @memcpy(a[8..14], &src_mac);
    put32(a[14..], src);
    @memcpy(a[18..24], &target_mac);
    put32(a[24..], target);
    return buf[0 .. ether_header + arp_length];
}

pub const Frame = union(enum) {
    arp: struct { op: ArpOp, sender_mac: Mac, sender: Ip, target: Ip },
    udp: struct { src_mac: Mac, src: Ip, dst: Ip, sport: u16, dport: u16, payload: []const u8 },
    /// Anything else, or anything malformed: ignored.
    other,
};

/// Read a frame; checksums are verified and a bad one reads as `other`.
pub fn parse(f: []const u8) Frame {
    if (f.len < ether_header) return .other;
    var src_mac: Mac = undefined;
    @memcpy(&src_mac, f[6..12]);
    const body = f[ether_header..];
    switch (get16(f[12..])) {
        ethertype_arp => {
            if (body.len < arp_length or get16(body[0..]) != 1 or get16(body[2..]) != ethertype_ip or body[4] != 6 or body[5] != 4) return .other;
            const op = std.enums.fromInt(ArpOp, get16(body[6..])) orelse return .other;
            var sm: Mac = undefined;
            @memcpy(&sm, body[8..14]);
            return .{ .arp = .{ .op = op, .sender_mac = sm, .sender = get32(body[14..]), .target = get32(body[24..]) } };
        },
        ethertype_ip => {
            if (body.len < ip_header or body[0] != 0x45 or body[9] != proto_udp) return .other;
            if (fold(sum(0, body[0..ip_header])) != 0) return .other;
            const total = get16(body[2..]);
            if (total > body.len or total < ip_header + udp_header) return .other;
            if (get16(body[6..]) & 0x3fff != 0) return .other; // fragments
            const u = body[ip_header..total];
            const ulen = get16(u[4..]);
            if (ulen < udp_header or ulen > u.len) return .other;
            const src = get32(body[12..]);
            const dst = get32(body[16..]);
            if (get16(u[6..]) != 0 and fold(sum(sum(0, &pseudoHeader(src, dst, ulen)), u[0..ulen])) != 0) return .other;
            return .{ .udp = .{ .src_mac = src_mac, .src = src, .dst = dst, .sport = get16(u[0..]), .dport = get16(u[2..]), .payload = u[udp_header..ulen] } };
        },
        else => return .other,
    }
}

fn pseudoHeader(src: Ip, dst: Ip, len: u16) [12]u8 {
    var p: [12]u8 = undefined;
    put32(p[0..], src);
    put32(p[4..], dst);
    p[8] = 0;
    p[9] = proto_udp;
    put16(p[10..], len);
    return p;
}

const testing = std.testing;

test "a UDP datagram round-trips, and damage is caught" {
    var buf: [1514]u8 = undefined;
    const a: Mac = .{ 0x52, 0x54, 0, 0, 0, 0x0a };
    const b: Mac = .{ 0x52, 0x54, 0, 0, 0, 0x0b };
    const f = udp(&buf, a, b, linkLocal(a), linkLocal(b), 4242, 4243, "hello, mycelium");
    try testing.expectEqual(@as(usize, 42 + 15), f.len);
    const p = parse(f).udp;
    try testing.expectEqual(linkLocal(a), p.src);
    try testing.expectEqual(@as(Ip, 0xA9FE000B), p.dst);
    try testing.expectEqual(@as(u16, 4243), p.dport);
    try testing.expectEqualStrings("hello, mycelium", p.payload);
    try testing.expectEqualSlices(u8, &a, &p.src_mac);
    // The IP header's checksum, as computed independently: 169.254.0.10 -> .11, 43 bytes.
    try testing.expectEqual(@as(u16, 0xe6b0), get16(f[24..]));
    f[50] ^= 1; // a payload bit
    try testing.expect(parse(f) == .other);
    f[50] ^= 1;
    f[22] ^= 1; // the ttl
    try testing.expect(parse(f) == .other);
}

test "ARP asks by broadcast and answers directly" {
    var buf: [64]u8 = undefined;
    const a: Mac = .{ 2, 0, 0, 0, 0, 1 };
    const b: Mac = .{ 2, 0, 0, 0, 0, 2 };
    const q = arp(&buf, .request, a, linkLocal(a), @splat(0), linkLocal(b));
    try testing.expectEqualSlices(u8, &broadcast_mac, q[0..6]);
    const r = parse(q).arp;
    try testing.expectEqual(ArpOp.request, r.op);
    try testing.expectEqual(linkLocal(b), r.target);
    try testing.expectEqualSlices(u8, &a, &r.sender_mac);
    var text: [15]u8 = undefined;
    try testing.expectEqualStrings("169.254.0.2", formatIp(linkLocal(b), &text));
}
