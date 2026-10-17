//! Fuzz targets for user space: every parser that reads what someone else
//! controls (a device, the network, a disk, a client, a manifest). Each
//! checks a property beyond "does not crash" where there is one: forged
//! handshakes are not accepted, objects read from a damaged disk still
//! match their hash, decoded messages encode back to themselves. See
//! kernel.zig for how to run them.
const std = @import("std");
const fuzz = @import("source.zig");
const Source = fuzz.Source;
const g = @import("grain");
const image = @import("image");
const brix = @import("brix");
const schema = @import("schema");
const proto = @import("proto");

// ---------------------------------------------------------------------------
// What devices, the network and other people send

/// Frames off the wire.
fn netFrames(src: *Source) !void {
    var buf: [1600]u8 = undefined;
    const mac_a: g.net.Mac = .{ 2, 0, 0, 0, 0, 1 };
    const mac_b: g.net.Mac = .{ 2, 0, 0, 0, 0, 2 };
    var payload: [64]u8 = undefined;
    const frame = switch (src.below(3)) {
        0 => g.net.udp(&buf, mac_a, mac_b, g.net.linkLocal(mac_a), g.net.linkLocal(mac_b), 7000, 7001, src.slice(&payload)),
        1 => g.net.arp(&buf, .request, mac_a, g.net.linkLocal(mac_a), mac_b, g.net.linkLocal(mac_b)),
        else => src.slice(&buf),
    };
    _ = g.net.parse(src.mutate(frame));
}

/// Noise XX: every handshake message and transport message damaged in
/// transit. A damaged message must never be accepted as authentic.
fn noiseMessages(src: *Source) !void {
    const N = g.noise;
    const si: N.LocalStatic = .{ .pair = .generateDeterministic(@splat(1)) };
    const sr: N.LocalStatic = .{ .pair = .generateDeterministic(@splat(2)) };
    var i = N.Handshake.init(true, si.pair.public_key, @splat(3), "grain comlink v1");
    var r = N.Handshake.init(false, sr.pair.public_key, @splat(4), "grain comlink v1");
    var buf: [512]u8 = undefined;
    var copy: [512]u8 = undefined;
    var got: [512]u8 = undefined;
    const which = src.below(4); // the message to damage
    const Step = struct {
        fn pass(s: *Source, damage: bool, msg: []const u8, into: *[512]u8) []u8 {
            @memcpy(into[0..msg.len], msg);
            return if (damage) s.mutate(into[0..msg.len]) else into[0..msg.len];
        }
    };
    const m1 = try i.write(&buf, "hello", si);
    const d1 = Step.pass(src, which == 0, m1, &copy);
    _ = r.read(d1, &got) catch return;
    // A damaged first message is unauthenticated (it carries only an
    // ephemeral key); what matters is that the rest cannot then succeed.
    const m2 = try r.write(&buf, "responder", sr);
    const d2 = Step.pass(src, which == 1, m2, &copy);
    const p2 = i.read(d2, &got) catch return;
    if (which == 1 and !std.mem.eql(u8, d2, m2)) return error.ForgedMessageAccepted;
    try std.testing.expectEqualStrings("responder", p2);
    const m3 = try i.write(&buf, "initiator", si);
    const d3 = Step.pass(src, which == 2, m3, &copy);
    _ = r.read(d3, &got) catch return;
    if (which == 2 and !std.mem.eql(u8, d3, m3)) return error.ForgedMessageAccepted;
    if (which == 0 and !std.mem.eql(u8, d1, m1)) {
        // A changed ephemeral key cannot end in a shared session.
        var a = i.split();
        var b = r.split();
        const t = a.encrypt(&buf, "x");
        if (b.decrypt(&got, t)) |_| return error.ForgedMessageAccepted else |_| return;
    }
    var a = i.split();
    var b = r.split();
    const t = a.encrypt(&buf, "transport");
    const dt = Step.pass(src, which == 3, t, &copy);
    const plain = b.decrypt(&got, dt) catch return;
    if (which == 3 and !std.mem.eql(u8, dt, t)) return error.ForgedMessageAccepted;
    try std.testing.expectEqualStrings("transport", plain);
}

