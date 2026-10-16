//! The shipped manifests must pass validation. (Kept apart from schema.zig
//! because Zig resolves every @import in a file, test blocks included.)
const std = @import("std");
const schema = @import("schema");

test "system/dev.zon is sound" {
    const m: schema.Manifest = @import("dev.zon");
    var buf: [512]u8 = undefined;
    if (schema.validate(m, &buf)) |e| {
        std.debug.print("system/dev.zon: {s}\n", .{e});
        return error.TestUnexpectedError;
    }
}

test "system/tests/miswired.zon is rejected" {
    const m: schema.Manifest = @import("miswired.zon");
    var buf: [512]u8 = undefined;
    try std.testing.expect(schema.validate(m, &buf) != null);
}
