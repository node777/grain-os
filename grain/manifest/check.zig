//! Compile-time manifest check, on its own: `zig build check-manifest
//! -Dsystem=<path>` compiles this file, and a miswired manifest is a
//! compile error naming the problem. (Steward runs the same check.)
const std = @import("std");
const schema = @import("schema");
const proto = @import("proto");
const manifest: schema.Manifest = @import("system.zon");
comptime {
    schema.check(manifest, "system manifest");
    @setEvalBranchQuota(100_000);
    for (manifest.domains) |d| {
        for (d.provides) |p| if (!proto.known(p.protocol)) @compileError("system manifest: domain '" ++ d.name ++ "' provides " ++ p.protocol ++ ", which is not defined in grain/proto");
        for (d.uses) |u| if (!proto.known(u.protocol)) @compileError("system manifest: domain '" ++ d.name ++ "' uses " ++ u.protocol ++ ", which is not defined in grain/proto");
    }
}
