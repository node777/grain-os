//! Noise_XX_25519_ChaChaPoly_BLAKE2s: the handshake Comlink sessions begin
//! with (the Noise Protocol Framework, revision 34).
//!
//!     XX:  -> e
//!          <- e, ee, s, es
//!          -> s, se
//!
//! Both sides learn the other's static key, and only the holder of a static
//! key can complete it. In Grain the static key is the instance's identity
//! (Kumara's Ed25519 key in its X25519 form), whose secret never leaves
//! Kumara: the two Diffie-Hellman operations that need it go through a
//! callback (`dh.agree(peer_public)`), so this file never sees it.
//!
//! After the handshake, transport messages carry their counter explicitly
//! (8 bytes, little-endian) and a receiver accepts each counter at most
//! once and only going forward, as WireGuard does: datagrams may be lost or
//! reordered, and a replay is refused.
const std = @import("std");
const X25519 = std.crypto.dh.X25519;
const Blake2s = std.crypto.hash.blake2.Blake2s256;
const Hmac = std.crypto.auth.hmac.Hmac(Blake2s);
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const protocol_name = "Noise_XX_25519_ChaChaPoly_BLAKE2s";
pub const key_len = 32;
pub const tag_len = Aead.tag_length;
pub const Key = [key_len]u8;

pub const Error = error{ Decrypt, OutOfOrder, BadMessage, Identity };

fn hkdf(ck: Key, ikm: []const u8, out1: *Key, out2: *Key) void {
    var temp: Key = undefined;
    Hmac.create(&temp, ikm, &ck);
    Hmac.create(out1, &[_]u8{1}, &temp);
    var in2: [key_len + 1]u8 = undefined;
    @memcpy(in2[0..key_len], out1);
    in2[key_len] = 2;
    Hmac.create(out2, &in2, &temp);
}

fn nonce(n: u64) [Aead.nonce_length]u8 {
    var out: [Aead.nonce_length]u8 = @splat(0);
    std.mem.writeInt(u64, out[4..12], n, .little);
    return out;
}

const Symmetric = struct {
    h: Key,
    ck: Key,
    k: ?Key = null,
    n: u64 = 0,

    fn init(prologue: []const u8) Symmetric {
        var h: Key = undefined;
        Blake2s.hash(protocol_name, &h, .{}); // longer than 32 bytes: hashed
        var s: Symmetric = .{ .h = h, .ck = h };
        s.mixHash(prologue);
        return s;
    }

    fn mixHash(s: *Symmetric, data: []const u8) void {
        var b = Blake2s.init(.{});
        b.update(&s.h);
        b.update(data);
        b.final(&s.h);
    }

    fn mixKey(s: *Symmetric, ikm: []const u8) void {
        var k: Key = undefined;
        hkdf(s.ck, ikm, &s.ck, &k);
        s.k = k;
        s.n = 0;
    }

    /// Append the encryption of `p` (or `p` itself before any key) to out.
    fn encryptAndHash(s: *Symmetric, out: []u8, p: []const u8) []u8 {
        const c = if (s.k) |k| blk: {
            Aead.encrypt(out[0..p.len], out[p.len..][0..tag_len], p, &s.h, nonce(s.n), k);
            s.n += 1;
            break :blk out[0 .. p.len + tag_len];
        } else blk: {
            @memcpy(out[0..p.len], p);
            break :blk out[0..p.len];
        };
        s.mixHash(c);
        return c;
    }

    fn decryptAndHash(s: *Symmetric, out: []u8, c: []const u8) Error![]u8 {
        const p = if (s.k) |k| blk: {
            if (c.len < tag_len) return error.BadMessage;
            const n = c.len - tag_len;
            Aead.decrypt(out[0..n], c[0..n], c[n..][0..tag_len].*, &s.h, nonce(s.n), k) catch return error.Decrypt;
            s.n += 1;
            break :blk out[0..n];
        } else blk: {
            @memcpy(out[0..c.len], c);
            break :blk out[0..c.len];
        };
        s.mixHash(c);
        return p;
    }

    fn overhead(s: *const Symmetric) usize {
        return if (s.k == null) 0 else tag_len;
    }
};

