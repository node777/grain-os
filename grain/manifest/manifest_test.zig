//! The shipped manifests (system/*.brix) must evaluate and pass validation.
//! (Kept apart from schema.zig because Zig resolves every @import in a file,
//! test blocks included.)
const std = @import("std");
const schema = @import("schema");
const brix = @import("brix");

fn load(arena: std.mem.Allocator, comptime file: []const u8, src: []const u8) !schema.Manifest {
    var d: brix.Diagnostic = .{};
    const r = brix.evaluate(schema.Manifest, arena, src, &d) catch |e| {
        std.debug.print("{s}:{d}:{d}: {s}\n", .{ file, d.pos.line, d.pos.col, d.msg });
        return e;
    };
    return r.value;
}

test "system/dev.brix is sound" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try load(arena.allocator(), "system/dev.brix", @embedFile("dev.brix"));
    var buf: [512]u8 = undefined;
    if (schema.validate(m, &buf)) |e| {
        std.debug.print("system/dev.brix: {s}\n", .{e});
        return error.TestUnexpectedError;
    }
    // Units, templates and blocks landed where they should.
    const envoy = m.domains[schema.findDomain(m, "envoy").?];
    try std.testing.expectEqual(@as(u32, 2_000), envoy.budget_us);
    try std.testing.expectEqual(@as(u32, 10_000), envoy.period_us);
    try std.testing.expectEqual(@as(u32, 128), envoy.memory_kib);
    try std.testing.expect(envoy.debug_console and envoy.devices[0].optional and envoy.devices[0].instance == 1);
    const console = m.domains[schema.findDomain(m, "console").?];
    try std.testing.expectEqual(@as(u8, 200), console.priority);
    try std.testing.expectEqual(schema.Restart.on_fault, console.restart);
    try std.testing.expectEqual(@as(u32, 15_000), m.agent.?.grants[0].duration_ms);
    try std.testing.expectEqualStrings("entropy", m.agent.?.askable[0].name);
}

test "system/tests/faults.brix is sound" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try load(arena.allocator(), "system/tests/faults.brix", @embedFile("faults.brix"));
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), schema.validate(m, &buf));
}

test "system/tests/miswired.brix is rejected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try load(arena.allocator(), "system/tests/miswired.brix", @embedFile("miswired.brix"));
    var buf: [512]u8 = undefined;
    const e = schema.validate(m, &buf) orelse return error.TestExpectedError;
    try std.testing.expect(std.mem.indexOf(u8, e, "console.consol") != null);
}
