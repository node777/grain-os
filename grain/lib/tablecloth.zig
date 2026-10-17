//! Tablecloth: holds things by their content.
//!
//! Ask for the same bytes and you get the same bytes, forever. An object is
//! named by its hash; Mantra names bind words to hashes (`system@3`); and the
//! store survives a power cut at any instant.
//!
//! On disk (4 KiB blocks):
//!
//!     block 0, 1   two superblock slots; the valid one with the higher `seq`
//!                  is the truth
//!     block 2..    the log, circular: object bytes packed end to end, then
//!                  the table, from `head` (nothing live is older) to `tail`
//!
//! Log positions only grow; position p lives in block 2 + (p / 4096) mod the
//! log's size, so the log wraps around the disk. Every commit appends
//! (objects, then a new table) at the tail, flushes, writes the *other*
//! superblock slot, and flushes again. Nothing a committed superblock points
//! at is ever overwritten (appends stop at the committed head), so a crash
//! leaves either the old state or the new one, and a torn superblock write
//! fails its checksum and the other slot wins.
//!
//! Space comes back by **reclaiming** the oldest part of the log: objects
//! there that are still live (reachable from a name, the boot state, a
//! generation, or a link) are copied to the tail, the rest are dropped, and
//! one commit moves the head past them.
//!
//! Objects are **public** (named by BLAKE3 of their bytes; the system's
//! generations, which Aurora reads before anyone unlocks the disk) or
//! **sealed**: encrypted with XChaCha20-Poly1305 under the master key, and
//! named by a keyed BLAKE3 of (owner, plaintext), where the owner is the
//! domain that stored it. The nonce is that name, so equal plaintexts from
//! one owner still deduplicate and nothing but equality leaks (the SIV
//! construction), and an object opens only for its owner: another domain
//! that learns the name still gets `NotFound`. The master key is wrapped by
//! a key Argon2id derives from the owner's passphrase.
//!
//! The store is generic over a block device with
//!     read(block, *Block) !void, write(block, *const Block) !void, flush() !void
//! and needs no allocator: capacities are fixed at comptime.
const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;
const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
/// Generation descriptors are public objects the store can read: their
/// chunks stay live while the descriptor does.
pub const generation = @import("generation.zig");

pub const block_size = 4096;
pub const Block = [block_size]u8;
pub const Hash = [32]u8;
pub const zero: Hash = @splat(0);
/// Larger content is a list of objects (see aurora.zig for boot images).
pub const max_object = 64 * 1024;
pub const tag_len = Aead.tag_length;
pub const name_len = 40;
pub const first_log_block = 2;

pub const Error = error{
    NotFormatted,
    Corrupt,
    NoSpace,
    TooLarge,
    Full,
    Locked,
    BadPassphrase,
    NotFound,
    BadName,
    /// A Mantra name is bound once: it may not change.
    NameTaken,
    AlreadyUnlocked,
    /// The generation is current or on trial.
    InUse,
    Io,
    OutOfMemory,
};

/// Where bytes are in the log.
pub const Ref = extern struct {
    offset: u64 = 0,
    len: u32 = 0,
    _pad: u32 = 0,
    hash: Hash = zero,
};

/// The generation state Aurora reads and writes. A new generation is
/// `pending` until a boot of it is confirmed; after `max_tries` unconfirmed
/// boots Aurora gives up on it and boots `current` again.
pub const Boot = extern struct {
    current: Hash = zero,
    pending: Hash = zero,
    /// What was current before the last confirmed switch: rollback's target.
    previous: Hash = zero,
    tries: u32 = 0,
    max_tries: u32 = 3,
};

/// The master key, wrapped by Argon2id(passphrase). `t` and `m_kib` are the
/// Argon2id costs, chosen when the disk is formatted; `set` is 0 until the
/// owner first sets a passphrase.
pub const Lock = extern struct {
    set: u32 = 0,
    t: u32 = 2,
    m_kib: u32 = 16 * 1024,
    _pad: u32 = 0,
    salt: [16]u8 = @splat(0),
    nonce: [24]u8 = @splat(0),
    wrapped: [32]u8 = @splat(0),
    tag: [16]u8 = @splat(0),

    pub fn isSet(l: Lock) bool {
        return l.set != 0;
    }
};

pub const magic = "tblcloth".*;
pub const version: u32 = 2;

pub const Super = extern struct {
    magic: [8]u8 = magic,
    version: u32 = version,
    _pad: u32 = 0,
    seq: u64 = 0,
    blocks: u64 = 0,
    /// Log position (bytes) before which nothing is live.
    head: u64 = 0,
    /// The first log block (position / 4096) no committed state uses.
    tail: u64 = 0,
    table: Ref = .{},
    boot: Boot = .{},
    lock: Lock = .{},
    /// BLAKE3 of every byte above.
    sum: Hash = zero,

    fn checksum(s: *const Super) Hash {
        var h: Hash = undefined;
        Blake3.hash(std.mem.asBytes(s)[0..@offsetOf(Super, "sum")], &h, .{});
        return h;
    }

    fn valid(s: *const Super) bool {
        return std.mem.eql(u8, &s.magic, &magic) and s.version == version and
            std.mem.eql(u8, &s.sum, &s.checksum()) and s.blocks > first_log_block + 1 and
            s.tail * block_size >= s.head and s.tail - s.head / block_size <= s.blocks - first_log_block;
    }

    pub fn logBlocks(s: *const Super) u64 {
        return s.blocks - first_log_block;
    }

    /// Blocks the committed log occupies, from the head's block to the tail.
    pub fn usedBlocks(s: *const Super) u64 {
        return s.tail - s.head / block_size;
    }
};

comptime {
    std.debug.assert(@sizeOf(Super) <= block_size);
    std.debug.assert(@sizeOf(Super) == 8 + 8 + 8 + 8 + 8 + 8 + @sizeOf(Ref) + @sizeOf(Boot) + @sizeOf(Lock) + 32);
}

pub const flag_sealed: u32 = 1;

/// One object in the table.
pub const Entry = extern struct {
    hash: Hash,
    /// Its log position.
    offset: u64,
    /// Bytes stored (sealed: plaintext + tag).
    len: u32,
    flags: u32,
    /// Another object this one keeps alive (a chain's previous link), or zero.
    link: Hash = zero,

    pub fn sealed(e: Entry) bool {
        return e.flags & flag_sealed != 0;
    }

    pub fn size(e: Entry) u32 {
        return if (e.sealed()) e.len - tag_len else e.len;
    }
};

pub const flag_tip: u32 = 1;
pub const flag_retired: u32 = 2;

