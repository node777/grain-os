//! registry.v1: what every protocol in the system is, by id.
const idl = @import("grain").idl;

pub const name = "registry";
pub const version = 1;
pub const doc = "Descriptors for every protocol in this system, by protocol id. Ask it what a capability speaks.";

pub const count = idl.Method(.{ .label = 1, .effect = .pure, .doc = "How many protocols are known." }, struct {}, struct {
    count: u64,
    pub const docs = .{ .count = "Number of protocols" };
});

pub const nth = idl.Method(.{ .label = 2, .effect = .pure, .doc = "The id and name of protocol number index." }, struct {
    index: u64,
    pub const docs = .{ .index = "0 .. count-1" };
}, struct {
    id: u64,
    name: idl.Bytes(24),
    pub const docs = .{ .id = "Protocol id (hash of its descriptor)", .name = "e.g. console.v1" };
});

pub const lookup = idl.Method(.{ .label = 3, .effect = .pure, .doc = "The name of a protocol, by id." }, struct {
    id: u64,
    pub const docs = .{ .id = "Protocol id" };
}, struct {
    name: idl.Bytes(24),
    found: bool,
    pub const docs = .{ .name = "e.g. console.v1", .found = "Whether the id is known" };
});

pub const describe = idl.Method(.{ .label = 4, .effect = .pure, .doc = "A piece of the protocol's JSON descriptor: 24 bytes from offset." }, struct {
    id: u64,
    offset: u64,
    pub const docs = .{ .id = "Protocol id", .offset = "Byte offset into the descriptor" };
}, struct {
    total: u64,
    chunk: idl.Bytes(24),
    pub const docs = .{ .total = "Descriptor length in bytes", .chunk = "Up to 24 bytes starting at offset" };
});
