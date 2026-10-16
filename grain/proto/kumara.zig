//! kumara.v1: this instance's identity.
const idl = @import("grain").idl;

pub const name = "kumara";
pub const version = 1;
pub const doc = "This instance's identity: an Ed25519 key that never leaves Kumara, named by three words drawn from it.";

pub const whoami = idl.Method(.{ .label = 1, .effect = .pure, .doc = "The identity's name and public key." }, struct {}, struct {
    name: idl.Text(14),
    public_key: idl.Bytes(32),
    pub const docs = .{ .name = "Three words from the v1 word bank, e.g. kelp-oryx-lute", .public_key = "The Ed25519 public key: the identity itself" };
});

pub const sign = idl.Method(.{ .label = 2, .effect = .external, .doc = "Sign a message as this identity. The signature binds the caller's name as its context, so it cannot pass as one made for anyone else." }, struct {
    message: idl.Bytes(256),
}, struct {
    signature: idl.Bytes(64),
    context: idl.Text(23),
    pub const docs = .{ .context = "The context that was bound: the caller's name" };
});