/// A name. Mantra names are bound once and then mean those bytes forever,
/// until *retired*: then they mean nothing, and can never be bound again
/// (the name stays in the table as a tombstone). A *tip* (`flag_tip`) is a
/// name that moves, such as the head of a chain.
pub const Name = extern struct {
    name: [name_len]u8,
    hash: Hash,
    flags: u32,
    _pad: u32 = 0,

    pub fn text(n: *const Name) []const u8 {
        return std.mem.sliceTo(&n.name, 0);
    }
};

const table_magic = "tblindx2".*;

const TableHeader = extern struct {
    magic: [8]u8 = table_magic,
    objects: u32,
    names: u32,
    /// The sealed object that holds the secret names (zero = none).
    secret_names: Hash,
};

/// Names are [a-z0-9] and `_ - . / @`, 1 to 39 bytes.
pub fn validName(n: []const u8) bool {
    if (n.len == 0 or n.len >= name_len) return false;
    for (n) |c| switch (c) {
        'a'...'z', '0'...'9', '_', '-', '.', '/', '@' => {},
        else => return false,
    };
    return true;
}

pub const Keys = struct {
    enc: [32]u8,
    addr: [32]u8,

    pub fn derive(master: [32]u8) Keys {
        var k: Keys = undefined;
        var a = Blake3.initKdf("grain tablecloth v1 seal", .{});
        a.update(&master);
        a.final(&k.enc);
        var b = Blake3.initKdf("grain tablecloth v1 address", .{});
        b.update(&master);
        b.final(&k.addr);
        return k;
    }
};

pub fn publicHash(data: []const u8) Hash {
    var h: Hash = undefined;
    Blake3.hash(data, &h, .{});
    return h;
}

/// Owners are domain names (at most 23 bytes); the name is hashed padded,
/// so "ab" + "c..." can't collide with "a" + "bc...".
pub const owner_len = 24;

pub fn sealedHash(keys: *const Keys, owner: []const u8, data: []const u8) Hash {
    var pad: [owner_len]u8 = @splat(0);
    @memcpy(pad[0..@min(owner.len, owner_len - 1)], owner[0..@min(owner.len, owner_len - 1)]);
    var b = Blake3.init(.{ .key = keys.addr });
    b.update(&pad);
    b.update(data);
    var h: Hash = undefined;
    b.final(&h);
    return h;
}

pub const Capacity = struct {
    objects: usize = 4096,
    names: usize = 256,
    secret_names: usize = 256,
};

/// Argon2id costs, stored per disk so a test disk can be cheap.
pub const KdfCost = struct { t: u32 = 2, m_kib: u32 = 16 * 1024 };

/// The store itself keeps its secret names under this owner.
const store_owner = "tablecloth";

