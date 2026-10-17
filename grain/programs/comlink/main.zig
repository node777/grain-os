//! comlink: other instances, by identity.
//!
//! On the link (through Mycelium, UDP port 4747) Comlink says hello: its
//! identity key, in the clear. When two instances have heard each other, the
//! one with the lower key opens a Noise XX handshake; each side proves its
//! identity by completing it (the Diffie-Hellman with its identity key is
//! done by Kumara, which never lets the key out) and names the identity in
//! its handshake payload, which must match the key it proved. Everything
//! after that is sealed in the session.
//!
//! Sharing makes a sturdy reference: a random token, sent to one identity
//! alone, and behind it a kernel Lease on Comlink's own capability (to a
//! hosted service, or to the store for an object). A request is honoured only
//! from that identity, with that token, through that lease; revoking the
//! share ends the lease. Shares and revocations go into the Ledger.
//!
//! Requests are retried on a timer (a signal alarm) until answered; the
//! host keeps its last answer to each peer, so a retried request is answered
//! again, never run twice. One thread serves local clients and the network:
//! datagrams and the timer raise one signal, bound to the thread.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");
const P = proto.comlink;
const M = proto.mycelium;
const TC = proto.tablecloth;
const idl = g.idl;
const D = g.domain;
const noise = g.noise;
const K = g.kumara;
const X25519 = std.crypto.dh.X25519;

pub const panic = g.panic;
pub const std_options = g.std_options;
comptime {
    g.exportStart();
}

const port: u16 = 4747;
const prologue = "grain comlink v1";
const tick_ms = 250;
const resend_ms = 600;
const handshake_ms = 1500;
const max_tries = 8;
const chunk = 400;

const bit_net: u64 = 1;
const bit_alarm: u64 = 2;

// On the wire (UDP payloads).
/// An amphora is a sealed message: encrypted in the session, opened only by
/// the identity it was sealed for.
const Wire = enum(u8) { hello = 1, hs1 = 2, hs2 = 3, hs3 = 4, amphora = 5, reset = 6, _ };
// Inside a session.
const Msg = enum(u8) { request = 1, response = 2, offer = 3, withdraw = 4, fetch = 5, _ };

const Status = enum(u8) { ok = 0, refused = 1, failed = 2 };

var mycelium: g.CPtr = 0;
var kumara: g.CPtr = 0;
var entropy: g.CPtr = 0;
var sig: g.CPtr = 0;
var alarm_cap: g.CPtr = 0;
var space: g.Space = undefined;
var online = false;

var my_key: [32]u8 = undefined;
var my_name: K.Name = undefined;
var my_static: [32]u8 = undefined;
var address: u32 = 0;
var ms: u64 = 10_000;
var next_id: u32 = 1;

fn now() u64 {
    return g.time();
}

fn random() [32]u8 {
    const r = idl.call(proto.entropy.get, entropy, .{}) catch @panic("no entropy");
    return r.bytes.data[0..32].*;
}

fn hex8(b: []const u8) g.klog.Hex(u64) {
    return g.klog.hex(std.mem.readInt(u64, b[0..8], .big));
}

// ---------------------------------------------------------------------------
// Peers

const Peer = struct {
    used: bool = false,
    /// Known once it said hello or proved itself in a handshake.
    known: bool = false,
    key: [32]u8 = undefined,
    name: K.Name = undefined,
    addr: u32 = 0,
    hs: noise.Handshake = undefined,
    hs_active: bool = false,
    hs_started: u64 = 0,
    /// The last handshake message we sent, to send again: lost datagrams
    /// must not leave one side with a session and the other without.
    hs_msg: [192]u8 = undefined,
    hs_msg_len: u8 = 0,
    hs_sent: u64 = 0,
    session: ?noise.Session = null,
    /// The last request this peer sent and our answer, to answer a retry.
    last_req: u32 = 0,
    last_resp: [480]u8 = undefined,
    last_resp_len: u16 = 0,
};
var peers: [8]Peer = @splat(.{});

fn peerByAddr(addr: u32) ?*Peer {
    for (&peers) |*p| if (p.used and p.addr == addr) return p;
    return null;
}

fn peerByKey(key: [32]u8) ?*Peer {
    for (&peers) |*p| if (p.used and p.known and std.mem.eql(u8, &p.key, &key)) return p;
    return null;
}

fn peerByName(n: []const u8) ?*Peer {
    for (&peers) |*p| if (p.used and p.known and std.mem.eql(u8, &p.name, n)) return p;
    return null;
}

