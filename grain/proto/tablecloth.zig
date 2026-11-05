//! tablecloth.v1: the content store.
//!
//! Objects are named by their hash. Each client works in its own space:
//! the names it binds are kept under its own name (`kumara` binding
//! `secret` makes `kumara/secret`), and a sealed object opens only for the
//! client that stored it. Public objects can be read by anyone.
//!
//! Space comes back through `reclaim`: objects no name, generation, boot
//! state or link keeps alive are dropped. An object stored and committed
//! without a name is garbage at the next reclaim.
const idl = @import("grain").idl;

pub const name = "tablecloth";
pub const version = 1;
pub const doc = "The content store: put and read objects by hash, bind names to them, commit atomically, and choose the system generation to boot.";

pub const chunk = 480;
pub const Hash = idl.Bytes(32);
pub const NameText = idl.Text(39);

pub const info = idl.Method(.{ .label = 1, .effect = .pure, .doc = "The store's state." }, struct {}, struct {
    blocks: u64,
    used: u64,
    free: u64,
    objects: u32,
    seq: u64,
    locked: bool,
    current: Hash,
    pending: Hash,
    previous: Hash,
    tries: u32,
    pub const docs = .{
        .blocks = "Disk size in 4 KiB blocks",
        .used = "Blocks the committed log uses",
        .free = "Blocks free for new objects",
        .objects = "Objects stored",
        .seq = "Commit number",
        .locked = "Whether sealed objects are unavailable (no passphrase given yet)",
        .current = "The generation that last booted and was confirmed",
        .pending = "A generation on trial (zero if none)",
        .previous = "What was current before the last switch (rollback goes there)",
        .tries = "Boots of the pending generation so far",
    };
});

pub const put = idl.Method(.{ .label = 2, .effect = .mutates, .doc = "Store up to 480 public bytes in one call; returns their hash." }, struct {
    data: idl.Bytes(chunk),
}, struct { hash: Hash });

pub const write = idl.Method(.{ .label = 3, .effect = .mutates, .doc = "Stage bytes of a larger object at an offset (up to 64 KiB in all); `store` stores them." }, struct {
    offset: u32,
    data: idl.Bytes(chunk),
}, struct {});

pub const store = idl.Method(.{ .label = 4, .effect = .mutates, .doc = "Store the first `len` staged bytes, public or sealed for you alone, keeping `link` (another object, or empty) alive as long as they are; returns their hash." }, struct {
    len: u32,
    sealed: bool,
    link: Hash,
}, struct { hash: Hash });

pub const read = idl.Method(.{ .label = 5, .effect = .pure, .doc = "Up to 480 bytes of an object from an offset, checked against its hash." }, struct {
    hash: Hash,
    offset: u32,
}, struct {
    size: u32,
    data: idl.Bytes(chunk),
    pub const docs = .{ .size = "The whole object's size" };
});

pub const has = idl.Method(.{ .label = 6, .effect = .pure, .doc = "Whether an object is stored." }, struct { hash: Hash }, struct {
    found: bool,
    size: u32,
    sealed: bool,
});

pub const bind = idl.Method(.{ .label = 7, .effect = .mutates, .doc = "Bind one of your names to an object. A Mantra name is bound once and then means those bytes forever; a tip moves. Secret names are sealed." }, struct {
    name: NameText,
    hash: Hash,
    secret: bool,
    tip: bool,
}, struct {});

pub const lookup = idl.Method(.{ .label = 8, .effect = .pure, .doc = "What one of your names is bound to." }, struct {
    name: NameText,
    secret: bool,
}, struct { hash: Hash, found: bool });

pub const commit = idl.Method(.{ .label = 9, .effect = .external, .doc = "Make everything so far durable, atomically. Returns the commit number." }, struct {}, struct { seq: u64 });

pub const switch_to = idl.Method(.{ .label = 10, .effect = .external, .doc = "Boot this stored generation next, on trial: it becomes current once a boot of it comes up whole; if none does in a few tries, Aurora goes back. Commits." }, struct {
    generation: Hash,
}, struct {});

pub const rollback = idl.Method(.{ .label = 11, .effect = .external, .doc = "Go back to the previous generation, on trial like any switch. Commits; returns which one." }, struct {}, struct {
    generation: Hash,
});

pub const retire = idl.Method(.{ .label = 12, .effect = .mutates, .doc = "Retire one of your names. A retired Mantra name means nothing and can never be bound again; a tip just goes." }, struct {
    name: NameText,
    secret: bool,
}, struct {});

pub const forget = idl.Method(.{ .label = 13, .effect = .external, .doc = "Let a generation go: its names retire and it is no longer the rollback target. Not the current or pending one. Commits." }, struct {
    generation: Hash,
}, struct {});

pub const reclaim = idl.Method(.{ .label = 14, .effect = .external, .doc = "Bring back space at the oldest end of the log, up to `budget` blocks: live objects there move forward, the rest are dropped. Commits." }, struct {
    budget: u32,
}, struct {
    dropped: u32,
    copied: u32,
    free: u64,
    pub const docs = .{ .dropped = "Objects dropped", .copied = "Live objects moved forward", .free = "Blocks free afterwards" };
});

// ---------------------------------------------------------------------------
// Client helpers

const grain = @import("grain");

/// Store bytes of any size up to 64 KiB (staged 480 at a time), public or
/// sealed for the caller; returns the hash.
pub fn storeBytes(ep: grain.CPtr, data: []const u8, sealed: bool) idl.CallError![32]u8 {
    return storeLinked(ep, data, sealed, null);
}

/// `storeBytes`, keeping `link` alive as long as the new object is.
pub fn storeLinked(ep: grain.CPtr, data: []const u8, sealed: bool, link: ?[32]u8) idl.CallError![32]u8 {
    var off: usize = 0;
    while (off < data.len) {
        const n = @min(data.len - off, chunk);
        _ = try idl.call(write, ep, .{ .offset = @intCast(off), .data = idl.Bytes(chunk).from(data[off..][0..n]) });
        off += n;
    }
    const r = try idl.call(store, ep, .{ .len = @intCast(data.len), .sealed = sealed, .link = if (link) |l| Hash.from(&l) else .{} });
    return r.hash.data;
}

/// Read a whole object into `buf`.
pub fn readBytes(ep: grain.CPtr, hash: [32]u8, buf: []u8) idl.CallError![]u8 {
    var off: usize = 0;
    while (true) {
        const r = try idl.call(read, ep, .{ .hash = Hash.from(&hash), .offset = @intCast(off) });
        if (r.size > buf.len) return error.InvalidArgs;
        const d = r.data.slice();
        @memcpy(buf[off..][0..d.len], d);
        off += d.len;
        if (off >= r.size or d.len == 0) return buf[0..r.size];
    }
}

pub fn find(ep: grain.CPtr, name_: []const u8, secret: bool) idl.CallError!?[32]u8 {
    const r = try idl.call(lookup, ep, .{ .name = NameText.from(name_), .secret = secret });
    return if (r.found) r.hash.data else null;
}

pub const passphrase = idl.Method(.{ .label = 15, .effect = .external, .doc = "Change the passphrase, given the current one. Nothing sealed changes, only how its key is wrapped; one commit, so a power cut leaves either passphrase working. The owner's settings alone may ask." }, struct {
    current: idl.Text(96),
    new: idl.Text(96),
}, struct {});