pub fn Store(comptime Dev: type, comptime cap: Capacity) type {
    return struct {
        const Self = @This();

        dev: *Dev,
        /// The last committed superblock (with `boot` as it will next commit).
        sup: Super,
        objects: [cap.objects]Entry = undefined,
        n_objects: usize = 0,
        names: [cap.names]Name = undefined,
        n_names: usize = 0,
        secrets: [cap.secret_names]Name = undefined,
        n_secrets: usize = 0,
        /// The sealed object holding the secret names in the committed table.
        secret_names: Hash = zero,
        keys: ?Keys = null,
        /// Next free log position, and the block it falls in, buffered.
        cursor: u64,
        tail: Block = @splat(0),
        dirty: bool = false,
        secrets_dirty: bool = false,
        io: Block = undefined,

        // --- Formatting and mounting ----------------------------------------

        /// Write an empty store over the device's `blocks` blocks and mount
        /// it in `s`. `cost` is what unlocking will cost (Argon2id), forever
        /// after. (A store is large: it lives in place, never on the stack.)
        pub fn format(s: *Self, dev: *Dev, blocks: u64, cost: KdfCost) Error!void {
            if (blocks < first_log_block + 2) return error.NoSpace;
            if (cost.t < 1 or cost.m_kib < 8) return error.BadPassphrase;
            s.* = .{ .dev = dev, .sup = .{ .blocks = blocks, .seq = 0, .lock = .{ .t = cost.t, .m_kib = cost.m_kib } }, .cursor = 0 };
            var empty: Block = @splat(0);
            try s.devWrite(0, &empty);
            try s.devWrite(1, &empty);
            s.dirty = true;
            try s.commit();
        }

        /// Mount the store on `dev` into `s`.
        pub fn mount(s: *Self, dev: *Dev) Error!void {
            s.* = .{ .dev = dev, .sup = undefined, .cursor = 0 };
            var best: ?Super = null;
            for (0..2) |slot| {
                try s.devRead(slot, &s.io);
                const c = std.mem.bytesToValue(Super, s.io[0..@sizeOf(Super)]);
                if (!c.valid()) continue;
                if (best == null or c.seq > best.?.seq) best = c;
            }
            s.sup = best orelse return error.NotFormatted;
            s.cursor = s.sup.tail * block_size;
            try s.loadTable();
        }

        fn loadTable(s: *Self) Error!void {
            const t = s.sup.table;
            var h = Blake3.init(.{});
            var r = s.reader(t.offset, t.len);
            var hdr: TableHeader = undefined;
            try r.readInto(std.mem.asBytes(&hdr), &h);
            if (!std.mem.eql(u8, &hdr.magic, &table_magic)) return error.Corrupt;
            if (hdr.objects > cap.objects or hdr.names > cap.names) return error.Full;
            if (t.len != @sizeOf(TableHeader) + hdr.objects * @sizeOf(Entry) + hdr.names * @sizeOf(Name)) return error.Corrupt;
            try r.readInto(std.mem.sliceAsBytes(s.objects[0..hdr.objects]), &h);
            try r.readInto(std.mem.sliceAsBytes(s.names[0..hdr.names]), &h);
            var got: Hash = undefined;
            h.final(&got);
            if (!std.mem.eql(u8, &got, &t.hash)) return error.Corrupt;
            s.n_objects = hdr.objects;
            s.n_names = hdr.names;
            s.secret_names = hdr.secret_names;
        }

        // --- Device and log I/O ---------------------------------------------

        fn devRead(s: *Self, block: u64, buf: *Block) Error!void {
            s.dev.read(block, buf) catch return error.Io;
        }

        fn devWrite(s: *Self, block: u64, buf: *const Block) Error!void {
            s.dev.write(block, buf) catch return error.Io;
        }

        fn devFlush(s: *Self) Error!void {
            s.dev.flush() catch return error.Io;
        }

        fn cursorBlock(s: *const Self) u64 {
            return s.cursor / block_size;
        }

        /// The device block that holds log block `v`.
        fn phys(s: *const Self, v: u64) u64 {
            return first_log_block + v % s.sup.logBlocks();
        }

        /// Append bytes at the cursor; full blocks go to the device at once.
        /// The log may not reach the *committed* head: what the last commit
        /// points at stays intact until the next one says otherwise.
        fn append(s: *Self, bytes: []const u8) Error!void {
            var rest = bytes;
            while (rest.len > 0) {
                if (s.cursorBlock() >= s.sup.head / block_size + s.sup.logBlocks()) return error.NoSpace;
                const at: usize = @intCast(s.cursor % block_size);
                const n = @min(rest.len, block_size - at);
                @memcpy(s.tail[at..][0..n], rest[0..n]);
                s.cursor += n;
                rest = rest[n..];
                if (s.cursor % block_size == 0) {
                    try s.devWrite(s.phys(s.cursorBlock() - 1), &s.tail);
                    s.tail = @splat(0);
                }
            }
        }

        const Reader = struct {
            s: *Self,
            offset: u64,
            end: u64,

            fn readInto(r: *Reader, out: []u8, h: ?*Blake3) Error!void {
                if (r.offset + out.len > r.end) return error.Corrupt;
                var done: usize = 0;
                while (done < out.len) {
                    const block = r.offset / block_size;
                    const at: usize = @intCast(r.offset % block_size);
                    const n = @min(out.len - done, block_size - at);
                    // The block under the cursor may not be on the device yet.
                    const src: *const Block = if (block == r.s.cursorBlock() and r.s.cursor % block_size != 0) &r.s.tail else blk: {
                        try r.s.devRead(r.s.phys(block), &r.s.io);
                        break :blk &r.s.io;
                    };
                    @memcpy(out[done..][0..n], src[at..][0..n]);
                    done += n;
                    r.offset += n;
                }
                if (h) |hh| hh.update(out);
            }
        };

        fn reader(s: *Self, offset: u64, len: u64) Reader {
            return .{ .s = s, .offset = offset, .end = offset + len };
        }

        // --- Objects --------------------------------------------------------

        fn find(s: *const Self, h: Hash) ?usize {
            const Ctx = struct {
                fn order(key: Hash, e: Entry) std.math.Order {
                    return std.mem.order(u8, &key, &e.hash);
                }
            };
            return std.sort.binarySearch(Entry, s.objects[0..s.n_objects], h, Ctx.order);
        }

        pub fn has(s: *const Self, h: Hash) bool {
            return s.find(h) != null;
        }

        pub fn entry(s: *const Self, h: Hash) ?Entry {
            return if (s.find(h)) |i| s.objects[i] else null;
        }

        fn insert(s: *Self, e: Entry) Error!void {
            if (s.n_objects == cap.objects) return error.Full;
            var i: usize = s.n_objects;
            while (i > 0 and std.mem.order(u8, &s.objects[i - 1].hash, &e.hash) == .gt) : (i -= 1) s.objects[i] = s.objects[i - 1];
            s.objects[i] = e;
            s.n_objects += 1;
            s.dirty = true;
        }

        /// Store public bytes; returns their name (BLAKE3). Storing what is
        /// already there costs nothing.
        pub fn put(s: *Self, data: []const u8) Error!Hash {
            return s.putLinked(data, zero);
        }

        /// `put`, keeping `link` alive as long as this object is.
        pub fn putLinked(s: *Self, data: []const u8, link: Hash) Error!Hash {
            if (data.len > max_object) return error.TooLarge;
            const h = publicHash(data);
            if (s.has(h)) return h;
            const at = s.cursor;
            try s.append(data);
            try s.insert(.{ .hash = h, .offset = at, .len = @intCast(data.len), .flags = 0, .link = link });
            return h;
        }

        /// Store bytes sealed under the master key, for `owner` alone;
        /// returns their keyed name. `scratch` must hold `data.len + tag_len`.
        pub fn seal(s: *Self, owner: []const u8, data: []const u8, scratch: []u8) Error!Hash {
            return s.sealLinked(owner, data, scratch, zero);
        }

        /// `seal`, keeping `link` alive as long as this object is.
        pub fn sealLinked(s: *Self, owner: []const u8, data: []const u8, scratch: []u8, link: Hash) Error!Hash {
            const k = s.keys orelse return error.Locked;
            if (data.len > max_object) return error.TooLarge;
            const h = sealedHash(&k, owner, data);
            if (s.has(h)) return h;
            const ct = scratch[0 .. data.len + tag_len];
            Aead.encrypt(ct[0..data.len], ct[data.len..][0..tag_len], data, &h, h[0..24].*, k.enc);
            const at = s.cursor;
            try s.append(ct);
            try s.insert(.{ .hash = h, .offset = at, .len = @intCast(ct.len), .flags = flag_sealed, .link = link });
            return h;
        }

        /// Read an object, checked against its name. A sealed object opens
        /// only for its `owner` (others get NotFound). `buf` must hold its
        /// stored length (`entry(h).len`); returns the plaintext.
        pub fn get(s: *Self, h: Hash, owner: []const u8, buf: []u8) Error![]u8 {
            const e = s.entry(h) orelse return error.NotFound;
            if (buf.len < e.len) return error.TooLarge;
            var r = s.reader(e.offset, e.len);
            try r.readInto(buf[0..e.len], null);
            if (e.sealed()) {
                const k = s.keys orelse return error.Locked;
                const n = e.len - tag_len;
                Aead.decrypt(buf[0..n], buf[0..n], buf[n..][0..tag_len].*, &h, h[0..24].*, k.enc) catch return error.Corrupt;
                if (!std.mem.eql(u8, &sealedHash(&k, owner, buf[0..n]), &h)) {
                    @memset(buf[0..n], 0);
                    return error.NotFound;
                }
                return buf[0..n];
            }
            if (!std.mem.eql(u8, &publicHash(buf[0..e.len]), &h)) return error.Corrupt;
            return buf[0..e.len];
        }

        // --- Names ----------------------------------------------------------

        fn nameList(s: *Self, secret: bool) Error!struct { items: []Name, n: *usize } {
            if (secret) {
                if (s.keys == null) return error.Locked;
                return .{ .items = &s.secrets, .n = &s.n_secrets };
            }
            return .{ .items = &s.names, .n = &s.n_names };
        }

        fn findName(list: []const Name, name: []const u8) ?usize {
            for (list, 0..) |*n, i| if (std.mem.eql(u8, n.text(), name)) return i;
            return null;
        }

        /// Bind a Mantra name (once: rebinding it to other bytes is refused),
        /// or move a tip. Secret names live in a sealed object.
        pub fn bind(s: *Self, name: []const u8, h: Hash, secret: bool, tip: bool) Error!void {
            if (!validName(name)) return error.BadName;
            if (!s.has(h)) return error.NotFound;
            const l = try s.nameList(secret);
            if (findName(l.items[0..l.n.*], name)) |i| {
                const n = &l.items[i];
                if (n.flags & flag_retired != 0) return error.NameTaken;
                if (n.flags & flag_tip == 0 or !tip) {
                    if (std.mem.eql(u8, &n.hash, &h) and (n.flags & flag_tip != 0) == tip) return;
                    return error.NameTaken;
                }
                n.hash = h;
            } else {
                if (l.n.* == l.items.len) return error.Full;
                var n: Name = .{ .name = @splat(0), .hash = h, .flags = if (tip) flag_tip else 0 };
                @memcpy(n.name[0..name.len], name);
                l.items[l.n.*] = n;
                l.n.* += 1;
            }
            if (secret) s.secrets_dirty = true;
            s.dirty = true;
        }

        pub fn lookup(s: *Self, name: []const u8, secret: bool) Error!?Hash {
            const l = try s.nameList(secret);
            const i = findName(l.items[0..l.n.*], name) orelse return null;
            return if (l.items[i].flags & flag_retired != 0) null else l.items[i].hash;
        }

        /// Retire a name: a Mantra name then means nothing, and can never be
        /// bound again; a tip just goes. What only it kept alive can then be
        /// reclaimed.
        pub fn retire(s: *Self, name: []const u8, secret: bool) Error!void {
            const l = try s.nameList(secret);
            const i = findName(l.items[0..l.n.*], name) orelse return error.NotFound;
            if (l.items[i].flags & flag_retired != 0) return;
            retireAt(l.items, l.n, i);
            if (secret) s.secrets_dirty = true;
            s.dirty = true;
        }

        fn retireAt(items: []Name, n: *usize, i: usize) void {
            if (items[i].flags & flag_tip != 0) {
                items[i] = items[n.* - 1];
                n.* -= 1;
            } else {
                items[i].hash = zero;
                items[i].flags |= flag_retired;
            }
        }

        pub fn publicNames(s: *const Self) []const Name {
            return s.names[0..s.n_names];
        }

        // --- Commit ---------------------------------------------------------

        /// Make everything so far durable, atomically.
        pub fn commit(s: *Self) Error!void {
            var next = s.sup;
            next.seq += 1;
            if (s.dirty) {
                if (s.secrets_dirty) {
                    var buf: [cap.secret_names * @sizeOf(Name) + tag_len]u8 = undefined;
                    const plain = std.mem.sliceAsBytes(s.secrets[0..s.n_secrets]);
                    if (plain.len > max_object) return error.TooLarge;
                    s.secret_names = try s.seal(store_owner, plain, &buf);
                }
                const hdr: TableHeader = .{ .objects = @intCast(s.n_objects), .names = @intCast(s.n_names), .secret_names = s.secret_names };
                var h = Blake3.init(.{});
                const at = s.cursor;
                const parts = [_][]const u8{ std.mem.asBytes(&hdr), std.mem.sliceAsBytes(s.objects[0..s.n_objects]), std.mem.sliceAsBytes(s.names[0..s.n_names]) };
                var len: u64 = 0;
                for (parts) |p| {
                    h.update(p);
                    try s.append(p);
                    len += p.len;
                }
                if (s.cursor % block_size != 0) try s.devWrite(s.phys(s.cursorBlock()), &s.tail);
                next.table = .{ .offset = at, .len = @intCast(len) };
                h.final(&next.table.hash);
                next.tail = std.math.divCeil(u64, s.cursor, block_size) catch unreachable;
                // Nothing live is older than the oldest object or the table.
                var head = at;
                for (s.objects[0..s.n_objects]) |e| head = @min(head, e.offset);
                next.head = head;
                try s.devFlush();
            }
            next.sum = next.checksum();
            @memset(&s.io, 0);
            @memcpy(s.io[0..@sizeOf(Super)], std.mem.asBytes(&next));
            try s.devWrite(next.seq % 2, &s.io);
            try s.devFlush();
            s.sup = next;
            s.cursor = next.tail * block_size;
            s.tail = @splat(0);
            s.dirty = false;
            s.secrets_dirty = false;
        }

        // --- Reclaiming space -----------------------------------------------

        /// Log blocks free for appending.
        pub fn freeBlocks(s: *const Self) u64 {
            return s.sup.head / block_size + s.sup.logBlocks() - (std.math.divCeil(u64, s.cursor, block_size) catch unreachable);
        }

        const Marks = std.StaticBitSet(cap.objects);

        /// Mark `first` and everything its links keep alive.
        fn markChain(s: *const Self, live: *Marks, first: Hash) void {
            var h = first;
            while (s.find(h)) |i| {
                if (live.isSet(i)) return;
                live.set(i);
                h = s.objects[i].link;
            }
        }

        /// Mark a root; a generation descriptor also keeps its chunks.
        fn markRoot(s: *Self, live: *Marks, scanned: *Marks, h: Hash) Error!void {
            const i = s.find(h) orelse return;
            s.markChain(live, h);
            if (scanned.isSet(i)) return;
            scanned.set(i);
            const e = s.objects[i];
            const G = generation;
            if (e.sealed() or e.len < @sizeOf(G.Header)) return;
            var hasher = Blake3.init(.{});
            var r = s.reader(e.offset, e.len);
            var hd: G.Header = undefined;
            try r.readInto(std.mem.asBytes(&hd), &hasher);
            if (!std.mem.eql(u8, &hd.magic, &G.magic)) return;
            if (e.len != @sizeOf(G.Header) + @as(u64, hd.segments) * @sizeOf(G.Segment) + @as(u64, hd.chunks) * 32) return;
            var seg: G.Segment = undefined;
            for (0..hd.segments) |_| try r.readInto(std.mem.asBytes(&seg), &hasher);
            for (0..hd.chunks) |_| {
                var c: Hash = undefined;
                try r.readInto(&c, &hasher);
                s.markChain(live, c);
            }
            var got: Hash = undefined;
            hasher.final(&got);
            if (!std.mem.eql(u8, &got, &h)) return error.Corrupt;
        }

        /// What is live: everything the boot state, a name or the secret
        /// names reach, through generation descriptors and links. Secret
        /// names are roots too, so this needs the store unlocked.
        fn mark(s: *Self, live: *Marks) Error!void {
            if (s.passphraseSet() and s.keys == null) return error.Locked;
            var scanned: Marks = .empty;
            const b = s.sup.boot;
            for ([_]Hash{ b.current, b.pending, b.previous }) |h| try s.markRoot(live, &scanned, h);
            for (s.names[0..s.n_names]) |n| try s.markRoot(live, &scanned, n.hash);
            for (s.secrets[0..s.n_secrets]) |n| try s.markRoot(live, &scanned, n.hash);
            s.markChain(live, s.secret_names);
        }

        pub const Reclaimed = extern struct {
            /// Objects dropped, and live ones copied forward.
            dropped: u32,
            copied: u32,
            /// Log blocks free afterwards.
            free: u64,
        };

        /// Clear up to `budget` blocks at the head of the log: copy what is
        /// still live there to the tail, drop the rest, and commit, which
        /// moves the head past them. When the live part would not fit in the
        /// free space, the budget shrinks until it does.
        pub fn reclaim(s: *Self, budget: u64) Error!Reclaimed {
            var live: Marks = .empty;
            try s.mark(&live);
            const head = s.sup.head;
            var target = @min(s.sup.tail * block_size, (head / block_size + budget) * block_size);
            while (target > head) {
                var need: u64 = 2 * block_size + @sizeOf(TableHeader) + s.n_objects * @sizeOf(Entry) + s.n_names * @sizeOf(Name);
                if (s.secrets_dirty) need += s.n_secrets * @sizeOf(Name) + tag_len;
                for (s.objects[0..s.n_objects], 0..) |e, i| {
                    if (e.offset < target and live.isSet(i)) need += e.len;
                }
                if (need <= s.freeBlocks() * block_size) break;
                target = @max(head, (head / block_size + (target / block_size - head / block_size) / 2) * block_size);
            }
            // Only the committed log is cleared: what was stored since the
            // last commit stays, live or not, until a later reclaim.
            var out: Reclaimed = .{ .dropped = 0, .copied = 0, .free = 0 };
            var buf: Block = undefined;
            for (s.objects[0..s.n_objects], 0..) |*e, i| {
                if (e.offset >= target or !live.isSet(i)) continue;
                const at = s.cursor;
                var r = s.reader(e.offset, e.len);
                var left: usize = e.len;
                while (left > 0) {
                    const n = @min(left, block_size);
                    try r.readInto(buf[0..n], null);
                    try s.append(buf[0..n]);
                    left -= n;
                }
                e.offset = at;
                out.copied += 1;
            }
            var kept: usize = 0;
            for (0..s.n_objects) |i| {
                if (s.objects[i].offset < target and !live.isSet(i)) {
                    out.dropped += 1;
                    continue;
                }
                s.objects[kept] = s.objects[i];
                kept += 1;
            }
            s.n_objects = kept;
            s.dirty = true;
            try s.commit();
            out.free = s.freeBlocks();
            return out;
        }

        /// Let a generation go: every public name for it retires, and it is
        /// no longer the one to roll back to. The current or pending one
        /// cannot go. Commits; a reclaim then frees what only it used.
        pub fn forget(s: *Self, gen: Hash) Error!void {
            const b = &s.sup.boot;
            if (std.mem.eql(u8, &gen, &b.current) or std.mem.eql(u8, &gen, &b.pending)) return error.InUse;
            if (std.mem.eql(u8, &gen, &b.previous)) b.previous = zero;
            var i: usize = 0;
            while (i < s.n_names) {
                const n = &s.names[i];
                if (std.mem.eql(u8, &n.hash, &gen) and n.flags & flag_retired == 0) {
                    const tip = n.flags & flag_tip != 0;
                    retireAt(&s.names, &s.n_names, i);
                    if (tip) continue;
                }
                i += 1;
            }
            s.dirty = true;
            try s.commit();
        }

        // --- The lock -------------------------------------------------------

        pub fn locked(s: *const Self) bool {
            return s.keys == null;
        }

        pub fn passphraseSet(s: *const Self) bool {
            return s.sup.lock.isSet();
        }

        fn kek(gpa: std.mem.Allocator, pass: []const u8, l: Lock) Error![32]u8 {
            var k: [32]u8 = undefined;
            std.crypto.pwhash.argon2.kdf(gpa, &k, pass, &l.salt, .{ .t = l.t, .m = l.m_kib, .p = 1 }, .argon2id, std.Io.failing) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Corrupt,
            };
            return k;
        }

        /// First boot: make the master key from `entropy` and wrap it with
        /// the passphrase. Commits. `gpa` backs Argon2's memory.
        pub fn create(s: *Self, gpa: std.mem.Allocator, pass: []const u8, entropy: [64]u8) Error!void {
            if (s.passphraseSet()) return error.AlreadyUnlocked;
            // entropy: 32 bytes of master key, 16 of salt, 16 that seed the nonce.
            var l = s.sup.lock;
            const master = entropy[0..32].*;
            try wrap(gpa, pass, master, &l, entropy[32..64].*);
            s.sup.lock = l;
            s.keys = Keys.derive(master);
            try s.commit();
        }

        fn unwrap(gpa: std.mem.Allocator, pass: []const u8, l: Lock) Error![32]u8 {
            if (!l.isSet()) return error.NotFound;
            const k = try kek(gpa, pass, l);
            var master: [32]u8 = undefined;
            Aead.decrypt(&master, &l.wrapped, l.tag, "grain tablecloth v1 lock", l.nonce, k) catch return error.BadPassphrase;
            return master;
        }

        fn wrap(gpa: std.mem.Allocator, pass: []const u8, master: [32]u8, l: *Lock, entropy: [32]u8) Error!void {
            l.set = 1;
            l.salt = entropy[0..16].*;
            var nonce: Hash = undefined;
            Blake3.hash(entropy[16..32], &nonce, .{});
            l.nonce = nonce[0..24].*;
            const k = try kek(gpa, pass, l.*);
            Aead.encrypt(&l.wrapped, &l.tag, &master, "grain tablecloth v1 lock", l.nonce, k);
        }

        /// Change the passphrase. The master key stays (nothing sealed
        /// changes); only its wrapping does, under a fresh salt from
        /// `entropy`. One commit: a power cut leaves the old passphrase or
        /// the new one working.
        pub fn rekey(s: *Self, gpa: std.mem.Allocator, old: []const u8, new: []const u8, entropy: [32]u8) Error!void {
            const master = try unwrap(gpa, old, s.sup.lock);
            var l = s.sup.lock;
            try wrap(gpa, new, master, &l, entropy);
            s.sup.lock = l;
            try s.commit();
        }

        pub fn unlock(s: *Self, gpa: std.mem.Allocator, pass: []const u8) Error!void {
            if (s.keys != null) return error.AlreadyUnlocked;
            const master = try unwrap(gpa, pass, s.sup.lock);
            s.keys = Keys.derive(master);
            if (!std.mem.eql(u8, &s.secret_names, &zero)) {
                const e = s.entry(s.secret_names) orelse return error.Corrupt;
                if (e.size() % @sizeOf(Name) != 0 or e.size() / @sizeOf(Name) > cap.secret_names) return error.Corrupt;
                const bytes = std.mem.sliceAsBytes(s.secrets[0..]);
                var buf: [cap.secret_names * @sizeOf(Name) + tag_len]u8 = undefined;
                const plain = try s.get(s.secret_names, store_owner, &buf);
                @memcpy(bytes[0..plain.len], plain);
                s.n_secrets = plain.len / @sizeOf(Name);
            }
        }

        // --- Generations ----------------------------------------------------

        /// Try `gen` on the next boot (it must be stored). Commits.
        pub fn stage(s: *Self, gen: Hash) Error!void {
            if (!s.has(gen)) return error.NotFound;
            s.sup.boot.pending = gen;
            s.sup.boot.tries = 0;
            try s.commit();
        }

        /// Aurora: which generation to boot now, recording the attempt.
        /// Null when the store holds none.
        pub fn chooseBoot(s: *Self) Error!?Hash {
            const b = &s.sup.boot;
            if (!std.mem.eql(u8, &b.pending, &zero)) {
                if (b.tries < b.max_tries) {
                    b.tries += 1;
                    try s.commit();
                    return b.pending;
                }
                // It never came up: forget it and go back.
                b.pending = zero;
                b.tries = 0;
                try s.commit();
            }
            return if (std.mem.eql(u8, &b.current, &zero)) null else b.current;
        }

        /// The running system came up: if it is a pending generation on
        /// trial, it becomes current. Commits. Returns whether it did.
        pub fn confirm(s: *Self) Error!bool {
            const b = &s.sup.boot;
            if (std.mem.eql(u8, &b.pending, &zero) or b.tries == 0) return false;
            if (!std.mem.eql(u8, &b.current, &b.pending)) b.previous = b.current;
            b.current = b.pending;
            b.pending = zero;
            b.tries = 0;
            try s.commit();
            return true;
        }

        /// Go back to the generation that was current before the last
        /// switch, through the same trial as any switch. Commits.
        pub fn rollback(s: *Self) Error!Hash {
            const prev = s.sup.boot.previous;
            if (std.mem.eql(u8, &prev, &zero)) return error.NotFound;
            try s.stage(prev);
            return prev;
        }

        /// Make `gen` current without a trial (a fresh disk's first
        /// generation, or a developer's build); the one it replaces becomes
        /// the rollback target. Commits.
        pub fn install(s: *Self, gen: Hash) Error!void {
            if (!s.has(gen)) return error.NotFound;
            const b = &s.sup.boot;
            if (!std.mem.eql(u8, &b.current, &gen)) {
                if (!std.mem.eql(u8, &b.current, &zero)) b.previous = b.current;
                b.current = gen;
            }
            try s.commit();
        }
    };
}