fn newPeer(addr: u32) *Peer {
    for (&peers) |*p| if (!p.used) {
        p.* = .{ .used = true, .addr = addr };
        return p;
    };
    // Full: forget the first one without a session.
    for (&peers) |*p| if (p.session == null) {
        p.* = .{ .used = true, .addr = addr };
        return p;
    };
    peers[0] = .{ .used = true, .addr = addr };
    return &peers[0];
}

fn know(p: *Peer, key: [32]u8) void {
    const fresh = !p.known;
    p.known = true;
    p.key = key;
    p.name = K.nameOf(key);
    if (fresh) {
        var ip: [15]u8 = undefined;
        g.log("comlink_peer", .{ .name = @as([]const u8, &p.name), .address = g.net.formatIp(p.addr, &ip), .key = hex8(&key) });
    }
}

/// The X25519 key an identity proves itself with.
fn staticOf(key: [32]u8) ?[32]u8 {
    const pk = std.crypto.sign.Ed25519.PublicKey.fromBytes(key) catch return null;
    return X25519.publicKeyFromEd25519(pk) catch null;
}

// ---------------------------------------------------------------------------
// The wire

var out_buf: [M.max_data]u8 = undefined;

fn sendRaw(to: u32, bytes: []const u8) void {
    _ = idl.call(M.send, mycelium, .{ .to = to, .port = port, .data = M.Data.from(bytes) }) catch {};
}

fn hello(to: u32, reply: bool) void {
    var b: [34]u8 = undefined;
    b[0] = @backingInt(Wire.hello);
    @memcpy(b[1..33], &my_key);
    b[33] = @intFromBool(reply);
    sendRaw(to, &b);
}

fn sendAmphora(p: *Peer, plain: []const u8) void {
    const s = &(p.session orelse return);
    out_buf[0] = @backingInt(Wire.amphora);
    const ct = s.encrypt(out_buf[1..], plain);
    sendRaw(p.addr, out_buf[0 .. 1 + ct.len]);
}

const KumaraDh = struct {
    pub const Error = error{Unavailable};
    pub fn agree(_: KumaraDh, peer_public: [32]u8) Error![32]u8 {
        const r = idl.call(proto.kumara.agree, kumara, .{ .peer = idl.Bytes(32).from(&peer_public) }) catch return error.Unavailable;
        return r.shared.data[0..32].*;
    }
};

/// Send a handshake message and keep it, to send again.
fn sendHandshake(p: *Peer, kind: Wire, m: []const u8) void {
    p.hs_msg[0] = @backingInt(kind);
    @memcpy(p.hs_msg[1..][0..m.len], m);
    p.hs_msg_len = @intCast(1 + m.len);
    p.hs_sent = now();
    sendRaw(p.addr, p.hs_msg[0..p.hs_msg_len]);
}

fn resendHandshake(p: *Peer) void {
    if (p.hs_msg_len == 0) return;
    p.hs_sent = now();
    sendRaw(p.addr, p.hs_msg[0..p.hs_msg_len]);
}

fn handshakeFailed(p: *Peer, step: []const u8, e: anyerror) void {
    p.hs_active = false;
    g.log("comlink_handshake_failed", .{ .step = step, .err = @errorName(e) });
}

fn reset(to: u32) void {
    sendRaw(to, &[_]u8{@backingInt(Wire.reset)});
}

fn startHandshake(p: *Peer) void {
    p.hs = noise.Handshake.init(true, my_static, random(), prologue);
    var m_buf: [128]u8 = undefined;
    const m = p.hs.write(&m_buf, "", KumaraDh{}) catch |e| return handshakeFailed(p, "write1", e);
    p.hs_active = true;
    p.hs_started = now();
    sendHandshake(p, .hs1, m);
}

/// The lower key opens the handshake, so two instances never open two.
fn maybeInitiate(p: *Peer) void {
    if (p.session != null or p.hs_active or !p.known) return;
    if (std.mem.order(u8, &my_key, &p.key) == .lt) startHandshake(p);
}

/// A handshake payload names the identity; it must be the one proved.
fn proved(p: *Peer, payload: []const u8) bool {
    if (payload.len != 32) return false;
    const key = payload[0..32].*;
    const s = staticOf(key) orelse return false;
    if (!std.mem.eql(u8, &s, &p.hs.remoteStatic())) return false;
    if (p.known and !std.mem.eql(u8, &p.key, &key)) return false;
    know(p, key);
    return true;
}

