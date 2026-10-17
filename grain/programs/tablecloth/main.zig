//! tablecloth: the content store, as a domain. It drives its virtio-blk disk
//! itself (no driver between), mounts the store (formatting a blank disk),
//! asks the owner for the passphrase on the console, and then serves
//! tablecloth.v1.
//!
//! Every client works in its own space: its names are kept under its own
//! name, and what it seals opens only for it (the owner is bound into the
//! object's name, see lib/tablecloth.zig). Steward calls unbadged.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");
const tc = g.tablecloth;
const P = proto.tablecloth;
const idl = g.idl;
const D = g.domain;

pub const panic = g.panic;
pub const std_options = g.std_options;
comptime {
    g.exportStart();
}

const Disk = g.virtio_blk.Blk;
const Store = tc.Store(Disk, .{ .objects = 4096, .names = 256, .secret_names = 256 });

var disk: Disk = undefined;
var cloth: Store = undefined;

/// The last object read, whole, so `read` in 480-byte steps reads the disk once.
var obj_buf: [tc.max_object + tc.tag_len]u8 = undefined;
var cached: struct { hash: tc.Hash = tc.zero, owner: [tc.owner_len]u8 = @splat(0), data: []const u8 = &.{} } = .{};

/// Larger objects are staged here, one buffer per client at a time.
const Staging = struct { badge: usize = std.math.maxInt(usize), len: u32 = 0, data: [tc.max_object]u8 = undefined };
var staging: [4]Staging = @splat(.{});
var staging_next: usize = 0;

fn stagingFor(badge: usize) *Staging {
    for (&staging) |*s| if (s.badge == badge) return s;
    const s = &staging[staging_next];
    staging_next = (staging_next + 1) % staging.len;
    s.* = .{ .badge = badge };
    return s;
}

/// Who is calling: a client domain, the agent, or Steward (unbadged).
fn ownerOf(c: idl.Caller) error{Unavailable}![]const u8 {
    if (c.badge == 0) return "steward";
    return g.env().clientName(c.badge) orelse error.Unavailable;
}

fn hashOf(b: P.Hash) error{InvalidArgs}!tc.Hash {
    if (b.len != 32) return error.InvalidArgs;
    return b.data;
}

fn fullName(buf: *[tc.name_len]u8, owner: []const u8, name: P.NameText) error{InvalidArgs}![]const u8 {
    const n = name.slice();
    if (owner.len + 1 + n.len >= tc.name_len) return error.InvalidArgs;
    @memcpy(buf[0..owner.len], owner);
    buf[owner.len] = '/';
    @memcpy(buf[owner.len + 1 ..][0..n.len], n);
    return buf[0 .. owner.len + 1 + n.len];
}

fn storeError(e: tc.Error) anyerror {
    return switch (e) {
        error.NotFound => error.NotFound,
        error.Locked, error.Io => error.Unavailable,
        error.BadName, error.TooLarge, error.NameTaken => error.InvalidArgs,
        else => error.Failed,
    };
}