/// A USB device's configuration descriptor.
fn usbConfiguration(src: *Source) !void {
    var kbd = [_]u8{ 9, 2, 34, 0, 1, 1, 0, 0xa0, 50, 9, 4, 0, 0, 1, 3, 1, 1, 0, 9, 0x21, 0x11, 1, 0, 1, 0x22, 63, 0, 7, 5, 0x81, 3, 8, 0, 7 };
    var any: [256]u8 = undefined;
    const cfg = if (src.chance(80)) src.mutate(&kbd) else src.slice(&any);
    if (g.xhci.parseConfiguration(cfg)) |h| {
        try std.testing.expect(h.endpoint & 0x80 != 0 and h.max_packet != 0 and h.max_packet <= 0x7ff);
    }
}

/// A PCI function's BAR sizes, as the device reports them (any mask).
fn pciBars(src: *Source) !void {
    var bars: [6]g.pci.Bar = undefined;
    var ptrs: [6]*g.pci.Bar = undefined;
    const n = src.below(7);
    for (bars[0..n], 0..) |*b, k| {
        // Sizing writes all ones and reads the mask back: a device can
        // answer anything.
        const mask = src.int(u64) & ~@as(u64, 0xf);
        b.* = .{ .index = @intCast(k), .size = g.pci.barSize(mask), .wide = src.chance(50), .prefetchable = false };
        ptrs[k] = b;
    }
    const base: u64 = 0x4000_0000;
    const size: u64 = 0x4000_0000;
    g.pci.place(ptrs[0..n], base, size) catch return;
    for (ptrs[0..n]) |b| {
        try std.testing.expect(b.addr >= base and b.addr + @max(b.size, g.pci.min_bar) <= base + size);
        try std.testing.expect(b.addr % @max(b.size, g.pci.min_bar) == 0);
    }
}

/// A disk someone else had: Tablecloth on a damaged image. Mounting and
/// unlocking may refuse; anything read must still be what was asked for.
fn tableclothDisk(src: *Source) !void {
    const T = g.tablecloth;
    const Store = T.Store(T.SimDisk, .{ .objects = 64, .names = 16, .secret_names = 8 });
    const gpa = std.testing.allocator;
    var disk = try T.SimDisk.init(gpa, 48);
    defer disk.deinit();
    const s = try gpa.create(Store);
    defer gpa.destroy(s);
    try s.format(&disk, 48, .{ .t = 1, .m_kib = 8 });
    try s.create(gpa, "pass", @splat(7));
    const public = try s.put("a public object");
    try s.bind("note", public, false, false);
    var scratch: [256]u8 = undefined;
    const secret = try s.seal("owner", "a sealed object", &scratch);
    try s.bind("diary", secret, true, false);
    try s.commit();
    try disk.flush();

    // The damage: whole blocks or a few bytes, anywhere.
    var edits = 1 + src.below(6);
    while (edits > 0) : (edits -= 1) {
        const block = src.below(48);
        const bytes: []u8 = &disk.media[block];
        if (src.chance(30)) src.bytes(bytes) else _ = src.mutate(bytes);
    }
    s.mount(&disk) catch return;
    s.unlock(gpa, "pass") catch {};
    var buf: [4096]u8 = undefined;
    for ([_][]const u8{ "note", "diary" }, [_]bool{ false, true }) |name, secret_name| {
        const h = (s.lookup(name, secret_name) catch continue) orelse continue;
        const data = s.get(h, "owner", &buf) catch continue;
        const e = s.entry(h) orelse return error.ReadWithoutEntry;
        if (!e.sealed()) try std.testing.expectEqualSlices(u8, &h, &T.publicHash(data));
    }
    for (s.publicNames()) |n| _ = n.text();
    _ = s.chooseBoot() catch {};
}

/// A boot image (Steward reads it; Aurora loads generations of them).
fn bootImage(src: *Source) !void {
    const gpa = std.testing.allocator;
    const bytes = try image.build(gpa, "manifest", &.{ .{ .name = "hello", .bytes = "program one" }, .{ .name = "steward", .bytes = "program two" } });
    defer gpa.free(bytes);
    const damaged = src.mutate(bytes);
    const img = image.Image.parse(damaged) catch return;
    _ = img.manifest();
    if (img.find("hello")) |e| _ = img.data(e);
    img.verify() catch return;
}