fn established(p: *Peer, initiator: bool) void {
    p.session = p.hs.split();
    p.hs_active = false;
    p.last_req = 0;
    g.log("comlink_session", .{ .peer = @as([]const u8, &p.name), .initiator = initiator, .hash = hex8(&p.session.?.hash) });
}

var plain_buf: [M.max_data]u8 = undefined;

fn onDatagram(from: u32, data: []const u8) void {
    if (data.len == 0) return;
    const body = data[1..];
    switch (@as(Wire, @fromBackingInt(@intCast(data[0])))) {
        .hello => {
            if (body.len != 33) return;
            const key = body[0..32].*;
            if (std.mem.eql(u8, &key, &my_key)) return;
            const p = peerByKey(key) orelse peerByAddr(from) orelse newPeer(from);
            const fresh = !p.known;
            p.addr = from;
            know(p, key);
            // A newcomer's broadcast is answered directly, once.
            if (fresh and body[32] == 0) hello(from, true);
            maybeInitiate(p);
        },
        .hs1 => {
            const p = peerByAddr(from) orelse newPeer(from);
            // The same first message again: our answer was lost; repeat it.
            if (p.hs_active and !p.hs.initiator and body.len >= 32 and std.mem.eql(u8, body[0..32], &p.hs.re)) return resendHandshake(p);
            p.hs = noise.Handshake.init(false, my_static, random(), prologue);
            _ = p.hs.read(body, &plain_buf) catch |e| return handshakeFailed(p, "read1", e);
            var m_buf: [160]u8 = undefined;
            const m = p.hs.write(&m_buf, &my_key, KumaraDh{}) catch |e| return handshakeFailed(p, "write2", e);
            p.hs_active = true;
            p.hs_started = now();
            sendHandshake(p, .hs2, m);
        },
        .hs2 => {
            const p = peerByAddr(from) orelse return;
            // Done already: our last message was lost; repeat it.
            if (!p.hs_active and p.session != null and p.hs.initiator) return resendHandshake(p);
            if (!p.hs_active or !p.hs.initiator) return;
            const payload = p.hs.read(body, &plain_buf) catch |e| return handshakeFailed(p, "read2", e);
            if (!proved(p, payload)) {
                p.hs_active = false;
                g.log("comlink_refused", .{ .reason = "identity_mismatch" });
                return;
            }
            var m_buf: [128]u8 = undefined;
            const m = p.hs.write(&m_buf, &my_key, KumaraDh{}) catch |e| return handshakeFailed(p, "write3", e);
            sendHandshake(p, .hs3, m);
            established(p, true);
        },
        .hs3 => {
            const p = peerByAddr(from) orelse return;
            if (!p.hs_active or p.hs.initiator) return;
            const payload = p.hs.read(body, &plain_buf) catch |e| return handshakeFailed(p, "read3", e);
            if (!proved(p, payload)) {
                p.hs_active = false;
                g.log("comlink_refused", .{ .reason = "identity_mismatch" });
                return;
            }
            established(p, false);
        },
        .amphora => {
            const p = peerByAddr(from) orelse return reset(from);
            const s = &(p.session orelse {
                // It thinks we share a session; we don't (lost, or we
                // restarted). Say so, and the two of us start over.
                if (!p.hs_active) reset(from);
                return;
            });
            const msg = s.decrypt(&plain_buf, body) catch return;
            onMessage(p, msg);
        },
        .reset => {
            const p = peerByAddr(from) orelse return;
            if (p.session == null and !p.hs_active) {
                maybeInitiate(p);
                return;
            }
            p.session = null;
            p.hs_active = false;
            g.log("comlink_reset", .{ .peer = @as([]const u8, &p.name) });
            maybeInitiate(p);
            // If it is ours to begin, it already began; else ask them to.
            if (!p.hs_active) reset(from);
        },
        _ => {},
    }
}

// ---------------------------------------------------------------------------
// Messages in a session

const Reader = struct {
    b: []const u8,
    fn take(r: *Reader, n: usize) ?[]const u8 {
        if (r.b.len < n) return null;
        defer r.b = r.b[n..];
        return r.b[0..n];
    }
    fn int(r: *Reader, comptime T: type) ?T {
        const s = r.take(@sizeOf(T)) orelse return null;
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }
};

