//! grain-disk: make and inspect Tablecloth disks on the host.
//!
//!   grain-disk format <disk.img> <size MiB> [--kdf-kib N] [--kdf-t N]
//!   grain-disk show <disk.img>
//!
//! The image is a raw disk (QEMU: -drive format=raw). The Argon2id cost is
//! fixed when the disk is formatted; the default (16 MiB, 2 passes) is for
//! real use, and tests format cheap disks.
const std = @import("std");
const tc = @import("tablecloth");

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

fn usage() u8 {
    std.debug.print("usage: grain-disk format <disk.img> <size MiB> [--kdf-kib N] [--kdf-t N]\n       grain-disk show <disk.img>\n", .{});
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
        var i: usize = 4;
        while (i + 1 < args.len) : (i += 2) {
            if (std.mem.eql(u8, args[i], "--kdf-kib")) cost.m_kib = try std.fmt.parseUnsigned(u32, args[i + 1], 10) else if (std.mem.eql(u8, args[i], "--kdf-t")) cost.t = try std.fmt.parseUnsigned(u32, args[i + 1], 10) else return usage();
        }
        const file = try cwd.createFile(io, args[2], .{ .read = true, .truncate = true });
        defer file.close(io);
        try file.setLength(io, mib * 1024 * 1024);
        var d: FileDisk = .{ .file = file, .io = io };
        const s = try arena.create(Store);
        try s.format(&d, mib * 1024 * 1024 / tc.block_size, cost);
        std.debug.print("@disk formatted path={s} blocks={d} kdf_kib={d} kdf_t={d}\n", .{ args[2], s.sup.blocks, cost.m_kib, cost.t });
        return 0;
    }
    if (std.mem.eql(u8, args[1], "show")) {
        const file = try cwd.openFile(io, args[2], .{});
        defer file.close(io);
        var d: FileDisk = .{ .file = file, .io = io };
        const s = try arena.create(Store);
        try s.mount(&d);
        const b = s.sup.boot;
        std.debug.print("@disk seq={d} blocks={d} used_blocks={d} objects={d} passphrase={} current={x} pending={x} tries={d}\n", .{
            s.sup.seq, s.sup.blocks, s.sup.log_end, s.n_objects, s.passphraseSet(), b.current[0..8], b.pending[0..8], b.tries,
        });
        for (s.publicNames()) |*n| std.debug.print("@disk name={s} hash={x}\n", .{ n.text(), n.hash[0..8] });
        return 0;
    }
    return usage();
}