// ---------------------------------------------------------------------------
// Tests, including the crash simulator: a disk with a volatile write cache
// that loses, keeps or tears any unflushed write when the power goes.

const testing = std.testing;

pub const SimDisk = struct {
    media: []Block,
    /// Writes since the last flush, in order (block, data).
    cache: std.ArrayList(struct { block: u64, data: Block }) = .empty,
    gpa: std.mem.Allocator,
    /// Count device operations; `fail_at` makes that one (and all after)
    /// fail, as if the power went then.
    ops: u64 = 0,
    fail_at: ?u64 = null,

    pub fn init(gpa: std.mem.Allocator, blocks: usize) !SimDisk {
        const m = try gpa.alloc(Block, blocks);
        for (m) |*b| b.* = @splat(0xEE);
        return .{ .media = m, .gpa = gpa };
    }

    pub fn deinit(d: *SimDisk) void {
        d.gpa.free(d.media);
        d.cache.deinit(d.gpa);
    }

    fn step(d: *SimDisk) !void {
        if (d.fail_at) |f| if (d.ops >= f) return error.PowerLost;
        d.ops += 1;
    }

    pub fn read(d: *SimDisk, block: u64, buf: *Block) !void {
        try d.step();
        buf.* = d.media[block];
        // A read sees the newest cached write.
        for (d.cache.items) |w| if (w.block == block) {
            buf.* = w.data;
        };
    }

    pub fn write(d: *SimDisk, block: u64, buf: *const Block) !void {
        try d.step();
        if (block >= d.media.len) return error.OutOfRange;
        try d.cache.append(d.gpa, .{ .block = block, .data = buf.* });
    }

    pub fn flush(d: *SimDisk) !void {
        try d.step();
        for (d.cache.items) |w| d.media[w.block] = w.data;
        d.cache.clearRetainingCapacity();
    }

    /// The power goes: each unflushed write independently survives, is
    /// lost, or (one of them) is torn at a 512-byte sector boundary.
    pub fn crash(d: *SimDisk, rng: std.Random) void {
        for (d.cache.items) |w| switch (rng.uintLessThan(u8, 4)) {
            0 => {},
            1, 2 => d.media[w.block] = w.data,
            else => {
                const sectors = rng.uintLessThan(usize, 8);
                @memcpy(d.media[w.block][0 .. sectors * 512], w.data[0 .. sectors * 512]);
            },
        };
        d.cache.clearRetainingCapacity();
        d.fail_at = null;
    }
};