const Writer = struct {
    buf: []u8,
    n: usize = 0,
    fn bytes(w: *Writer, s: []const u8) void {
        @memcpy(w.buf[w.n..][0..s.len], s);
        w.n += s.len;
    }
    fn int(w: *Writer, comptime T: type, v: T) void {
        std.mem.writeInt(T, w.buf[w.n..][0..@sizeOf(T)], v, .little);
        w.n += @sizeOf(T);
    }
    fn done(w: *const Writer) []const u8 {
        return w.buf[0..w.n];
    }
};

/// The answer we are waiting for, if any.
var pending: struct { active: bool = false, id: u32 = 0, done: bool = false, status: Status = .ok, len: usize = 0, data: [480]u8 = undefined } = .{};

fn respond(p: *Peer, id: u32, status: Status, body: []const u8) void {
    var w: Writer = .{ .buf = &p.last_resp };
    w.int(u8, @backingInt(Msg.response));
    w.int(u32, id);
    w.int(u8, @backingInt(status));
    w.bytes(body);
    p.last_req = id;
    p.last_resp_len = @intCast(w.n);
    sendAmphora(p, w.done());
}

fn onMessage(p: *Peer, msg: []const u8) void {
    var r: Reader = .{ .b = msg };
    const kind: Msg = @fromBackingInt(@intCast(r.int(u8) orelse return));
    const id = r.int(u32) orelse return;
    switch (kind) {
        .response => {
            if (!pending.active or pending.id != id or pending.done) return;
            const st = r.int(u8) orelse return;
            pending.status = std.enums.fromInt(Status, st) orelse .failed;
            pending.len = r.b.len;
            @memcpy(pending.data[0..r.b.len], r.b);
            pending.done = true;
        },
        else => {
            // A retry of the last request: the same answer again.
            if (id == p.last_req and p.last_resp_len > 0) return sendAmphora(p, p.last_resp[0..p.last_resp_len]);
            serve(p, kind, id, &r);
        },
    }
}

var answer: [480]u8 = undefined;

fn serve(p: *Peer, kind: Msg, id: u32, r: *Reader) void {
    switch (kind) {
        .request => {
            const token = (r.take(16) orelse return)[0..16].*;
            const label = r.int(u32) orelse return;
            const n = r.int(u8) orelse return;
            const raw = r.take(@as(usize, n) * 8) orelse return;
            const s = shareFor(p, token, .service) orelse return respond(p, id, .refused, "");
            var words: idl.Words = @splat(0);
            for (0..n) |i| words[i] = std.mem.readInt(u64, raw[i * 8 ..][0..8], .little);
            const out = idl.callWords(s.lease, label, &words, n);
            if (out.r.status != .ok) {
                // The kernel refused: the lease ran out or expired. The
                // share is over.
                g.log("comlink_served", .{ .peer = @as([]const u8, &p.name), .share = s.index, .label = label, .ok = false, .status = @tagName(out.r.status) });
                end(s);
                return respond(p, id, .refused, "");
            }
            var w: Writer = .{ .buf = &answer };
            const len = @min(out.r.tag.length, P.max_words);
            w.int(u32, out.r.tag.label);
            w.int(u8, @intCast(len));
            for (out.w[0..len]) |x| w.int(u64, x);
            g.log("comlink_served", .{ .peer = @as([]const u8, &p.name), .share = s.index, .label = label, .ok = out.r.tag.label == 0, .status = "ok" });
            respond(p, id, .ok, w.done());
        },
        .fetch => {
            const token = (r.take(16) orelse return)[0..16].*;
            const offset = r.int(u32) orelse return;
            const s = shareFor(p, token, .object) orelse return respond(p, id, .refused, "");
            const got = idl.call(TC.read, s.lease, .{ .hash = TC.Hash.from(&s.hash), .offset = offset }) catch return respond(p, id, .refused, "");
            const d = got.data.slice();
            const n = @min(d.len, chunk);
            var w: Writer = .{ .buf = &answer };
            w.int(u32, got.size);
            w.int(u16, @intCast(n));
            w.bytes(d[0..n]);
            respond(p, id, .ok, w.done());
        },
        .offer => {
            const token = (r.take(16) orelse return)[0..16].*;
            const k = std.enums.fromInt(P.Kind, r.int(u8) orelse return) orelse return;
            const name = r.take(16) orelse return;
            const protocol_id = r.int(u64) orelse return;
            const hash = (r.take(32) orelse return)[0..32].*;
            const size = r.int(u32) orelse return;
            addImport(p, token, k, name, protocol_id, hash, size);
            respond(p, id, .ok, "");
        },
        .withdraw => {
            const token = (r.take(16) orelse return)[0..16].*;
            for (&imports) |*im| if (im.used and std.mem.eql(u8, &im.token, &token) and std.mem.eql(u8, &im.from, &p.key)) {
                im.active = false;
                g.log("comlink_withdrawn", .{ .from = @as([]const u8, &p.name), .service = im.nameSlice() });
            };
            respond(p, id, .ok, "");
        },
        .response, _ => {},
    }
}

