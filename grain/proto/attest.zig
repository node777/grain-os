//! attest.v1: what booted, signed by this instance's identity.
const idl = @import("grain").idl;

pub const name = "attest";
pub const version = 1;
pub const doc = "Attestation: this instance's identity signs the measured-boot chain (what booted) together with a verifier's fresh nonce. Nothing else can be signed through it.";

pub const quote = idl.Method(.{ .label = 1, .effect = .pure, .doc = "Sign what booted, with a fresh nonce so the answer cannot be replayed. All-zero hashes mean the boot was not measured." }, struct {
    nonce: idl.Bytes(32),
    pub const docs = .{ .nonce = "32 bytes the verifier chose" };
}, struct {
    signature: idl.Bytes(64),
    public_key: idl.Bytes(32),
    chain: idl.Bytes(32),
    loader: idl.Bytes(32),
    generation: idl.Bytes(32),
    pub const docs = .{
        .signature = "Ed25519, context @attest, over chain, loader, generation and nonce",
        .public_key = "The identity that signed",
        .chain = "The measured-boot chain",
        .loader = "BLAKE3 of the loader's code (Aurora)",
        .generation = "The generation booted (its descriptor's hash)",
    };
});
