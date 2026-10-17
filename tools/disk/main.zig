//! grain-disk: make and inspect Tablecloth disks on the host.
//!
//!   grain-disk format <disk.img> <size MiB> [--kdf-kib N] [--kdf-t N]
//!                     [--install <kernel.elf> <label>] [--stage <kernel.elf> <label>]
//!   grain-disk show <disk.img>
//!   grain-disk add <disk.img> <kernel.elf> <label> [--current | --stage]
//!   grain-disk pack <kernel.elf> <label> <out-dir>
//!
//! `add` stores a kernel image as a generation (see lib/generation.zig) and
//! names it `system@N`; `--current` makes it the one Aurora boots (a fresh
//! disk's first generation), `--stage` puts it on trial. `pack` writes a
//! generation as files instead: `descriptor` and `chunks/<hash>`, plus
//! `generation` (its hash in hex), for an agent to upload through Envoy.
//!
//! The image is a raw disk (QEMU: -drive format=raw). The Argon2id cost is
//! fixed when the disk is formatted; the default (16 MiB, 2 passes) is for
//! real use, and tests format cheap disks.
const std = @import("std");
const tc = @import("tablecloth");
const gen = tc.generation;

/// A generation built from a kernel ELF: the descriptor and the chunks it
/// names (slices of the ELF), in order.
pub const Built = struct {
    descriptor: []u8,
    chunks: []const []const u8,
    hash: gen.Hash,
};

pub fn build(arena: std.mem.Allocator, elf: []const u8, label: []const u8) !Built {
    const rd = struct {
        fn f(comptime T: type, b: []const u8, off: usize) T {
            return std.mem.readInt(T, b[off..][0..@sizeOf(T)], .little);
        }
    }.f;
    if (elf.len < 64 or !std.mem.eql(u8, elf[0..4], "\x7fELF")) return error.NotElf;
    const entry = rd(u64, elf, 24);
    const phoff: usize = @intCast(rd(u64, elf, 32));
    const phentsize: usize = rd(u16, elf, 54);
    const phnum: usize = rd(u16, elf, 56);
    var segs: std.ArrayList(gen.Segment) = .empty;
    var chunks: std.ArrayList([]const u8) = .empty;
    var hashes: std.ArrayList(gen.Hash) = .empty;
    var entry_phys: ?u64 = null;
    for (0..phnum) |i| {
        const ph = phoff + phentsize * i;
        if (rd(u32, elf, ph) != 1) continue;
        const off: usize = @intCast(rd(u64, elf, ph + 8));
        const vaddr = rd(u64, elf, ph + 16);
        const paddr = rd(u64, elf, ph + 24);
        const filesz: usize = @intCast(rd(u64, elf, ph + 32));
        const memsz = rd(u64, elf, ph + 40);
        if (entry >= vaddr and entry < vaddr + memsz) entry_phys = entry - vaddr + paddr;
        const first = chunks.items.len;
        var data = elf[off..][0..filesz];
        while (data.len > 0) {
            const n = gen.nextChunk(data);
            try chunks.append(arena, data[0..n]);
            try hashes.append(arena, tc.publicHash(data[0..n]));
            data = data[n..];
        }
        try segs.append(arena, .{ .paddr = paddr, .memsz = memsz, .filesz = filesz, .first_chunk = @intCast(first), .chunks = @intCast(chunks.items.len - first) });
    }
    var h: gen.Header = .{ .entry = entry_phys orelse return error.NoEntry, .segments = @intCast(segs.items.len), .chunks = @intCast(chunks.items.len), .label = @splat(0), .closure = @splat(0) };
    @memcpy(h.label[0..@min(label.len, 31)], label[0..@min(label.len, 31)]);
    var d: std.ArrayList(u8) = .empty;
    try d.appendSlice(arena, std.mem.asBytes(&h));
    try d.appendSlice(arena, std.mem.sliceAsBytes(segs.items));
    try d.appendSlice(arena, std.mem.sliceAsBytes(hashes.items));
    if (d.items.len > tc.max_object) return error.TooLarge;
    return .{ .descriptor = d.items, .chunks = chunks.items, .hash = tc.publicHash(d.items) };
}

/// A Tablecloth block device over a host file.
pub const FileDisk = struct {
    file: std.Io.File,
    io: std.Io,

    pub fn read(d: *FileDisk, block: u64, buf: *tc.Block) !void {
        const n = try d.file.readPositionalAll(d.io, buf, block * tc.block_size);
        if (n != tc.block_size) @memset(buf[n..], 0);
    }

    pub fn write(d: *FileDisk, block: u64, buf: *const tc.Block) !void {
        try d.file.writePositionalAll(d.io, buf, block * tc.block_size);
    }

    pub fn flush(d: *FileDisk) !void {
        try d.file.sync(d.io);
    }
};

pub const Store = tc.Store(FileDisk, .{});

fn addGeneration(arena: std.mem.Allocator, io: std.Io, s: *Store, elf_path: []const u8, label: []const u8, mode: []const u8) !void {
    const elf = try std.Io.Dir.cwd().readFileAlloc(io, elf_path, arena, .unlimited);
    const g = try build(arena, elf, label);
    var fresh: usize = 0;
    for (g.chunks) |c| {
        if (!s.has(tc.publicHash(c))) fresh += 1;
        _ = try s.put(c);
    }
    _ = try s.put(g.descriptor);
    var n: usize = 1;
    for (s.publicNames()) |*nm| if (std.mem.startsWith(u8, nm.text(), "system@")) {
        n += 1;
    };
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "system@{d}", .{n});
    try s.bind(name, g.hash, false, false);
    try s.commit();
    if (std.mem.eql(u8, mode, "--current")) try s.install(g.hash) else if (std.mem.eql(u8, mode, "--stage")) try s.stage(g.hash);
    std.debug.print("@disk added name={s} generation={x} label={s} chunks={d} new_chunks={d} {s}\n", .{ name, g.hash, label, g.chunks.len, fresh, mode });
}