/// Send a request and wait for its answer, serving the network meanwhile
/// and sending it again until it comes (or the peer is given up on).
fn request(p: *Peer, msg: []const u8) !struct { status: Status, body: []const u8 } {
    if (p.session == null) return error.Unavailable;
    if (pending.active) return error.Unavailable;
    const id = std.mem.readInt(u32, msg[1..5], .little);
    pending = .{ .active = true, .id = id };
    defer pending.active = false;
    var tries: u32 = 1;
    sendAmphora(p, msg);
    var last = now();
    while (!pending.done) {
        const w = g.wait(sig);
        pump(w.w[0]);
        if (pending.done) break;
        if (now() - last >= resend_ms * ms) {
            if (tries == max_tries) return error.Unavailable;
            tries += 1;
            sendAmphora(p, msg);
            last = now();
        }
    }
    return .{ .status = pending.status, .body = pending.data[0..pending.len] };
}

fn newRequest(buf: []u8, kind: Msg) Writer {
    var w: Writer = .{ .buf = buf };
    w.int(u8, @backingInt(kind));
    w.int(u32, next_id);
    next_id +%= 1;
    if (next_id == 0) next_id = 1;
    return w;
}

// ---------------------------------------------------------------------------
// Shares (what this instance lends) and imports (what it was lent)

const Share = struct {
    used: bool = false,
    active: bool = false,
    index: u16 = 0,
    kind: P.Kind = .service,
    token: [16]u8 = undefined,
    to: [32]u8 = undefined,
    service: [16]u8 = @splat(0),
    hash: [32]u8 = @splat(0),
    lease: g.CPtr = 0,
    uses: u32 = 0,

    fn serviceSlice(s: *const Share) []const u8 {
        return std.mem.sliceTo(&s.service, 0);
    }
};
var shares: [16]Share = @splat(.{});

fn shareFor(p: *Peer, token: [16]u8, kind: P.Kind) ?*Share {
    for (&shares) |*s| {
        if (s.used and s.active and s.kind == kind and std.mem.eql(u8, &s.token, &token) and std.mem.eql(u8, &s.to, &p.key)) return s;
    }
    return null;
}

const Import = struct {
    used: bool = false,
    active: bool = false,
    kind: P.Kind = .service,
    from: [32]u8 = undefined,
    token: [16]u8 = undefined,
    name: [16]u8 = @splat(0),
    protocol_id: u64 = 0,
    hash: [32]u8 = @splat(0),
    size: u32 = 0,

    fn nameSlice(im: *const Import) []const u8 {
        return std.mem.sliceTo(&im.name, 0);
    }
};
var imports: [16]Import = @splat(.{});

fn addImport(p: *Peer, token: [16]u8, kind: P.Kind, name: []const u8, protocol_id: u64, hash: [32]u8, size: u32) void {
    for (&imports) |*im| if (im.used and std.mem.eql(u8, &im.token, &token)) return;
    const im = for (&imports) |*im| {
        if (!im.used) break im;
    } else return;
    im.* = .{ .used = true, .active = true, .kind = kind, .from = p.key, .token = token, .protocol_id = protocol_id, .hash = hash, .size = size };
    @memcpy(&im.name, name[0..16]);
    g.log("comlink_imported", .{ .from = @as([]const u8, &p.name), .kind = @tagName(kind), .service = im.nameSlice() });
}

/// Services Comlink keeps for itself; every other service it uses is one
/// the owner may share.
const infrastructure = [_][]const u8{ "mycelium", "kumara", "ledger", "tablecloth", "entropy" };

fn hostedService(name: []const u8) ?*const D.Service {
    for (infrastructure) |n| if (std.mem.eql(u8, n, name)) return null;
    const e = g.env();
    for (e.uses[0..e.use_count]) |*s| if (std.mem.eql(u8, D.nameOf(&s.name), name)) return s;
    return null;
}

fn record(kind: []const u8, comptime fmt: []const u8, args: anytype) void {
    const l = g.use("ledger") orelse return;
    var buf: [200]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = idl.call(proto.ledger.append, l, .{ .kind = idl.Text(24).from(kind), .text = idl.Text(200).from(text) }) catch {};
}