const TestStore = Store(SimDisk, .{ .objects = 64, .names = 16, .secret_names = 8 });
var scratch_store: TestStore = undefined;
const cheap: KdfCost = .{ .t = 1, .m_kib = 64 };

fn testEntropy(seed: u8) [64]u8 {
    var e: [64]u8 = undefined;
    for (&e, 0..) |*b, i| b.* = @truncate(i *% 31 +% seed);
    return e;
}

test "objects, names, sealing, dedupe, remount" {
    var disk = try SimDisk.init(testing.allocator, 64);
    defer disk.deinit();
    try TestStore.format(&scratch_store, &disk, 64, cheap);
    var s: TestStore = undefined;
    try s.mount(&disk);
    try testing.expect(s.locked() and !s.passphraseSet());

    const a = try s.put("hello tablecloth");
    try testing.expectEqualSlices(u8, &a, &(try s.put("hello tablecloth")));
    var big: [10_000]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i *% 7);
    const b = try s.put(&big);
    try s.bind("greeting@1", a, false, false);
    try testing.expectError(error.NameTaken, s.bind("greeting@1", b, false, false));
    try testing.expectError(error.Locked, s.seal("kumara", "secret", &.{}));

    try s.create(testing.allocator, "correct horse", testEntropy(1));
    var scratch: [64]u8 = undefined;
    const sec = try s.seal("kumara", "the secret", &scratch);
    // Same bytes, other owner: another object.
    const other = try s.seal("ledger", "the secret", &scratch);
    try testing.expect(!std.mem.eql(u8, &sec, &other));
    try s.bind("kumara/secret", sec, true, false);
    try s.bind("ledger/head", a, false, true);
    try s.bind("ledger/head", b, false, true);
    try s.commit();

    var t: TestStore = undefined;
    try t.mount(&disk);
    var buf: [10_100]u8 = undefined;
    try testing.expectEqualStrings("hello tablecloth", try t.get(a, "anyone", &buf));
    try testing.expectEqualSlices(u8, &big, try t.get(b, "anyone", &buf));
    try testing.expectEqualSlices(u8, &b, &(try t.lookup("ledger/head", false)).?);
    try testing.expectError(error.Locked, t.get(sec, "kumara", &buf));
    try testing.expectError(error.Locked, t.lookup("kumara/secret", true));
    try testing.expectError(error.BadPassphrase, t.unlock(testing.allocator, "wrong"));
    try t.unlock(testing.allocator, "correct horse");
    try testing.expectEqualSlices(u8, &sec, &(try t.lookup("kumara/secret", true)).?);
    try testing.expectEqualStrings("the secret", try t.get(sec, "kumara", &buf));
    try testing.expectError(error.NotFound, t.get(sec, "ledger", &buf));

    // A new passphrase opens the same secrets; the old one no longer does.
    try testing.expectError(error.BadPassphrase, t.rekey(testing.allocator, "wrong", "new horse", testEntropy(5)[0..32].*));
    try t.rekey(testing.allocator, "correct horse", "new horse", testEntropy(5)[0..32].*);
    var u: TestStore = undefined;
    try u.mount(&disk);
    try testing.expectError(error.BadPassphrase, u.unlock(testing.allocator, "correct horse"));
    try u.unlock(testing.allocator, "new horse");
    try testing.expectEqualStrings("the secret", try u.get(sec, "kumara", &buf));
    // Sealed names are not readable from the public table.
    try testing.expect(try t.lookup("kumara/secret", false) == null);

    // A flipped byte in an object is caught.
    const e = t.entry(a).?;
    disk.media[first_log_block + e.offset / block_size % t.sup.logBlocks()][e.offset % block_size] ^= 1;
    try testing.expectError(error.Corrupt, t.get(a, "anyone", &buf));
}

