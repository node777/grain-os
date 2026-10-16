//! kumara: this instance's identity.
//!
//! On the first boot of a disk it draws a 32-byte seed from the entropy
//! service, seals it in the store (sealed objects open only for the domain
//! that stored them) and binds it as its secret name `seed`; on every later
//! boot it reads the seed back. The key never leaves this domain: others
//! ask it to sign, and the signature binds who asked.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");
const K = g.kumara;
const P = proto.kumara;
const TC = proto.tablecloth;
const idl = g.idl;

pub const panic = g.panic;
pub const std_options = g.std_options;
comptime {
    g.exportStart();
}

var key: ?K.Ed25519.KeyPair = null;
var name: K.Name = undefined;

const Server = struct {
    pub fn whoami(_: *Server, _: P.whoami.Params, _: idl.Caller) !P.whoami.Results {
        const kp = key orelse return error.Unavailable;
        return .{ .name = idl.Text(14).from(&name), .public_key = idl.Bytes(32).from(&kp.public_key.toBytes()) };
    }

    pub fn sign(_: *Server, p: P.sign.Params, c: idl.Caller) !P.sign.Results {
        const kp = key orelse return error.Unavailable;
        const context = if (c.badge == 0) "steward" else g.env().clientName(c.badge) orelse return error.Unavailable;
        const sig = K.sign(kp, context, p.message.slice()) catch return error.Failed;
        return .{ .signature = idl.Bytes(64).from(&sig), .context = idl.Text(23).from(context) };
    }
};

/// Load the identity, or make it on a new disk. Returns whether it was made.
fn load(store: g.CPtr, entropy: g.CPtr) !bool {
    var seed: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    if (try TC.find(store, "seed", true)) |h| {
        const got = try TC.readBytes(store, h, &seed);
        if (got.len != 32) return error.Corrupt;
        key = try K.keyPair(seed);
        return false;
    }
    const r = try idl.call(proto.entropy.get, entropy, .{});
    @memcpy(&seed, r.bytes.slice()[0..32]);
    const kp = try K.keyPair(seed);
    const sealed = try TC.storeBytes(store, &seed, true);
    _ = try idl.call(TC.bind, store, .{ .name = TC.NameText.from("seed"), .hash = TC.Hash.from(&sealed), .secret = true, .tip = false });
    const public = try TC.storeBytes(store, &kp.public_key.toBytes(), false);
    _ = try idl.call(TC.bind, store, .{ .name = TC.NameText.from("public"), .hash = TC.Hash.from(&public), .secret = false, .tip = false });
    _ = try idl.call(TC.commit, store, .{});
    key = kp;
    return true;
}

pub fn main() !u16 {
    const store = g.use("tablecloth") orelse return error.NoService;
    const entropy = g.use("entropy") orelse return error.NoService;
    if (load(store, entropy)) |created| {
        const pk = key.?.public_key.toBytes();
        name = K.nameOf(pk);
        g.log("kumara_ready", .{ .name = @as([]const u8, &name), .key = g.klog.hex(std.mem.readInt(u64, pk[0..8], .big)), .created = created });
    } else |e| g.log("kumara_unavailable", .{ .err = @errorName(e) });
    _ = g.call(g.domain.Slot.steward, .{ .label = @backingInt(g.domain.Lifecycle.ready), .length = 1 }, .{1});
    var s: Server = .{};
    idl.serve(P, g.provided("kumara") orelse return error.NoService, &s);
}