/// Lend `target` through a fresh lease and tell the peer about it.
fn lend(p: *Peer, kind: P.Kind, target: g.CPtr, service: []const u8, protocol_id: u64, hash: [32]u8, size: u32, uses: u32, seconds: u32) !u16 {
    const i = for (&shares, 0..) |*s, i| {
        if (!s.used) break i;
    } else return error.Unavailable;
    const lease = space.retype(.lease, 0) catch return error.Unavailable;
    const duration = @as(u64, seconds) * 1000 * ms;
    if (!g.invoke(lease, g.abi.LeaseMethod.arm, .{ target, (g.abi.Rights{ .send = true }).bits(), duration, uses }).ok()) return error.Failed;
    const s = &shares[i];
    s.* = .{ .used = true, .active = true, .index = @intCast(i), .kind = kind, .token = random()[0..16].*, .to = p.key, .hash = hash, .lease = lease, .uses = uses };
    @memcpy(s.service[0..@min(service.len, 16)], service[0..@min(service.len, 16)]);
    var buf: [128]u8 = undefined;
    var w = newRequest(&buf, .offer);
    w.bytes(&s.token);
    w.int(u8, @backingInt(kind));
    w.bytes(&s.service);
    w.int(u64, protocol_id);
    w.bytes(&hash);
    w.int(u32, size);
    const r = request(p, w.done()) catch {
        end(s);
        return error.Unavailable;
    };
    if (r.status != .ok) {
        end(s);
        return error.Failed;
    }
    g.log("comlink_shared", .{ .share = i, .kind = @tagName(kind), .service = s.serviceSlice(), .to = @as([]const u8, &p.name) });
    return @intCast(i);
}

/// The lease goes: revoked, and our only capability to it deleted.
fn end(s: *Share) void {
    _ = g.invoke(D.Slot.cnode, g.abi.CNodeMethod.revoke, .{s.lease});
    _ = g.invoke(D.Slot.cnode, g.abi.CNodeMethod.delete, .{s.lease});
    s.active = false;
}

// ---------------------------------------------------------------------------
// The timer and the signal

var last_hello: u64 = 0;

fn tick() void {
    const t = now();
    // Say hello now and then, so instances that came up later find us.
    if (t - last_hello >= 2000 * ms) {
        hello(M.broadcast, false);
        last_hello = t;
    }
    // Handshake messages are sent again until answered; one that goes
    // nowhere for long starts over (the initiator's job).
    for (&peers) |*p| if (p.used and p.hs_active) {
        if (t - p.hs_started >= 4 * handshake_ms * ms) {
            p.hs_active = false;
            maybeInitiate(p);
        } else if (t - p.hs_sent >= resend_ms * ms) resendHandshake(p);
    };
    _ = g.alarm(alarm_cap, tick_ms * ms);
}

fn drainNetwork() void {
    while (true) {
        const r = idl.call(M.recv, mycelium, .{}) catch return;
        if (!r.found) return;
        if (r.port != port) continue;
        onDatagram(r.from, r.data.slice());
    }
}

fn pump(bits: u64) void {
    if (!online) return;
    if (bits & bit_net != 0) drainNetwork();
    if (bits & bit_alarm != 0) tick();
}

// ---------------------------------------------------------------------------
// comlink.v1

fn nameText(n: []const u8) P.Name {
    return P.Name.from(n);
}

/// The peer refused: what it lent is no longer lent.
fn refusedImport(im: *Import) error{Unavailable} {
    im.active = false;
    g.log("comlink_withdrawn", .{ .from = @as([]const u8, &K.nameOf(im.from)), .service = im.nameSlice(), .reason = "refused" });
    return error.Unavailable;
}