const Server = struct {
    pub fn info(_: *Server, _: P.info.Params, _: idl.Caller) !P.info.Results {
        const b = cloth.sup.boot;
        return .{
            .blocks = cloth.sup.blocks,
            .used = cloth.sup.log_end,
            .objects = @intCast(cloth.n_objects),
            .seq = cloth.sup.seq,
            .locked = cloth.locked(),
            .current = P.Hash.from(&b.current),
            .pending = P.Hash.from(&b.pending),
            .previous = P.Hash.from(&b.previous),
            .tries = b.tries,
        };
    }

    pub fn put(_: *Server, p: P.put.Params, c: idl.Caller) !P.put.Results {
        _ = try ownerOf(c);
        const h = cloth.put(p.data.slice()) catch |e| return storeError(e);
        return .{ .hash = P.Hash.from(&h) };
    }

    pub fn write(_: *Server, p: P.write.Params, c: idl.Caller) !P.write.Results {
        _ = try ownerOf(c);
        const d = p.data.slice();
        if (@as(usize, p.offset) + d.len > tc.max_object) return error.InvalidArgs;
        const s = stagingFor(c.badge);
        @memcpy(s.data[p.offset..][0..d.len], d);
        s.len = @max(s.len, p.offset + @as(u32, @intCast(d.len)));
        return .{};
    }

    pub fn store(_: *Server, p: P.store.Params, c: idl.Caller) !P.store.Results {
        const owner = try ownerOf(c);
        const s = stagingFor(c.badge);
        if (p.len > s.len) return error.InvalidArgs;
        cached = .{};
        const h = (if (p.sealed) cloth.seal(owner, s.data[0..p.len], &obj_buf) else cloth.put(s.data[0..p.len])) catch |e| return storeError(e);
        s.len = 0;
        return .{ .hash = P.Hash.from(&h) };
    }

    pub fn read(_: *Server, p: P.read.Params, c: idl.Caller) !P.read.Results {
        const owner = try ownerOf(c);
        const h = try hashOf(p.hash);
        var pad: [tc.owner_len]u8 = @splat(0);
        @memcpy(pad[0..owner.len], owner);
        if (!std.mem.eql(u8, &cached.hash, &h) or !std.mem.eql(u8, &cached.owner, &pad)) {
            cached = .{};
            const data = cloth.get(h, owner, &obj_buf) catch |e| return storeError(e);
            cached = .{ .hash = h, .owner = pad, .data = data };
        }
        const off = @min(p.offset, cached.data.len);
        const n = @min(cached.data.len - off, P.chunk);
        return .{ .size = @intCast(cached.data.len), .data = idl.Bytes(P.chunk).from(cached.data[off..][0..n]) };
    }

    pub fn has(_: *Server, p: P.has.Params, c: idl.Caller) !P.has.Results {
        _ = try ownerOf(c);
        const e = cloth.entry(try hashOf(p.hash)) orelse return .{ .found = false, .size = 0, .sealed = false };
        return .{ .found = true, .size = e.size(), .sealed = e.sealed() };
    }

    pub fn bind(_: *Server, p: P.bind.Params, c: idl.Caller) !P.bind.Results {
        var buf: [tc.name_len]u8 = undefined;
        const full = try fullName(&buf, try ownerOf(c), p.name);
        cloth.bind(full, try hashOf(p.hash), p.secret, p.tip) catch |e| return storeError(e);
        return .{};
    }

    pub fn lookup(_: *Server, p: P.lookup.Params, c: idl.Caller) !P.lookup.Results {
        var buf: [tc.name_len]u8 = undefined;
        const full = try fullName(&buf, try ownerOf(c), p.name);
        const h = (cloth.lookup(full, p.secret) catch |e| return storeError(e)) orelse return .{ .hash = .{}, .found = false };
        return .{ .hash = P.Hash.from(&h), .found = true };
    }

    pub fn commit(_: *Server, _: P.commit.Params, c: idl.Caller) !P.commit.Results {
        _ = try ownerOf(c);
        cloth.commit() catch |e| return storeError(e);
        g.log("tablecloth_commit", .{ .seq = cloth.sup.seq, .objects = cloth.n_objects, .used_blocks = cloth.sup.log_end });
        return .{ .seq = cloth.sup.seq };
    }

    pub fn switch_to(_: *Server, p: P.switch_to.Params, c: idl.Caller) !P.switch_to.Results {
        const owner = try ownerOf(c);
        if (!std.mem.eql(u8, owner, "steward") and !std.mem.eql(u8, owner, "agent")) return error.Unavailable;
        const h = try hashOf(p.generation);
        nameGeneration(h) catch |e| return storeError(e);
        cloth.stage(h) catch |e| return storeError(e);
        g.log("generation_staged", .{ .generation = g.klog.hex(std.mem.readInt(u64, h[0..8], .big)), .by = owner });
        return .{};
    }

    pub fn rollback(_: *Server, _: P.rollback.Params, c: idl.Caller) !P.rollback.Results {
        const owner = try ownerOf(c);
        if (!std.mem.eql(u8, owner, "steward") and !std.mem.eql(u8, owner, "agent")) return error.Unavailable;
        const h = cloth.rollback() catch |e| return storeError(e);
        g.log("generation_staged", .{ .generation = g.klog.hex(std.mem.readInt(u64, h[0..8], .big)), .by = owner, .rollback = true });
        return .{ .generation = P.Hash.from(&h) };
    }
};

/// A generation gets a Mantra name the first time it is staged: `system@N`,
/// numbered in the order generations arrive. Only a valid descriptor whose
/// every chunk is stored can be staged (Aurora must be able to load it).
fn nameGeneration(h: tc.Hash) !void {
    const d = try cloth.get(h, "", &obj_buf);
    cached = .{};
    const v = g.generation.View.parse(d) catch return error.BadName;
    for (v.hashes) |c| if (!cloth.has(c)) return error.NotFound;
    var n: usize = 1;
    for (cloth.publicNames()) |*nm| {
        if (std.mem.eql(u8, &nm.hash, &h)) return;
        if (std.mem.startsWith(u8, nm.text(), "system@")) n += 1;
    }
    var buf: [24]u8 = undefined;
    try cloth.bind(std.fmt.bufPrint(&buf, "system@{d}", .{n}) catch unreachable, h, false, false);
}

// ---------------------------------------------------------------------------
// Unlocking: the passphrase comes from the owner, on the console.

fn say(console: g.CPtr, text: []const u8) void {
    proto.console.print(console, text) catch {};
}

/// The owner's next typed line (input.v1, polled: the driver cannot hold a
/// reply open, so a line is either waiting or not).
fn readLine(input: g.CPtr, out: *[128]u8) []u8 {
    while (true) {
        if (idl.call(proto.input.read_line, input, .{})) |r| {
            if (r.ready) {
                const t = r.text.slice();
                @memcpy(out[0..t.len], t);
                return out[0..t.len];
            }
        } else |_| {}
        g.yield();
    }
}

