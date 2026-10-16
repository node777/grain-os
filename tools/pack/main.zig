//! grain-pack: build a Grain boot image from a manifest and program ELFs.
//!
//!   grain-pack <out.img> <manifest.zon> <name>=<program.elf> ...
//!
//! Checks the manifest (the same `validate` Steward runs at compile time),
//! checks that every program it names was supplied, writes the image, and
//! prints the closure hash that names the whole system.
const std = @import("std");
const schema = @import("schema");
const image = @import("image");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
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
        const bytes = try cwd.readFileAlloc(io, a[eq + 1 ..], arena, .unlimited);
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