test "generations: stage, trial boots, confirm, give up" {
    var disk = try SimDisk.init(testing.allocator, 32);
    defer disk.deinit();
    try TestStore.format(&scratch_store, &disk, 32, cheap);
    var s: TestStore = undefined;
    try s.mount(&disk);
    try testing.expect(try s.chooseBoot() == null);
    const g1 = try s.put("generation one");
    const g2 = try s.put("generation two");
    try s.commit();
    try s.install(g1);
    try testing.expectEqualSlices(u8, &g1, &(try s.chooseBoot()).?);
    try testing.expect(!try s.confirm()); // nothing on trial

    try s.stage(g2);
    try testing.expect(!try s.confirm()); // staged, not yet booted
    try testing.expectEqualSlices(u8, &g2, &(try s.chooseBoot()).?);
    try testing.expect(try s.confirm());
    try testing.expectEqualSlices(u8, &g2, &s.sup.boot.current);
    try testing.expectEqualSlices(u8, &g1, &s.sup.boot.previous);

    // A generation that never comes up is tried max_tries times, then dropped.
    try s.stage(g1);
    for (0..3) |_| {
        var r: TestStore = undefined;
        try r.mount(&disk);
        try testing.expectEqualSlices(u8, &g1, &(try r.chooseBoot()).?);
    }
    var r: TestStore = undefined;
    try r.mount(&disk);
    try testing.expectEqualSlices(u8, &g2, &(try r.chooseBoot()).?);
    try testing.expect(std.mem.eql(u8, &r.sup.boot.pending, &zero));
}