/// One side's half of the XX handshake. Messages go in order: the
/// initiator writes, reads, writes; the responder reads, writes, reads.
pub const Handshake = struct {
    sym: Symmetric,
    initiator: bool,
    e: X25519.KeyPair,
    s: Key,
    re: Key = undefined,
    rs: Key = undefined,
    step: u2 = 0,

    /// `s` is this side's static public key; `ephemeral` seeds a fresh
    /// ephemeral key (from good entropy, never reused).
    pub fn init(initiator: bool, s: Key, ephemeral: Key, prologue: []const u8) Handshake {
        return .{ .sym = .init(prologue), .initiator = initiator, .e = .generateDeterministic(ephemeral), .s = s };
    }

    pub fn done(hs: *const Handshake) bool {
        return hs.step == 3;
    }

    fn mine(hs: *const Handshake) bool {
        // Messages 0 and 2 are the initiator's.
        return (hs.step % 2 == 0) == hs.initiator;
    }

    fn mixDh(hs: *Handshake, secret: Key, public: Key) Error!void {
        const shared = X25519.scalarmult(secret, public) catch return error.BadMessage;
        hs.sym.mixKey(&shared);
    }

    /// Write the next message, carrying `payload`, into `out`. `dh` does the
    /// Diffie-Hellman with this side's static secret.
    pub fn write(hs: *Handshake, out: []u8, payload: []const u8, dh: anytype) (Error || @TypeOf(dh).Error)![]u8 {
        if (!hs.mine() or hs.done()) return error.OutOfOrder;
        var n: usize = 0;
        switch (hs.step) {
            0 => {
                @memcpy(out[0..32], &hs.e.public_key);
                hs.sym.mixHash(&hs.e.public_key);
                n = 32;
            },
            1 => {
                @memcpy(out[0..32], &hs.e.public_key);
                hs.sym.mixHash(&hs.e.public_key);
                n = 32;
                try hs.mixDh(hs.e.secret_key, hs.re); // ee
                n += hs.sym.encryptAndHash(out[n..], &hs.s).len; // s
                hs.sym.mixKey(&try dh.agree(hs.re)); // es: our static, their ephemeral
            },
            2 => {
                n = hs.sym.encryptAndHash(out, &hs.s).len; // s
                hs.sym.mixKey(&try dh.agree(hs.re)); // se: our static, their ephemeral
            },
            3 => unreachable,
        }
        n += hs.sym.encryptAndHash(out[n..], payload).len;
        hs.step += 1;
        return out[0..n];
    }

    /// Read the other side's next message into `out`; returns its payload.
    pub fn read(hs: *Handshake, msg: []const u8, out: []u8) Error![]u8 {
        if (hs.mine() or hs.done()) return error.OutOfOrder;
        var m = msg;
        switch (hs.step) {
            0 => {
                if (m.len < 32) return error.BadMessage;
                hs.re = m[0..32].*;
                hs.sym.mixHash(&hs.re);
                m = m[32..];
            },
            1 => {
                if (m.len < 32 + 32 + tag_len) return error.BadMessage;
                hs.re = m[0..32].*;
                hs.sym.mixHash(&hs.re);
                m = m[32..];
                try hs.mixDh(hs.e.secret_key, hs.re); // ee
                var rs: [32]u8 = undefined;
                _ = try hs.sym.decryptAndHash(&rs, m[0 .. 32 + tag_len]);
                hs.rs = rs;
                m = m[32 + tag_len ..];
                try hs.mixDh(hs.e.secret_key, hs.rs); // es: our ephemeral, their static
            },
            2 => {
                if (m.len < 32 + tag_len) return error.BadMessage;
                var rs: [32]u8 = undefined;
                _ = try hs.sym.decryptAndHash(&rs, m[0 .. 32 + tag_len]);
                hs.rs = rs;
                m = m[32 + tag_len ..];
                try hs.mixDh(hs.e.secret_key, hs.rs); // se: our ephemeral, their static
            },
            3 => unreachable,
        }
        if (m.len < hs.sym.overhead()) return error.BadMessage;
        const p = try hs.sym.decryptAndHash(out, m);
        hs.step += 1;
        return p;
    }

    /// The other side's static key (once its message carrying it was read).
    pub fn remoteStatic(hs: *const Handshake) Key {
        return hs.rs;
    }

    /// The keys for the session, once the handshake is done.
    pub fn split(hs: *const Handshake) Session {
        var k1: Key = undefined;
        var k2: Key = undefined;
        hkdf(hs.sym.ck, "", &k1, &k2);
        return .{
            .send_key = if (hs.initiator) k1 else k2,
            .recv_key = if (hs.initiator) k2 else k1,
            .hash = hs.sym.h,
        };
    }
};

/// Overhead of a transport message: its counter and its tag.
pub const transport_overhead = 8 + tag_len;

