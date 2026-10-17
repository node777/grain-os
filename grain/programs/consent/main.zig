//! consent: puts the agent's asks to the owner. When the agent asks for an
//! askable service, Steward holds the question; this domain finds it
//! (Lifecycle.pending), shows it on the owner's console, reads the answer
//! the owner types (input.v1) and gives it to Steward (Lifecycle.decide).
//! Only the domain the manifest names as `agent.owner` may do either, and
//! the agent's own domain can never be it.
//!
//! What was typed before a question appears is thrown away, so nothing
//! typed ahead (a stray "yes") answers a question the owner has not seen.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");
const D = g.domain;

pub const panic = g.panic;
comptime {
    g.exportStart();
}

var sig: g.CPtr = 0;
var ticks_per_ms: u64 = 1;

fn sleepMs(ms: u64) void {
    _ = g.alarm(sig, ms * ticks_per_ms);
    _ = g.wait(sig);
}

fn lifecycle(label: D.Lifecycle, w: [5]usize, length: u7) g.Result {
    return g.syscall(.call, D.Slot.steward, @bitCast(g.Tag{ .label = @backingInt(label), .length = length }), w);
}

/// The next line the owner typed, if one is waiting.
fn takeLine(input: g.CPtr, out: *[128]u8) ?[]const u8 {
    const r = g.idl.call(proto.input.read_line, input, .{}) catch return null;
    if (!r.ready) return null;
    const t = r.text.slice();
    @memcpy(out[0..t.len], t);
    return std.mem.trim(u8, out[0..t.len], " \t");
}

const Question = struct {
    number: usize,
    name: [24]u8,
    uses: u32,
    duration_ms: u32,

    fn nameSlice(q: *const Question) []const u8 {
        return q.name[0 .. std.mem.indexOfScalar(u8, &q.name, 0) orelse q.name.len];
    }
};

fn waiting() !?Question {
    const r = lifecycle(.pending, @splat(0), 0);
    if (r.status != .ok or r.tag.label != 0) return error.NotOwner;
    if (r.w[0] == 0) return null;
    var q: Question = .{ .number = r.w[0], .name = undefined, .uses = @truncate(r.w[4]), .duration_ms = @truncate(r.w[4] >> 32) };
    @memcpy(q.name[0..8], std.mem.asBytes(&r.w[1]));
    @memcpy(q.name[8..16], std.mem.asBytes(&r.w[2]));
    @memcpy(q.name[16..24], std.mem.asBytes(&r.w[3]));
    return q;
}

fn show(console: g.CPtr, q: *const Question) void {
    var buf: [256]u8 = undefined;
    var limits: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&limits);
    if (q.uses != 0) w.print("at most {d} uses", .{q.uses}) catch {};
    if (q.uses != 0 and q.duration_ms != 0) w.writeAll(", ") catch {};
    if (q.duration_ms != 0) w.print("for {d} s", .{(q.duration_ms + 999) / 1000}) catch {};
    const lim = if (w.end == 0) "no limit" else w.buffered();
    const text = std.fmt.bufPrint(&buf, "\n[owner] The agent asks for '{s}' ({s}). Allow it? Type yes or no.\n", .{ q.nameSlice(), lim }) catch return;
    proto.console.print(console, text) catch {};
}

pub fn main() !u16 {
    const console = g.use("console") orelse return error.NoConsole;
    const input = g.use("input") orelse return error.NoInput;
    var space: g.Space = .{ .untyped = D.Slot.memory, .vspace = D.Slot.vspace, .next_slot = D.Slot.first_free };
    sig = try space.retype(.signal, 0);
    ticks_per_ms = @max(1, g.env().timebase_hz / 1000);
    g.log("consent_ready", .{});

    var shown: usize = 0; // the question on the console, by number
    var line: [128]u8 = undefined;
    while (true) {
        const q = (try waiting()) orelse {
            shown = 0;
            sleepMs(100);
            continue;
        };
        if (q.number != shown) {
            while (takeLine(input, &line)) |_| {} // typed before the question: not an answer
            show(console, &q);
            shown = q.number;
            g.log("owner_asked", .{ .service = q.nameSlice(), .uses = q.uses, .duration_ms = q.duration_ms });
        }
        const answer = takeLine(input, &line) orelse {
            sleepMs(50);
            continue;
        };
        const yes = std.ascii.eqlIgnoreCase(answer, "yes") or std.ascii.eqlIgnoreCase(answer, "y");
        const no = std.ascii.eqlIgnoreCase(answer, "no") or std.ascii.eqlIgnoreCase(answer, "n");
        if (!yes and !no) {
            proto.console.print(console, "[owner] Please type yes or no.\n") catch {};
            continue;
        }
        const r = lifecycle(.decide, .{ q.number, @intFromBool(yes), 0, 0, 0 }, 2);
        const recorded = r.status == .ok and r.tag.label == 0;
        proto.console.print(console, if (!recorded) "[owner] That question is no longer open.\n" else if (yes) "[owner] Allowed.\n" else "[owner] Refused.\n") catch {};
        shown = 0;
    }
}
