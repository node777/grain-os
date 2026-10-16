//! grain-pack: build a Grain boot image from a manifest and program ELFs.
//!
//!   grain-pack <out.img> <manifest.zon> <name>=<program.elf> ...
//!   grain-pack compact <in.elf> <out.elf>
//!
//! Checks the manifest (the same `validate` Steward runs at compile time),
//! checks that every program it names was supplied, writes the image, and
//! prints the closure hash that names the whole system.
const std = @import("std");
const schema = @import("schema");
const image = @import("image");

/// The loadable part of an ELF executable, as a smaller ELF: the header,
/// the program headers, and each PT_LOAD segment's file bytes, packed end to
/// end. No sections, no symbols, no debug information: what a loader reads
/// and nothing else. (gdb uses the full binaries in zig-out.)
pub fn compact(arena: std.mem.Allocator, elf: []const u8) ![]u8 {
    if (elf.len < 64 or !std.mem.eql(u8, elf[0..4], "\x7fELF") or elf[4] != 2 or elf[5] != 1) return error.NotElf64;
    const rd = struct {
        fn f(comptime T: type, b: []const u8, off: usize) T {
            return std.mem.readInt(T, b[off..][0..@sizeOf(T)], .little);
        }
    }.f;
    const phoff: usize = @intCast(rd(u64, elf, 32));
    const phentsize: usize = rd(u16, elf, 54);
    const phnum: usize = rd(u16, elf, 56);
    if (phentsize < 56 or phoff + phentsize * phnum > elf.len) return error.Truncated;
    var size: usize = 64 + phentsize * phnum;
    for (0..phnum) |i| {
        const ph = phoff + phentsize * i;
        if (rd(u32, elf, ph) == 1) size += @intCast(rd(u64, elf, ph + 32));
    }
    const out = try arena.alloc(u8, size);
    @memcpy(out[0..64], elf[0..64]);
    std.mem.writeInt(u64, out[32..40], 64, .little); // e_phoff
    std.mem.writeInt(u64, out[40..48], 0, .little); // e_shoff
    std.mem.writeInt(u16, out[58..60], 0, .little); // e_shentsize
    std.mem.writeInt(u16, out[60..62], 0, .little); // e_shnum
    std.mem.writeInt(u16, out[62..64], 0, .little); // e_shstrndx
    var data_at: usize = 64 + phentsize * phnum;
    for (0..phnum) |i| {
        const src = phoff + phentsize * i;
        const dst = 64 + phentsize * i;
        @memcpy(out[dst..][0..phentsize], elf[src..][0..phentsize]);
        if (rd(u32, elf, src) != 1) continue;
        const off: usize = @intCast(rd(u64, elf, src + 8));
        const filesz: usize = @intCast(rd(u64, elf, src + 32));
        if (off + filesz > elf.len) return error.Truncated;
        @memcpy(out[data_at..][0..filesz], elf[off..][0..filesz]);
        std.mem.writeInt(u64, out[dst + 8 ..][0..8], data_at, .little);
        data_at += filesz;
    }
    return out;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 4 and std.mem.eql(u8, args[1], "compact")) {
        const elf = try std.Io.Dir.cwd().readFileAlloc(io, args[2], arena, .unlimited);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = try compact(arena, elf) });
        return;
    }
    if (args.len < 3) {
        std.debug.print("usage: grain-pack <out.img> <manifest.zon> <name>=<program.elf> ...\n", .{});
        return error.InvalidArgument;
    }
    const cwd = std.Io.Dir.cwd();
    const manifest_src = try cwd.readFileAllocOptions(io, args[2], arena, .unlimited, .of(u8), 0);
    var diag: std.zon.parse.Diagnostics = undefined;
    const m = std.zon.parse.fromSlice(schema.Manifest, .{ .gpa = init.gpa, .arena = arena, .source = manifest_src, .diagnostics = &diag }) catch |e| {
        std.debug.print("{s}: not a valid manifest ({s})\n", .{ args[2], @errorName(e) });
        return error.InvalidManifest;
    };
    var buf: [512]u8 = undefined;
    if (schema.validate(m, &buf)) |msg| {
        std.debug.print("{s}: {s}\n", .{ args[2], msg });
        return error.InvalidManifest;
    }

    // Only the programs the manifest names go in: the closure covers exactly
    // what this system runs.
    var programs: std.ArrayList(image.Program) = .empty;
    for (args[3..]) |a| {
        const eq = std.mem.indexOfScalar(u8, a, '=') orelse return error.InvalidArgument;
        const name = a[0..eq];
        const named = for (m.domains) |d| {
            if (std.mem.eql(u8, d.program, name)) break true;
        } else false;
        const dup = for (programs.items) |p| {
            if (std.mem.eql(u8, p.name, name)) break true;
        } else false;
        if (!named or dup) continue;
        const bytes = try compact(arena, try cwd.readFileAlloc(io, a[eq + 1 ..], arena, .unlimited));
        try programs.append(arena, .{ .name = name, .bytes = bytes });
    }
    for (m.domains) |d| {
        const have = for (programs.items) |p| {
            if (std.mem.eql(u8, p.name, d.program)) break true;
        } else false;
        if (!have) {
            std.debug.print("{s}: domain '{s}' needs program '{s}', which was not built\n", .{ args[2], d.name, d.program });
            return error.MissingProgram;
        }
    }

    const bytes = try image.build(arena, manifest_src, programs.items);
    try cwd.writeFile(io, .{ .sub_path = args[1], .data = bytes });
    const img = try image.Image.parse(bytes);
    std.debug.print("@pack system={s} programs={d} bytes={d} closure={s}\n", .{ m.name, programs.items.len, bytes.len, &image.hexHash(img.header.closure) });
}