/// The state a test can compare before and after a crash.
const Snapshot = struct {
    seq: u64,
    lock_set: bool,
    salt: [16]u8,
    objects: usize,
    names: usize,
    current: Hash,
    pending: Hash,
    tries: u32,
    secrets: usize,
};

fn snap(s: *const TestStore) Snapshot {
    return .{ .seq = s.sup.seq, .lock_set = s.passphraseSet(), .salt = s.sup.lock.salt, .objects = s.n_objects, .names = s.n_names, .current = s.sup.boot.current, .pending = s.sup.boot.pending, .tries = s.sup.boot.tries, .secrets = s.n_secrets };
}

fn sameState(a: Snapshot, b: Snapshot) bool {
    return a.lock_set == b.lock_set and std.mem.eql(u8, &a.salt, &b.salt) and a.objects == b.objects and a.names == b.names and std.mem.eql(u8, &a.current, &b.current) and
        std.mem.eql(u8, &a.pending, &b.pending) and a.tries == b.tries and a.secrets == b.secrets;
}

/// One step of the scenario, applied to a mounted store. Each step is one
/// atomic operation (one commit), so after a crash the store must be exactly
/// as it was before the step or after it.
fn scenarioStep(s: *TestStore, i: usize) !void {
    var scratch: [600]u8 = undefined;
    switch (i) {
        0 => try s.create(testing.allocator, "pass", testEntropy(9)),
        1 => {
            var data: [5000]u8 = undefined;
            for (&data, 0..) |*b, j| b.* = @truncate(j);
            try s.bind("system@1", try s.put(&data), false, false);
            try s.commit();
        },
        2 => try s.install((try s.lookup("system@1", false)).?),
        3 => {
            try s.bind("system@2", try s.put("generation two, a little different"), false, false);
            try s.bind("kumara/secret", try s.seal("kumara", "kumara secret key material", &scratch), true, false);
            try s.commit();
        },
        4 => try s.stage((try s.lookup("system@2", false)).?),
        5 => _ = try s.chooseBoot(),
        6 => _ = try s.confirm(),
        7 => try s.stage((try s.lookup("system@1", false)).?), // rollback
        8 => _ = try s.chooseBoot(),
        9 => _ = try s.confirm(),
        10 => try s.forget((try s.lookup("system@2", false)).?),
        11 => _ = try s.reclaim(1000),
        // Fill and clear the log until it has wrapped around the disk.
        12, 14, 16, 18 => {
            var data: [30_000]u8 = undefined;
            for (&data, 0..) |*b, j| b.* = @truncate(j *% i);
            try s.bind("scratch", try s.put(&data), false, true);
            try s.commit();
        },
        13, 15, 17, 19 => {
            try s.retire("scratch", false);
            _ = try s.reclaim(1000);
        },
        // A new wrapping (the same passphrase, so every recovery unlocks).
        20 => try s.rekey(testing.allocator, "pass", "pass", testEntropy(77)[0..32].*),
        else => unreachable,
    }
}
const scenario_steps = 21;

