//! Every protocol in Grain, in one list. Steward checks manifests against it,
//! the Registry serves its descriptors, and Envoy encodes agent calls with it.
const std = @import("std");
const idl = @import("grain").idl;

pub const console = @import("console.zig");
pub const entropy = @import("entropy.zig");
pub const echo = @import("echo.zig");
pub const kv = @import("kv.zig");
pub const registry = @import("registry.zig");
pub const tablecloth = @import("tablecloth.zig");
pub const kumara = @import("kumara.zig");
pub const ledger = @import("ledger.zig");
pub const input = @import("input.zig");
pub const surf = @import("surf.zig");
pub const scene = @import("scene.zig");
pub const mycelium = @import("mycelium.zig");
pub const comlink = @import("comlink.zig");
pub const guestbook = @import("guestbook.zig");
pub const attest = @import("attest.zig");
pub const steward = @import("steward.zig");

pub const all = .{ console, entropy, echo, kv, registry, tablecloth, kumara, ledger, input, surf, scene, mycelium, comlink, guestbook, attest, steward };

comptime {
    for (all) |P| idl.check(P);
    // Ids must be unique, and so must the 16 bits the kernel checks.
    for (all, 0..) |a, i| for (all, 0..) |b, j| if (i < j) {
        if (idl.id(a) == idl.id(b)) @compileError("protocol id collision: " ++ idl.fullName(a) ++ " and " ++ idl.fullName(b));
        if (idl.kernelId(a) == idl.kernelId(b)) @compileError("kernel protocol id collision: " ++ idl.fullName(a) ++ " and " ++ idl.fullName(b) ++ "; bump a version or reword a doc");
    };
}

/// Whether `full` (e.g. "console.v1") names a known protocol.
pub fn known(comptime full: []const u8) bool {
    inline for (all) |P| if (comptime std.mem.eql(u8, idl.fullName(P), full)) return true;
    return false;
}

/// The kernel-checked id for a protocol named in a manifest.
pub fn kernelIdOf(comptime full: []const u8) u16 {
    inline for (all) |P| if (comptime std.mem.eql(u8, idl.fullName(P), full)) return idl.kernelId(P);
    @compileError("unknown protocol " ++ full);
}

pub fn idOf(comptime full: []const u8) u64 {
    inline for (all) |P| if (comptime std.mem.eql(u8, idl.fullName(P), full)) return idl.id(P);
    @compileError("unknown protocol " ++ full);
}

pub fn names() []const []const u8 {
    comptime {
        var out: []const []const u8 = &.{};
        for (all) |P| out = out ++ .{idl.fullName(P)};
        return out;
    }
}
