//! ledger: the append-only record of who did what, with whose authority.
//!
//! Each entry names its predecessor's hash, the client that appended it
//! (from the badge; nobody can append as someone else), what happened, and
//! Kumara's signature over all of that. Entries are sealed in the store
//! (only the Ledger opens them); the newest is the secret tip `head`, and
//! every append is committed before it returns.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");
const P = proto.ledger;
const TC = proto.tablecloth;
const idl = g.idl;

pub const panic = g.panic;
pub const std_options = g.std_options;
comptime {
    g.exportStart();
}

pub const Entry = extern struct {
    seq: u64,
    prev: [32]u8,
    by: [24]u8,
    kind: [24]u8,
    text_len: u16,
    _pad: [6]u8 = @splat(0),
    text: [200]u8,
    /// Kumara's signature (context "ledger") over the BLAKE3 of all the above.
    signature: [64]u8,

    fn body(e: *const Entry) []const u8 {
        return std.mem.asBytes(e)[0..@offsetOf(Entry, "signature")];
    }
};

var store: g.CPtr = 0;
var kumara: g.CPtr = 0;
var head_hash: [32]u8 = @splat(0);
var head_seq: u64 = 0;
var available = false;

fn setText(dst: []u8, src: []const u8) void {
    @memset(dst, 0);
    @memcpy(dst[0..@min(dst.len, src.len)], src[0..@min(dst.len, src.len)]);
}

fn readEntry(h: [32]u8) !Entry {
    var e: Entry = undefined;
    const got = try TC.readBytes(store, h, std.mem.asBytes(&e));
    if (got.len != @sizeOf(Entry)) return error.Corrupt;
    return e;
}

const Server = struct {
    pub fn append(_: *Server, p: P.append.Params, c: idl.Caller) !P.append.Results {
        if (!available) return error.Unavailable;
        const by = if (c.badge == 0) "steward" else g.env().clientName(c.badge) orelse return error.Unavailable;
        var e: Entry = .{ .seq = head_seq + 1, .prev = head_hash, .by = undefined, .kind = undefined, .text_len = @intCast(p.text.slice().len), .text = undefined, .signature = @splat(0) };
        setText(&e.by, by);
        setText(&e.kind, p.kind.slice());
        setText(&e.text, p.text.slice());
        var digest: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(e.body(), &digest, .{});
        const s = try idl.call(proto.kumara.sign, kumara, .{ .message = idl.Bytes(256).from(&digest) });
        e.signature = s.signature.data[0..64].*;
        // Each entry keeps the one before it, so only the head needs a name.
        const h = try TC.storeLinked(store, std.mem.asBytes(&e), true, if (head_seq == 0) null else head_hash);
        _ = try idl.call(TC.bind, store, .{ .name = TC.NameText.from("head"), .hash = TC.Hash.from(&h), .secret = true, .tip = true });
        _ = try idl.call(TC.commit, store, .{});
        head_hash = h;
        head_seq = e.seq;
        g.log("ledger_appended", .{ .seq = e.seq, .by = by, .kind = p.kind.slice() });
        return .{ .seq = e.seq, .hash = idl.Bytes(32).from(&h) };
    }

    pub fn head(_: *Server, _: P.head.Params, _: idl.Caller) !P.head.Results {
        if (!available) return error.Unavailable;
        return .{ .seq = head_seq, .hash = idl.Bytes(32).from(&head_hash) };
    }

    pub fn entry(_: *Server, p: P.entry.Params, _: idl.Caller) !P.entry.Results {
        if (!available) return error.Unavailable;
        if (p.hash.len != 32) return error.InvalidArgs;
        const e = try readEntry(p.hash.data[0..32].*);
        return .{
            .seq = e.seq,
            .prev = idl.Bytes(32).from(&e.prev),
            .by = idl.Text(23).from(std.mem.sliceTo(&e.by, 0)),
            .kind = idl.Text(24).from(std.mem.sliceTo(&e.kind, 0)),
            .text = idl.Text(200).from(e.text[0..@min(e.text_len, e.text.len)]),
            .signature = idl.Bytes(64).from(&e.signature),
        };
    }
};

pub fn main() !u16 {
    store = g.use("tablecloth") orelse return error.NoService;
    kumara = g.use("kumara") orelse return error.NoService;
    if (TC.find(store, "head", true)) |found| {
        if (found) |h| {
            head_hash = h;
            head_seq = (try readEntry(h)).seq;
        }
        available = true;
        g.log("ledger_ready", .{ .entries = head_seq });
    } else |e| g.log("ledger_unavailable", .{ .err = @errorName(e) });
    _ = g.call(g.domain.Slot.steward, .{ .label = @backingInt(g.domain.Lifecycle.ready), .length = 1 }, .{1});
    var s: Server = .{};
    idl.serve(P, g.provided("ledger") orelse return error.NoService, &s);
}
