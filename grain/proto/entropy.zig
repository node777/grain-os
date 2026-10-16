//! entropy.v1: random bytes from a hardware source.
const idl = @import("grain").idl;

pub const name = "entropy";
pub const version = 1;
pub const doc = "Random bytes from a hardware entropy source.";

pub const get = idl.Method(.{ .label = 1, .effect = .pure, .doc = "Return 32 fresh random bytes. Changes nothing else." }, struct {}, struct {
    bytes: idl.Bytes(32),
    pub const docs = .{ .bytes = "32 random bytes" };
});
