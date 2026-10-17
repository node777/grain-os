//! comlink.v1: other instances, by identity.
//!
//! Comlink finds instances on the link, opens an end-to-end encrypted
//! session with each (Noise XX, keyed by the two identities), and carries
//! capabilities between them. Sharing a service or an object with another
//! identity makes a *sturdy reference*: a secret token, sent to that identity
//! alone, behind which stands a kernel Lease on Comlink's own capability.
//! Revoking it ends the lease; the holder's next use is refused.
//!
//! What others share with this instance arrives as *imports*: a service is
//! called through `call` (Envoy shows it to an agent as an ordinary typed
//! capability, `guestbook@sift-noon-city`), and an object is brought home
//! with `fetch`, its hash checked on arrival.
const idl = @import("grain").idl;

pub const name = "comlink";
pub const version = 1;
pub const doc = "Other instances, by identity: who is near, end-to-end sessions with them, and capabilities shared both ways, each backed by a lease and revocable.";

pub const Name = idl.Text(14);
pub const Service = idl.Text(16);
pub const Hash = idl.Bytes(32);
pub const max_words = 50;
pub const Words = idl.Bytes(max_words * 8);
pub const Kind = enum { service, object };

pub const whoami = idl.Method(.{ .label = 1, .effect = .pure, .doc = "This instance's name and network address, and how many peers it knows." }, struct {}, struct {
    name: Name,
    address: u32,
    peers: u16,
    shares: u16,
    imports: u16,
});

pub const peer = idl.Method(.{ .label = 2, .effect = .pure, .doc = "Peer `index`: its name, identity key, address, and whether a session is open." }, struct {
    index: u16,
}, struct {
    name: Name,
    key: idl.Bytes(32),
    address: u32,
    session: bool,
});

pub const share = idl.Method(.{ .label = 3, .effect = .external, .doc = "Share one of the services this instance hosts with a peer, by name: a lease, at most `uses` calls (0: no limit) and `seconds` long (0: until revoked). Recorded in the Ledger." }, struct {
    service: Service,
    to: Name,
    uses: u32,
    seconds: u32,
}, struct {
    share: u16,
});

pub const share_object = idl.Method(.{ .label = 4, .effect = .external, .doc = "Share a public object in the store with a peer, who can then fetch it. Recorded in the Ledger." }, struct {
    hash: Hash,
    to: Name,
}, struct {
    share: u16,
});

pub const revoke = idl.Method(.{ .label = 5, .effect = .external, .doc = "End a share: its lease is revoked, and the peer's next use is refused. Recorded in the Ledger." }, struct {
    share: u16,
}, struct {});

pub const shared = idl.Method(.{ .label = 6, .effect = .pure, .doc = "Share `index`: what, with whom, and whether it still stands." }, struct {
    index: u16,
}, struct {
    kind: Kind,
    service: Service,
    hash: Hash,
    to: Name,
    active: bool,
    uses: u32,
});

pub const imported = idl.Method(.{ .label = 7, .effect = .pure, .doc = "Import `index`: what a peer shared with this instance." }, struct {
    index: u16,
}, struct {
    kind: Kind,
    from: Name,
    service: Service,
    protocol_id: u64,
    hash: Hash,
    size: u32,
    active: bool,
});

pub const call = idl.Method(.{ .label = 8, .effect = .external, .doc = "Call a method of an imported service: its label and encoded words go to the peer, and its answer comes back the same way. (Envoy does the encoding for agents.)" }, struct {
    import: u16,
    label: u32,
    words: Words,
}, struct {
    label: u32,
    words: Words,
});

pub const fetch = idl.Method(.{ .label = 9, .effect = .external, .doc = "Bring an imported object home: fetched from the peer, checked against its hash, and stored here as a public object." }, struct {
    import: u16,
}, struct {
    hash: Hash,
    size: u32,
});
