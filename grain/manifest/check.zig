//! Compile-time manifest check, on its own: `zig build check-manifest
//! -Dsystem=<path>` compiles this file, and a miswired manifest is a
//! compile error naming the problem. (Steward runs the same check.)
const schema = @import("schema");
const manifest: schema.Manifest = @import("system.zon");
comptime {
    schema.check(manifest, "system manifest");
}