const Server = struct {
    pub fn onSignal(_: *Server, bits: u64) void {
        pump(bits);
    }

    pub fn whoami(_: *Server, _: P.whoami.Params, _: idl.Caller) !P.whoami.Results {
        var n_peers: u16 = 0;
        for (peers) |p| n_peers += @intFromBool(p.used and p.known);
        var n_shares: u16 = 0;
        for (shares) |s| n_shares += @intFromBool(s.used);
        var n_imports: u16 = 0;
        for (imports) |im| n_imports += @intFromBool(im.used);
        return .{ .name = nameText(&my_name), .address = address, .peers = n_peers, .shares = n_shares, .imports = n_imports };
    }

    pub fn peer(_: *Server, p: P.peer.Params, _: idl.Caller) !P.peer.Results {
        var k: usize = 0;
        for (&peers) |*x| if (x.used and x.known) {
            if (k == p.index) return .{ .name = nameText(&x.name), .key = idl.Bytes(32).from(&x.key), .address = x.addr, .session = x.session != null };
            k += 1;
        };
        return error.NotFound;
    }

    pub fn share(_: *Server, p: P.share.Params, _: idl.Caller) !P.share.Results {
        const svc = hostedService(p.service.slice()) orelse return error.NotFound;
        const to = peerByName(p.to.slice()) orelse return error.NotFound;
        const i = try lend(to, .service, svc.slot, p.service.slice(), svc.protocol_id, @splat(0), 0, p.uses, p.seconds);
        record("comlink_share", "{s} to {s}, uses {d}, seconds {d}", .{ p.service.slice(), &to.name, p.uses, p.seconds });
        return .{ .share = i };
    }

    pub fn share_object(_: *Server, p: P.share_object.Params, _: idl.Caller) !P.share_object.Results {
        const store = g.use("tablecloth") orelse return error.Unavailable;
        if (p.hash.len != 32) return error.InvalidArgs;
        const to = peerByName(p.to.slice()) orelse return error.NotFound;
        const h = idl.call(TC.has, store, .{ .hash = p.hash }) catch return error.Unavailable;
        if (!h.found or h.sealed) return error.NotFound;
        const i = try lend(to, .object, store, "object", 0, p.hash.data[0..32].*, h.size, 0, 0);
        record("comlink_share", "object {x} ({d} bytes) to {s}", .{ p.hash.data[0..8], h.size, &to.name });
        return .{ .share = i };
    }

    pub fn revoke(_: *Server, p: P.revoke.Params, _: idl.Caller) !P.revoke.Results {
        if (p.share >= shares.len or !shares[p.share].used) return error.NotFound;
        const s = &shares[p.share];
        if (!s.active) return .{};
        end(s);
        record("comlink_revoke", "share {d} ({s}) from {s}", .{ p.share, s.serviceSlice(), &K.nameOf(s.to) });
        g.log("comlink_revoked", .{ .share = p.share, .service = s.serviceSlice(), .from = @as([]const u8, &K.nameOf(s.to)) });
        // Tell the holder, if it can be told; the lease is gone either way.
        if (peerByKey(s.to)) |to| {
            var buf: [64]u8 = undefined;
            var w = newRequest(&buf, .withdraw);
            w.bytes(&s.token);
            _ = request(to, w.done()) catch {};
        }
        return .{};
    }

    pub fn shared(_: *Server, p: P.shared.Params, _: idl.Caller) !P.shared.Results {
        if (p.index >= shares.len or !shares[p.index].used) return error.NotFound;
        const s = &shares[p.index];
        return .{ .kind = s.kind, .service = P.Service.from(s.serviceSlice()), .hash = P.Hash.from(&s.hash), .to = nameText(&K.nameOf(s.to)), .active = s.active, .uses = s.uses };
    }

    pub fn imported(_: *Server, p: P.imported.Params, _: idl.Caller) !P.imported.Results {
        if (p.index >= imports.len or !imports[p.index].used) return error.NotFound;
        const im = &imports[p.index];
        return .{ .kind = im.kind, .from = nameText(&K.nameOf(im.from)), .service = P.Service.from(im.nameSlice()), .protocol_id = im.protocol_id, .hash = P.Hash.from(&im.hash), .size = im.size, .active = im.active };
    }

    fn importFor(index: u16, kind: P.Kind) !struct { im: *Import, peer: *Peer } {
        if (index >= imports.len or !imports[index].used or imports[index].kind != kind) return error.NotFound;
        const im = &imports[index];
        if (!im.active) return error.Unavailable;
        const p = peerByKey(im.from) orelse return error.Unavailable;
        return .{ .im = im, .peer = p };
    }

    pub fn call(_: *Server, p: P.call.Params, _: idl.Caller) !P.call.Results {
        const t = try importFor(p.import, .service);
        const words = p.words.slice();
        if (words.len % 8 != 0) return error.InvalidArgs;
        var buf: [480]u8 = undefined;
        var w = newRequest(&buf, .request);
        w.bytes(&t.im.token);
        w.int(u32, p.label);
        w.int(u8, @intCast(words.len / 8));
        w.bytes(words);
        const r = try request(t.peer, w.done());
        if (r.status != .ok) return refusedImport(t.im);
        var rd: Reader = .{ .b = r.body };
        const label = rd.int(u32) orelse return error.Failed;
        const n = rd.int(u8) orelse return error.Failed;
        const raw = rd.take(@as(usize, n) * 8) orelse return error.Failed;
        return .{ .label = label, .words = P.Words.from(raw) };
    }

    pub fn fetch(_: *Server, p: P.fetch.Params, _: idl.Caller) !P.fetch.Results {
        const t = try importFor(p.import, .object);
        const store = g.use("tablecloth") orelse return error.Unavailable;
        if (t.im.size > fetched.len) return error.InvalidArgs;
        var off: u32 = 0;
        while (off < t.im.size) {
            var buf: [64]u8 = undefined;
            var w = newRequest(&buf, .fetch);
            w.bytes(&t.im.token);
            w.int(u32, off);
            const r = try request(t.peer, w.done());
            if (r.status != .ok) return refusedImport(t.im);
            var rd: Reader = .{ .b = r.body };
            _ = rd.int(u32) orelse return error.Failed;
            const n = rd.int(u16) orelse return error.Failed;
            const d = rd.take(n) orelse return error.Failed;
            if (n == 0 or off + n > t.im.size) return error.Failed;
            @memcpy(fetched[off..][0..n], d);
            off += n;
        }
        // Held by its content: what arrived must be what was named.
        const got = g.tablecloth.publicHash(fetched[0..t.im.size]);
        if (!std.mem.eql(u8, &got, &t.im.hash)) {
            g.log("comlink_fetch_refused", .{ .reason = "hash_mismatch" });
            return error.Failed;
        }
        const stored = TC.storeBytes(store, fetched[0..t.im.size], false) catch return error.Unavailable;
        g.log("comlink_fetched", .{ .from = @as([]const u8, &K.nameOf(t.im.from)), .hash = hex8(&stored), .size = t.im.size });
        return .{ .hash = P.Hash.from(&stored), .size = t.im.size };
    }
};