fn usage() u8 {
    std.debug.print("usage: grain-disk format <disk.img> <size MiB> [--kdf-kib N] [--kdf-t N]\n       grain-disk show <disk.img>\n       grain-disk add <disk.img> <kernel.elf> <label> [--current | --stage]\n       grain-disk pack <kernel.elf> <label> <out-dir>\n", .{});
    return 2;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return usage();
    const cwd = std.Io.Dir.cwd();
    if (std.mem.eql(u8, args[1], "format")) {
        if (args.len < 4) return usage();
        const mib = try std.fmt.parseUnsigned(u64, args[3], 10);
        var cost: tc.KdfCost = .{};
        // Generations to add right away: the first is installed as current,
        // a --stage one is put on trial.
        var adds: [2]struct { elf: []const u8, label: []const u8, mode: []const u8 } = undefined;
        var n_adds: usize = 0;
        var i: usize = 4;
        while (i + 1 < args.len) {
            if (std.mem.eql(u8, args[i], "--kdf-kib")) {
                cost.m_kib = try std.fmt.parseUnsigned(u32, args[i + 1], 10);
                i += 2;
            } else if (std.mem.eql(u8, args[i], "--kdf-t")) {
                cost.t = try std.fmt.parseUnsigned(u32, args[i + 1], 10);
                i += 2;
            } else if ((std.mem.eql(u8, args[i], "--install") or std.mem.eql(u8, args[i], "--stage")) and i + 2 < args.len and n_adds < adds.len) {
                adds[n_adds] = .{ .elf = args[i + 1], .label = args[i + 2], .mode = if (std.mem.eql(u8, args[i], "--install")) "--current" else "--stage" };
                n_adds += 1;
                i += 3;
            } else return usage();
        }
        const file = try cwd.createFile(io, args[2], .{ .read = true, .truncate = true });
        defer file.close(io);
        try file.setLength(io, mib * 1024 * 1024);
        var d: FileDisk = .{ .file = file, .io = io };
        const s = try arena.create(Store);
        try s.format(&d, mib * 1024 * 1024 / tc.block_size, cost);
        std.debug.print("@disk formatted path={s} blocks={d} kdf_kib={d} kdf_t={d}\n", .{ args[2], s.sup.blocks, cost.m_kib, cost.t });
        for (adds[0..n_adds]) |a| try addGeneration(arena, io, s, a.elf, a.label, a.mode);
        return 0;
    }
    if (std.mem.eql(u8, args[1], "add")) {
        if (args.len < 5) return usage();
        const file = try cwd.openFile(io, args[2], .{ .mode = .read_write });
        defer file.close(io);
        var d: FileDisk = .{ .file = file, .io = io };
        const s = try arena.create(Store);
        try s.mount(&d);
        try addGeneration(arena, io, s, args[3], args[4], if (args.len > 5) args[5] else "");
        return 0;
    }
    if (std.mem.eql(u8, args[1], "pack")) {
        if (args.len < 5) return usage();
        const elf = try cwd.readFileAlloc(io, args[2], arena, .unlimited);
        const g = try build(arena, elf, args[3]);
        const out = args[4];
        try cwd.createDirPath(io, out);
        const dir = try cwd.openDir(io, out, .{});
        try dir.createDirPath(io, "chunks");
        try dir.writeFile(io, .{ .sub_path = "descriptor", .data = g.descriptor });
        var hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x}", .{g.hash}) catch unreachable;
        try dir.writeFile(io, .{ .sub_path = "generation", .data = &hex });
        for (g.chunks) |c| {
            var name: [80]u8 = undefined;
            const p = try std.fmt.bufPrint(&name, "chunks/{x}", .{tc.publicHash(c)});
            try dir.writeFile(io, .{ .sub_path = p, .data = c });
        }
        std.debug.print("@disk packed generation={s} label={s} chunks={d}\n", .{ &hex, args[3], g.chunks.len });
        return 0;
    }
    if (std.mem.eql(u8, args[1], "show")) {
        const file = try cwd.openFile(io, args[2], .{});
        defer file.close(io);
        var d: FileDisk = .{ .file = file, .io = io };
        const s = try arena.create(Store);
        try s.mount(&d);
        const b = s.sup.boot;
        std.debug.print("@disk seq={d} blocks={d} used_blocks={d} free_blocks={d} objects={d} passphrase={} current={x} pending={x} tries={d}\n", .{
            s.sup.seq, s.sup.blocks, s.sup.usedBlocks(), s.freeBlocks(), s.n_objects, s.passphraseSet(), b.current[0..8], b.pending[0..8], b.tries,
        });
        for (s.publicNames()) |*n| {
            if (n.flags & tc.flag_retired != 0) std.debug.print("@disk name={s} retired\n", .{n.text()}) else std.debug.print("@disk name={s} hash={x}\n", .{ n.text(), n.hash[0..8] });
        }
        return 0;
    }
    return usage();
}
