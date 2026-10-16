//! The first service protocols. Each is a set of labels and the meaning of
//! the message words, plus client helpers. (Phase 4 replaces this hand-written
//! file with typed interface definitions.)
const std = @import("std");
const grain = @import("grain.zig");

/// Reply label for success; anything else is an error.
pub const ok: u32 = 0;
pub const failed: u32 = 1;

/// console.v1: text output.
pub const console = struct {
    /// w0 = byte count (≤ 32), w1..w4 = bytes, packed little-endian.
    pub const write: u32 = 1;

    pub fn print(ep: grain.CPtr, text: []const u8) !void {
        var rest = text;
        while (rest.len > 0) {
            const n = @min(rest.len, 32);
            var chunk: [32]u8 = @splat(0);
            @memcpy(chunk[0..n], rest[0..n]);
            var w: [5]usize = undefined;
            w[0] = n;
            for (0..4) |i| w[i + 1] = std.mem.readInt(u64, chunk[i * 8 ..][0..8], .little);
            const r = grain.syscall(.call, ep, @bitCast(grain.Tag{ .label = write, .length = 5 }), w);
            if (r.status != .ok) return grain.statusError(r.status);
            if (r.tag.label != ok) return error.ConsoleFailed;
            rest = rest[n..];
        }
    }

    /// Unpack a write request's bytes.
    pub fn bytesOf(w: [5]usize, out: *[32]u8) []const u8 {
        for (0..4) |i| std.mem.writeInt(u64, out[i * 8 ..][0..8], w[i + 1], .little);
        return out[0..@min(w[0], 32)];
    }
};

/// entropy.v1: random bytes from a hardware source.
pub const entropy = struct {
    /// Reply: w0..w3 = 32 bytes.
    pub const get: u32 = 1;

    pub fn fill(ep: grain.CPtr, out: *[32]u8) !void {
        const r = grain.call(ep, .{ .label = get }, .{});
        if (r.status != .ok) return grain.statusError(r.status);
        if (r.tag.label != ok) return error.EntropyFailed;
        for (0..4) |i| std.mem.writeInt(u64, out[i * 8 ..][0..8], r.w[i], .little);
    }
};

/// echo.v1: answers w0 + 1 (a liveness check).
pub const echo = struct {
    pub const ping: u32 = 1;
};