var fetched: [64 * 1024]u8 = undefined;

pub fn main() !u16 {
    space = .{ .untyped = D.Slot.memory, .vspace = D.Slot.vspace, .next_slot = D.Slot.first_free };
    ms = @max(g.env().timebase_hz / 1000, 1);
    kumara = g.use("kumara") orelse return error.NoService;
    entropy = g.use("entropy") orelse return error.NoService;
    mycelium = g.use("mycelium") orelse return error.NoService;
    sig = try space.retype(.signal, 0);
    var s: Server = .{};
    const ep = g.provided("comlink") orelse return error.NoService;

    // Without an identity or a network there is nobody to be: serve the
    // local questions, and nothing else.
    const who = idl.call(proto.kumara.whoami, kumara, .{}) catch {
        g.log("comlink_idle", .{ .reason = "no_identity" });
        idl.serve(P, ep, &s);
    };
    my_key = who.public_key.data[0..32].*;
    my_name = K.nameOf(my_key);
    my_static = staticOf(my_key) orelse return error.BadIdentity;
    const bound = idl.call(M.bind, mycelium, .{ .port = port }) catch {
        g.log("comlink_idle", .{ .reason = "no_network" });
        idl.serve(P, ep, &s);
    };
    address = bound.address;

    // Datagrams and the timer raise one signal, with their own bits.
    const net_cap = try space.slot();
    alarm_cap = try space.slot();
    const send_only = (g.abi.Rights{ .send = true }).bits();
    if (!g.invoke(D.Slot.cnode, g.abi.CNodeMethod.mint, .{ net_cap, sig, send_only, bit_net, 0 }).ok()) return error.MintFailed;
    if (!g.invoke(D.Slot.cnode, g.abi.CNodeMethod.mint, .{ alarm_cap, sig, send_only, bit_alarm, 0 }).ok()) return error.MintFailed;
    _ = try idl.call(M.listen, mycelium, .{ .signal = .{ .slot = net_cap } });
    if (g.bindSignal(sig) != .ok) return error.BindFailed;
    online = true;

    var ip: [15]u8 = undefined;
    g.log("comlink_ready", .{ .name = @as([]const u8, &my_name), .address = g.net.formatIp(address, &ip) });
    hello(M.broadcast, false);
    last_hello = now();
    _ = g.alarm(alarm_cap, tick_ms * ms);
    idl.serve(P, ep, &s);
}