/// A generation's description, as read back from a disk.
fn generationView(src: *Source) !void {
    const G = g.generation;
    // A valid descriptor: two segments over three chunks.
    var buf: [@sizeOf(G.Header) + 2 * @sizeOf(G.Segment) + 3 * 32]u8 = undefined;
    var label: [32]u8 = @splat(0);
    @memcpy(label[0..9], "grain-dev");
    const h: G.Header = .{ .entry = 0x8020_0000, .segments = 2, .chunks = 3, .label = label, .closure = @splat(5) };
    const segs = [2]G.Segment{
        .{ .paddr = 0x8020_0000, .memsz = 0x3000, .filesz = 0x2000, .first_chunk = 0, .chunks = 2 },
        .{ .paddr = 0x8030_0000, .memsz = 0x1000, .filesz = 0x1000, .first_chunk = 2, .chunks = 1 },
    };
    @memcpy(buf[0..@sizeOf(G.Header)], std.mem.asBytes(&h));
    @memcpy(buf[@sizeOf(G.Header)..][0 .. 2 * @sizeOf(G.Segment)], std.mem.sliceAsBytes(&segs));
    @memset(buf[@sizeOf(G.Header) + 2 * @sizeOf(G.Segment) ..], 9);
    const v = G.View.parse(src.mutate(&buf)) catch return;
    _ = v.label();
    for (v.segments) |seg| {
        try std.testing.expect(seg.filesz <= seg.memsz);
        _ = v.hashes[seg.first_chunk..][0..seg.chunks];
    }
}

/// Messages from clients: every method of every protocol decodes any
/// words or refuses them, and what decodes encodes back to the same value.
fn idlMessages(src: *Source) !void {
    const idl = g.idl;
    var w: idl.Words = undefined;
    for (&w) |*x| x.* = switch (src.below(4)) {
        0 => src.below(4),
        1 => src.below(300),
        else => src.int(u64),
    };
    const pick = src.below(protocolMethods());
    var k: usize = 0;
    inline for (proto.all) |P| {
        inline for (comptime idl.methodNames(P)) |name| {
            defer k += 1;
            if (k == pick) {
                const M = @field(P, name);
                const v = idl.decode(M.Params, &w) catch return;
                const again = idl.encode(M.Params, v);
                const v2 = try idl.decode(M.Params, &again);
                try std.testing.expect(std.meta.eql(v, v2));
            }
        }
    }
}

fn protocolMethods() usize {
    comptime var n: usize = 0;
    inline for (proto.all) |P| n += comptime g.idl.methodNames(P).len;
    return n;
}

const dev_brix = @embedFile("dev.brix");

/// Manifests: Brix source, damaged, through evaluation and the validator.
fn manifests(src: *Source) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try arena.dupe(u8, dev_brix);
    const damaged = src.mutate(source);
    var diag: brix.Diagnostic = .{};
    const r = brix.evaluate(schema.Manifest, arena, damaged, &diag) catch return;
    var msg: [512]u8 = undefined;
    _ = schema.validate(r.value, &msg);
}

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------

test "fuzz: network frames" {
    try fuzz.run(netFrames, .{ .sweep = 2000 });
}
test "fuzz: Noise messages" {
    try fuzz.run(noiseMessages, .{ .sweep = 300 });
}
test "fuzz: USB configuration" {
    try fuzz.run(usbConfiguration, .{ .sweep = 2000 });
}
test "fuzz: PCI BARs" {
    try fuzz.run(pciBars, .{ .sweep = 2000 });
}
test "fuzz: Tablecloth disk" {
    try fuzz.run(tableclothDisk, .{ .sweep = 40 });
}
test "fuzz: boot image" {
    try fuzz.run(bootImage, .{ .sweep = 1000 });
}
test "fuzz: generation" {
    try fuzz.run(generationView, .{ .sweep = 1000 });
}
test "fuzz: IDL messages" {
    try fuzz.run(idlMessages, .{ .sweep = 3000 });
}
test "fuzz: manifests" {
    try fuzz.run(manifests, .{ .sweep = 300 });
}