fn unlock(space: *g.Space, console: g.CPtr, input: g.CPtr, entropy: g.CPtr) !void {
    const l = cloth.sup.lock;
    const heap = try space.mapHeap(D.Layout.heap + 0x10_0000, l.m_kib / 4 + 64);
    var fba: std.heap.FixedBufferAllocator = .init(heap);
    var pass: [128]u8 = undefined;
    defer std.crypto.secureZero(u8, &pass);
    if (!cloth.passphraseSet()) {
        var again: [128]u8 = undefined;
        defer std.crypto.secureZero(u8, &again);
        while (true) {
            say(console, "tablecloth: this disk is new. Choose a passphrase:\n");
            const a = readLine(input, &pass);
            say(console, "tablecloth: once more:\n");
            const b = readLine(input, &again);
            if (a.len > 0 and std.mem.eql(u8, a, b)) {
                var seed: [64]u8 = undefined;
                defer std.crypto.secureZero(u8, &seed);
                for (0..2) |i| {
                    const r = try idl.call(proto.entropy.get, entropy, .{});
                    @memcpy(seed[i * 32 ..][0..32], r.bytes.slice()[0..32]);
                }
                fba.reset();
                try cloth.create(fba.allocator(), a, seed);
                g.log("tablecloth_unlocked", .{ .created = true, .tries = 1 });
                return;
            }
            say(console, "tablecloth: those differ (or are empty); again.\n");
        }
    }
    var tries: u32 = 0;
    while (true) {
        tries += 1;
        say(console, "tablecloth: passphrase:\n");
        const p = readLine(input, &pass);
        fba.reset();
        if (cloth.unlock(fba.allocator(), p)) |_| {
            g.log("tablecloth_unlocked", .{ .created = false, .tries = tries });
            return;
        } else |e| switch (e) {
            error.BadPassphrase => {
                g.log("tablecloth_unlock_failed", .{ .tries = tries });
                say(console, "tablecloth: that is not it.\n");
            },
            else => return e,
        }
    }
}

pub fn main() !u16 {
    const dev = g.device("disk") orelse return error.NoDevice;
    var space: g.Space = .{ .untyped = D.Slot.memory, .vspace = D.Slot.vspace, .next_slot = D.Slot.first_free };
    const q = try g.virtio.Dma.alloc(&space, D.Layout.heap);
    const req = try g.virtio.Dma.alloc(&space, D.Layout.heap + 0x1000);
    const data = try g.virtio.Dma.alloc(&space, D.Layout.heap + 0x2000);
    const signal = try space.retype(.signal, 0);
    if (!g.invoke(dev.irq_slot, g.abi.IrqMethod.set_signal, .{signal}).ok()) return error.IrqSetup;
    disk = try Disk.init(dev.mmio, .{ .va = q.va, .pa = q.pa }, .{ .va = req.va, .pa = req.pa }, .{ .va = data.va, .pa = data.pa }, signal, dev.irq_slot);

    cloth.mount(&disk) catch |e| switch (e) {
        error.NotFormatted => {
            // Unlocking may take half this domain's memory.
            const m_kib: u32 = @intCast(@min(16 * 1024, g.env().memory_bytes / 2 / 1024));
            try cloth.format(&disk, disk.blocks, .{ .t = 2, .m_kib = m_kib });
            g.log("tablecloth_formatted", .{ .blocks = disk.blocks });
        },
        else => return e,
    };
    const cur = cloth.sup.boot.current;
    g.log("tablecloth_mounted", .{
        .blocks = cloth.sup.blocks,
        .used_blocks = cloth.sup.log_end,
        .seq = cloth.sup.seq,
        .objects = cloth.n_objects,
        .current = g.klog.hex(std.mem.readInt(u64, cur[0..8], .big)),
        .tries = cloth.sup.boot.tries,
    });
    try unlock(&space, g.use("console") orelse return error.NoService, g.use("input") orelse return error.NoService, g.use("entropy") orelse return error.NoService);

    // Ask Steward whether the whole boot came up; if it did, a generation
    // on trial becomes current.
    const ready: u32 = @backingInt(D.Lifecycle.ready);
    const r = g.call(D.Slot.steward, .{ .label = ready, .length = 1 }, .{0});
    if (r.ok() and r.w[0] == 1) {
        const promoted = try cloth.confirm();
        const now = cloth.sup.boot.current;
        g.log("generation_confirmed", .{ .promoted = promoted, .current = g.klog.hex(std.mem.readInt(u64, now[0..8], .big)) });
    } else g.log("generation_not_confirmed", .{ .reason = "boot_unhealthy" });
    _ = g.call(D.Slot.steward, .{ .label = ready, .length = 1 }, .{1});

    var s: Server = .{};
    idl.serve(P, g.provided("tablecloth") orelse return error.NoService, &s);
}
