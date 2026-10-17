//! Measured boot. The loader (Aurora) hashes its own code and the
//! generation it chose into a chain, as a TPM extends a register: each
//! step folds the previous value, a label and a hash into a new value, so
//! the chain names exactly what booted, in order. The kernel passes it to
//! Steward in BootInfo, Steward to every domain, the Ledger records it, and
//! Kumara signs it with a verifier's nonce (an attestation).
//!
//! What it proves rests on what measured the loader. On QEMU nothing does:
//! a modified Aurora could report anything. On hardware whose boot ROM
//! measures Aurora (DICE, or a TPM), the chain starts there.
const std = @import("std");
const abi = @import("abi");
const Blake3 = std.crypto.hash.Blake3;

pub const Hash = [32]u8;
pub const zero: Hash = @splat(0);

/// The Kumara signing context for attestations. Domain names are
/// [a-z0-9_]: no domain can ask Kumara to sign under this one.
pub const attest_context = "@attest";

pub fn extend(prev: Hash, label: []const u8, h: Hash) Hash {
    var b = Blake3.initKdf("grain measure v1", .{});
    b.update(&prev);
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, label.len, .little);
    b.update(&len);
    b.update(label);
    b.update(&h);
    var out: Hash = undefined;
    b.final(&out);
    return out;
}

pub fn chain(loader: Hash, generation: Hash) Hash {
    return extend(extend(zero, "loader", loader), "generation", generation);
}

pub fn measurement(loader_code: []const u8, generation: Hash) abi.Measurement {
    var loader: Hash = undefined;
    Blake3.hash(loader_code, &loader, .{});
    return .{ .chain = chain(loader, generation), .loader = loader, .generation = generation };
}

/// Whether a measurement is consistent: its chain is the one its parts make.
pub fn consistent(m: abi.Measurement) bool {
    return std.mem.eql(u8, &m.chain, &chain(m.loader, m.generation));
}

/// What an attestation signs: the measurement and the verifier's nonce.
pub fn attestMessage(m: abi.Measurement, nonce: [32]u8) [128]u8 {
    var out: [128]u8 = undefined;
    @memcpy(out[0..32], &m.chain);
    @memcpy(out[32..64], &m.loader);
    @memcpy(out[64..96], &m.generation);
    @memcpy(out[96..128], &nonce);
    return out;
}

test "the chain is ordered and names its parts" {
    const a: Hash = @splat(1);
    const b: Hash = @splat(2);
    try std.testing.expect(!std.mem.eql(u8, &chain(a, b), &chain(b, a)));
    const m = measurement("loader code", b);
    try std.testing.expect(consistent(m));
    var bad = m;
    bad.generation[0] ^= 1;
    try std.testing.expect(!consistent(bad));
    // Labels are length-prefixed: "ab"+"c" is not "a"+"bc".
    try std.testing.expect(!std.mem.eql(u8, &extend(zero, "ab", a), &extend(zero, "a", a)));
    // Known answer, from the independent Python check (tools/envoy.py).
    try std.testing.expectEqualStrings("775e9e18464620fc8e3e5941ac1d542d0c65b5925201399cce75a09fd231d042", &std.fmt.bytesToHex(chain(a, b), .lower));
}
