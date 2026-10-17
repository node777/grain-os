//! mycelium.v1: datagrams between instances on the local network.
//!
//! Mycelium is the network below Comlink: it drives the network device and
//! speaks just enough IPv4 (link-local addresses, ARP, UDP) to carry
//! datagrams. Each client binds one port; datagrams for it queue until it
//! takes them, and a signal it gives with `listen` is raised when some wait.
const idl = @import("grain").idl;

pub const name = "mycelium";
pub const version = 1;
pub const doc = "Datagrams to and from other instances on the local network: bind a port, send, take what arrives.";

pub const max_data = 480;
pub const Data = idl.Bytes(max_data);
/// To every instance on the link.
pub const broadcast: u32 = 0xffff_ffff;

pub const bind = idl.Method(.{ .label = 1, .effect = .mutates, .doc = "Take a UDP port for your datagrams. Returns this instance's address." }, struct {
    port: u16,
}, struct {
    address: u32,
    pub const docs = .{ .address = "This instance's IPv4 address, as a number (a link-local 169.254.x.y)" };
});

pub const listen = idl.Method(.{ .label = 2, .effect = .mutates, .doc = "Give Mycelium a signal to raise whenever datagrams wait for you." }, struct {
    signal: idl.Cap,
}, struct {});

pub const send = idl.Method(.{ .label = 3, .effect = .external, .doc = "Send a datagram from your port to an address and port (broadcast: every instance on the link)." }, struct {
    to: u32,
    port: u16,
    data: Data,
}, struct {});

pub const recv = idl.Method(.{ .label = 4, .effect = .mutates, .doc = "Take the oldest datagram for your port, if any." }, struct {}, struct {
    found: bool,
    from: u32,
    port: u16,
    data: Data,
    pub const docs = .{ .from = "The sender's address", .port = "The sender's port" };
});

pub const info = idl.Method(.{ .label = 5, .effect = .pure, .doc = "This instance's link address and counters." }, struct {}, struct {
    address: u32,
    mac: idl.Bytes(6),
    sent: u64,
    received: u64,
    dropped: u64,
    pub const docs = .{ .dropped = "Datagrams that arrived for no port, or for a full queue" };
});
