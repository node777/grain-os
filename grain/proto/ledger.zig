//! ledger.v1: the append-only record of who did what, with whose authority.
const idl = @import("grain").idl;

pub const name = "ledger";
pub const version = 1;
pub const doc = "The append-only, hash-chained, signed record of authority events. Each entry names who appended it (Ledger knows its callers; they cannot claim to be someone else).";

pub const append = idl.Method(.{ .label = 1, .effect = .external, .doc = "Append an entry, durably. Returns its number and hash." }, struct {
    kind: idl.Text(24),
    text: idl.Text(200),
    pub const docs = .{ .kind = "What happened, e.g. agent_call", .text = "Details" };
}, struct {
    seq: u64,
    hash: idl.Bytes(32),
});

pub const head = idl.Method(.{ .label = 2, .effect = .pure, .doc = "The newest entry." }, struct {}, struct {
    seq: u64,
    hash: idl.Bytes(32),
});

pub const entry = idl.Method(.{ .label = 3, .effect = .pure, .doc = "One entry by hash; follow `prev` to walk back to the first." }, struct {
    hash: idl.Bytes(32),
}, struct {
    seq: u64,
    prev: idl.Bytes(32),
    by: idl.Text(23),
    kind: idl.Text(24),
    text: idl.Text(200),
    signature: idl.Bytes(64),
    pub const docs = .{ .prev = "The entry before (zero for the first)", .by = "Who appended it", .signature = "Kumara's signature (context ledger) over the entry" };
});
