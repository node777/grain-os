//! Where a fuzz target gets its choices. Under `zig build fuzz --fuzz`,
//! Zig's coverage-guided fuzzer makes them (std.testing.Smith); otherwise a
//! seeded PRNG does, so `zig build test` sweeps every target the same way on
//! every run. Targets are written once against this.
const std = @import("std");
const Smith = std.testing.Smith;

pub const Source = struct {
    smith: ?*Smith = null,
    rng: ?std.Random = null,
    /// PRNG mode: steps `more` still allows.
    left: u32 = 0,

    fn site() u32 {
        return @truncate(@returnAddress());
    }

    /// A value in [0, n).
    pub fn below(s: *Source, n: u64) u64 {
        std.debug.assert(n != 0);
        if (s.smith) |sm| return sm.valueRangeLessThanWithHash(u64, 0, n, site());
        return s.rng.?.uintLessThan(u64, n);
    }

    /// Any value of an integer type.
    pub fn int(s: *Source, comptime T: type) T {
        if (s.smith) |sm| {
            const U = @Int(.unsigned, @bitSizeOf(T));
            const W = if (@bitSizeOf(T) <= 64) U else u64;
            return @bitCast(@as(U, @intCast(sm.valueWithHash(W, site()))));
        }
        return s.rng.?.int(T);
    }

    /// The interface of std.Random the simulator's generator uses.
    pub fn uintLessThan(s: *Source, comptime T: type, n: T) T {
        return @intCast(s.below(n));
    }

    pub fn chance(s: *Source, percent: u8) bool {
        return s.below(100) < percent;
    }

    pub fn bytes(s: *Source, out: []u8) void {
        if (s.smith) |sm| return sm.bytesWithHash(out, site());
        s.rng.?.bytes(out);
    }

    /// Bytes of a length the source picks, at most `buf.len`.
    pub fn slice(s: *Source, buf: []u8) []u8 {
        if (s.smith) |sm| return buf[0..sm.sliceWithHash(buf, site())];
        const n = s.below(buf.len + 1);
        s.rng.?.bytes(buf[0..n]);
        return buf[0..n];
    }

    /// Whether to take another step.
    pub fn more(s: *Source) bool {
        if (s.smith) |sm| return !sm.eosWeightedSimpleWithHash(15, 1, site());
        if (s.left == 0) return false;
        s.left -= 1;
        return true;
    }

    /// Damage a valid sample the way an attacker or a bad sector would:
    /// flipped bits, overwritten bytes and words, a cut-off end. Returns
    /// the (possibly shorter) result. Structure-aware inputs reach much
    /// deeper than random bytes.
    pub fn mutate(s: *Source, buf: []u8) []u8 {
        var out = buf;
        if (out.len == 0) return out;
        var edits = 1 + s.below(8);
        while (edits > 0 and out.len > 0) : (edits -= 1) {
            const at = s.below(out.len);
            switch (s.below(5)) {
                0 => out[at] ^= @as(u8, 1) << @intCast(s.below(8)),
                1 => out[at] = s.int(u8),
                2 => if (at + 4 <= out.len) std.mem.writeInt(u32, out[at..][0..4], interesting32[s.below(interesting32.len)], if (s.chance(50)) .big else .little),
                3 => if (at + 8 <= out.len) std.mem.writeInt(u64, out[at..][0..8], s.int(u64), .little),
                else => if (s.chance(30)) {
                    out = out[0..at];
                },
            }
        }
        return out;
    }
};

const interesting32 = [_]u32{ 0, 1, 2, 0x7f, 0x80, 0xff, 0x100, 0xfff, 0x1000, 0x7fff_ffff, 0x8000_0000, 0xffff_fffe, 0xffff_ffff };

pub const Target = fn (*Source) anyerror!void;

pub const Options = struct {
    /// Inputs per target in a sweep (no --fuzz).
    sweep: u32 = 200,
    /// Steps `more` allows per input in a sweep.
    steps: u32 = 64,
};

/// Run a target: under the fuzzer, forever (or to --fuzz's limit); else as a
/// seeded sweep. A failing sweep names its seed.
pub fn run(comptime target: Target, opts: Options) !void {
    // Always through std.testing.fuzz: that is how the build runner finds
    // fuzz tests. Outside --fuzz it runs the target once on empty input.
    try std.testing.fuzz({}, struct {
        fn one(_: void, sm: *Smith) anyerror!void {
            var src: Source = .{ .smith = sm };
            return target(&src);
        }
    }.one, .{});
    if (@import("builtin").fuzz) return;
    const sweep = @import("fuzz_options").sweep;
    var seed: u64 = 0;
    while (seed < @as(u64, opts.sweep) * sweep / 100) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed *% 0x9e37_79b9_7f4a_7c15 +% 1);
        var src: Source = .{ .rng = prng.random(), .left = opts.steps };
        target(&src) catch |e| {
            std.debug.print("fuzz: input {d} failed: {s}\n", .{ seed, @errorName(e) });
            return e;
        };
    }
}