test "a power cut at any device operation leaves the old state or the new one" {
    var prng = std.Random.DefaultPrng.init(0x7ab1ec10);
    const rng = prng.random();
    var cuts: usize = 0;
    for (0..scenario_steps) |step| {
        // Measure how many device operations this step takes.
        var probe = try SimDisk.init(testing.allocator, 48);
        defer probe.deinit();
        try TestStore.format(&scratch_store, &probe, 48, cheap);
        for (0..step) |i| {
            var s: TestStore = undefined;
            try s.mount(&probe);
            if (i > 0) try s.unlock(testing.allocator, "pass");
            try scenarioStep(&s, i);
        }
        var before_store: TestStore = undefined;
        try before_store.mount(&probe);
        if (step > 0) try before_store.unlock(testing.allocator, "pass");
        const before = snap(&before_store);
        const ops0 = probe.ops;
        try scenarioStep(&before_store, step);
        const after = snap(&before_store);
        const total = probe.ops - ops0;

        // Now cut the power at every operation of that step, several ways.
        for (0..total + 1) |cut| for (0..4) |_| {
            var disk = try SimDisk.init(testing.allocator, 48);
            defer disk.deinit();
            try TestStore.format(&scratch_store, &disk, 48, cheap);
            for (0..step) |i| {
                var s: TestStore = undefined;
                try s.mount(&disk);
                if (i > 0) try s.unlock(testing.allocator, "pass");
                try scenarioStep(&s, i);
            }
            var s: TestStore = undefined;
            try s.mount(&disk);
            if (step > 0) try s.unlock(testing.allocator, "pass");
            disk.fail_at = disk.ops + cut;
            scenarioStep(&s, step) catch {};
            disk.crash(rng);
            cuts += 1;

            var r: TestStore = undefined;
            r.mount(&disk) catch |e| {
                std.debug.print("step {d} cut {d}: mount failed: {s}\n", .{ step, cut, @errorName(e) });
                return e;
            };
            // Everything the table names must be readable and intact.
            if (r.passphraseSet()) try r.unlock(testing.allocator, "pass");
            const got = snap(&r);
            if (!sameState(got, before) and !sameState(got, after)) {
                std.debug.print("step {d} cut {d}: state is neither before nor after\n  got {any}\n  before {any}\n  after {any}\n", .{ step, cut, got, before, after });
                return error.TestUnexpectedResult;
            }
            var buf: [32 * 1024]u8 = undefined;
            for (r.objects[0..r.n_objects]) |e| {
                // Sealed objects here belong to kumara or the store itself.
                _ = r.get(e.hash, "kumara", &buf) catch |err| switch (err) {
                    error.NotFound => try r.get(e.hash, store_owner, &buf),
                    else => return err,
                };
            }
            // And the store keeps working after recovery.
            _ = try r.put("after the crash");
            try r.commit();
        };
    }
    try testing.expect(cuts > 100);

    // The scenario's last steps take the log round the disk.
    var disk = try SimDisk.init(testing.allocator, 48);
    defer disk.deinit();
    try TestStore.format(&scratch_store, &disk, 48, cheap);
    for (0..scenario_steps) |i| {
        var s: TestStore = undefined;
        try s.mount(&disk);
        if (i > 0) try s.unlock(testing.allocator, "pass");
        try scenarioStep(&s, i);
    }
    var s: TestStore = undefined;
    try s.mount(&disk);
    try testing.expect(s.sup.tail > s.sup.logBlocks());
}

test "reclaiming: names, the boot state, generations and links keep objects; the log wraps" {
    var disk = try SimDisk.init(testing.allocator, 40);
    defer disk.deinit();
    try TestStore.format(&scratch_store, &disk, 40, cheap);
    const s = &scratch_store;
    try s.create(testing.allocator, "pass", testEntropy(3));

    // A generation: a descriptor naming two chunks, kept by the boot state.
    const c1 = try s.put("chunk one");
    const c2 = try s.put("chunk two");
    const G = generation;
    var desc: [@sizeOf(G.Header) + @sizeOf(G.Segment) + 64]u8 = undefined;
    const hd: G.Header = .{ .entry = 0x8020_0000, .segments = 1, .chunks = 2, .label = @splat(0), .closure = zero };
    const seg: G.Segment = .{ .paddr = 0x8020_0000, .memsz = 18, .filesz = 18, .first_chunk = 0, .chunks = 2 };
    @memcpy(desc[0..@sizeOf(G.Header)], std.mem.asBytes(&hd));
    @memcpy(desc[@sizeOf(G.Header)..][0..@sizeOf(G.Segment)], std.mem.asBytes(&seg));
    @memcpy(desc[desc.len - 64 ..][0..32], &c1);
    @memcpy(desc[desc.len - 32 ..], &c2);
    const g = try s.put(&desc);
    try s.commit();
    try s.install(g);

    // A chain: only its newest link is named; the rest are kept by links.
    var scratch: [64]u8 = undefined;
    var prev = zero;
    for (0..3) |i| {
        const entry_text = [_]u8{ 'e', '0' + @as(u8, @intCast(i)) };
        prev = try s.sealLinked("ledger", &entry_text, &scratch, prev);
    }
    try s.bind("ledger/head", prev, true, true);
    const named = try s.put("kept by a name");
    try s.bind("kept@1", named, false, false);
    const loose = try s.put("kept by nothing");
    try s.commit();

    var r = try s.reclaim(1000);
    try testing.expectEqual(@as(u32, 1), r.dropped);
    try testing.expect(!s.has(loose) and s.has(named) and s.has(c1) and s.has(c2) and s.has(g));
    try testing.expectEqual(@as(usize, 8), s.n_objects); // with the secret names
    try testing.expectError(error.InUse, s.forget(g));

    // Fill the disk, clear it, and go round it twice.
    var data: [20_000]u8 = undefined;
    var stored: usize = 0;
    for (0..12) |round| {
        for (&data, 0..) |*b, j| b.* = @truncate(j *% (round + 3));
        const h = s.put(&data) catch |e| {
            try testing.expectEqual(error.NoSpace, e);
            r = try s.reclaim(1000);
            try testing.expect(r.free > 6);
            continue;
        };
        try s.bind("scratch", h, false, true);
        try s.commit();
        stored += 1;
        if (round % 3 == 2) {
            try s.retire("scratch", false);
            _ = try s.reclaim(1000);
        }
    }
    try testing.expect(stored >= 8 and s.sup.tail > 2 * s.sup.logBlocks());

    // A retired Mantra name means nothing, and cannot come back.
    try s.retire("kept@1", false);
    try testing.expect(try s.lookup("kept@1", false) == null);
    try testing.expectError(error.NameTaken, s.bind("kept@1", named, false, false));
    _ = try s.reclaim(1000);
    try testing.expect(!s.has(named));

    // After all that, a fresh mount reads everything still live.
    var t: TestStore = undefined;
    try t.mount(&disk);
    try t.unlock(testing.allocator, "pass");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("chunk two", try t.get(c2, "anyone", &buf));
    var h = (try t.lookup("ledger/head", true)).?;
    var n: usize = 0;
    while (!std.mem.eql(u8, &h, &zero)) : (n += 1) {
        _ = try t.get(h, "ledger", &buf);
        h = t.entry(h).?.link;
    }
    try testing.expectEqual(@as(usize, 3), n);
}