pub const Session = struct {
    send_key: Key,
    recv_key: Key,
    /// The handshake hash: both sides hold the same one.
    hash: Key,
    sent: u64 = 0,
    /// The next counter that may be accepted.
    next_recv: u64 = 0,

    pub fn encrypt(s: *Session, out: []u8, plain: []const u8) []u8 {
        const n = s.sent;
        s.sent += 1;
        std.mem.writeInt(u64, out[0..8], n, .little);
        Aead.encrypt(out[8..][0..plain.len], out[8 + plain.len ..][0..tag_len], plain, "", nonce(n), s.send_key);
        return out[0 .. plain.len + transport_overhead];
    }

    pub fn decrypt(s: *Session, out: []u8, msg: []const u8) Error![]u8 {
        if (msg.len < transport_overhead) return error.BadMessage;
        const n = std.mem.readInt(u64, msg[0..8], .little);
        if (n < s.next_recv) return error.OutOfOrder;
        const len = msg.len - transport_overhead;
        Aead.decrypt(out[0..len], msg[8..][0..len], msg[8 + len ..][0..tag_len].*, "", nonce(n), s.recv_key) catch return error.Decrypt;
        s.next_recv = n + 1;
        return out[0..len];
    }
};

/// A static key held in memory (for tests and tools; Grain's lives in Kumara).
pub const LocalStatic = struct {
    pair: X25519.KeyPair,
    pub const Error = error{BadMessage};
    pub fn agree(l: LocalStatic, peer: Key) LocalStatic.Error!Key {
        return X25519.scalarmult(l.pair.secret_key, peer) catch error.BadMessage;
    }
};

const testing = std.testing;

fn seed(b: u8) Key {
    return @splat(b);
}

test "XX: both sides finish with each other's static key and the same session" {
    const si: LocalStatic = .{ .pair = .generateDeterministic(seed(1)) };
    const sr: LocalStatic = .{ .pair = .generateDeterministic(seed(2)) };
    var i = Handshake.init(true, si.pair.public_key, seed(3), "grain comlink v1");
    var r = Handshake.init(false, sr.pair.public_key, seed(4), "grain comlink v1");
    var buf: [256]u8 = undefined;
    var got: [256]u8 = undefined;

    const m1 = try i.write(&buf, "hi", si);
    try testing.expectEqualStrings("hi", try r.read(m1, &got));
    const m2 = try r.write(&buf, "responder", sr);
    try testing.expectEqualStrings("responder", try i.read(m2, &got));
    try testing.expectEqualSlices(u8, &sr.pair.public_key, &i.remoteStatic());
    const m3 = try i.write(&buf, "initiator", si);
    try testing.expectEqualStrings("initiator", try r.read(m3, &got));
    try testing.expectEqualSlices(u8, &si.pair.public_key, &r.remoteStatic());
    try testing.expect(i.done() and r.done());

    var a = i.split();
    var b = r.split();
    try testing.expectEqualSlices(u8, &a.hash, &b.hash);
    const t1 = a.encrypt(&buf, "first");
    // Known answers, from an independent implementation (tools/noise_ref.py).
    try testing.expectEqualStrings("791b010ff7da7bde56dd3136b5907602943532b6fead532d05d9c920c5ef1bbf", &std.fmt.bytesToHex(a.hash, .lower));
    var hex: [128]u8 = undefined;
    try testing.expectEqualStrings("00000000000000000607ff589821645c09f368558a787b18e8160b417e", std.fmt.bufPrint(&hex, "{x}", .{t1}) catch unreachable);
    try testing.expectEqualStrings("first", try b.decrypt(&got, t1));
    try testing.expectError(error.OutOfOrder, b.decrypt(&got, t1)); // a replay
    const t2 = b.encrypt(&buf, "back");
    var copy: [64]u8 = undefined;
    @memcpy(copy[0..t2.len], t2);
    copy[10] ^= 1;
    try testing.expectError(error.Decrypt, a.decrypt(&got, copy[0..t2.len]));
    try testing.expectEqualStrings("back", try a.decrypt(&got, t2));
}

test "XX: a responder without the static key it claims cannot finish" {
    const si: LocalStatic = .{ .pair = .generateDeterministic(seed(1)) };
    const sr: LocalStatic = .{ .pair = .generateDeterministic(seed(2)) };
    const impostor: LocalStatic = .{ .pair = .generateDeterministic(seed(9)) };
    var i = Handshake.init(true, si.pair.public_key, seed(3), "grain comlink v1");
    // Claims sr's public key, but computes with another secret.
    var r = Handshake.init(false, sr.pair.public_key, seed(4), "grain comlink v1");
    var buf: [256]u8 = undefined;
    var got: [256]u8 = undefined;
    _ = try r.read(try i.write(&buf, "", si), &got);
    const m2 = try r.write(&buf, "", impostor);
    try testing.expectError(error.Decrypt, i.read(m2, &got));
}
