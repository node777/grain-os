//! shell: the first application on the desktop. The owner types a command,
//! presses enter, and the answer appears: who this instance is, what the
//! store holds, how long the Ledger is, keys in the key-value store.
//!
//! It draws itself as brushstrokes (surf.v1), so every line it shows is an
//! element an agent can read back through scene.v1. It waits on one signal,
//! which Surf raises when keys or clicks are waiting for it.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");
const S = proto.surf;
const idl = g.idl;
const D = g.domain;

pub const panic = g.panic;
pub const std_options = g.std_options;
comptime {
    g.exportStart();
}

const width = 640;
const height = 404;
const line_h = 20;
const pad = 14;
const rows = (height - 2 * pad - 30) / line_h;
const cols = (width - 2 * pad) / g.paint.font.w;

const color = struct {
    const ink: u32 = 0x221d30;
    const text: u32 = 0xe9dfcf;
    const command: u32 = 0xb8a6e0;
    const answer: u32 = 0xe9dfcf;
    const fault: u32 = 0xf0a07a;
    const prompt: u32 = 0x8fd1b5;
    const cursor: u32 = 0x8fd1b5;
    const button: u32 = 0x3d355a;
};

const Kind = enum { command, answer, fault };
const Line = struct { kind: Kind = .answer, text: [cols]u8 = undefined, len: u8 = 0 };

var lines: [rows]Line = @splat(.{});
var n_lines: usize = 0;
var input: [cols - 2]u8 = undefined;
var input_len: usize = 0;

fn say(kind: Kind, text: []const u8) void {
    if (n_lines == rows) {
        std.mem.copyForwards(Line, lines[0 .. rows - 1], lines[1..rows]);
        n_lines -= 1;
    }
    const l = &lines[n_lines];
    l.kind = kind;
    l.len = @intCast(@min(text.len, cols));
    @memcpy(l.text[0..l.len], text[0..l.len]);
    n_lines += 1;
}

fn sayf(kind: Kind, comptime fmt: []const u8, args: anytype) void {
    var buf: [cols]u8 = undefined;
    say(kind, std.fmt.bufPrint(&buf, fmt, args) catch buf[0..]);
}

const button_clear: u16 = 1;

fn draw(surf: g.CPtr) !void {
    var f: S.Frame = .{ .ep = surf };
    try f.fill(.{ .x = 0, .y = 0, .w = width, .h = height }, color.ink, "background");
    try f.button(.{ .x = width - pad - 64, .y = pad - 4, .w = 64, .h = 24 }, color.button, button_clear, "clear");
    for (lines[0..n_lines], 0..) |*l, i| {
        const y: i32 = @intCast(pad + 30 + i * line_h);
        const c = switch (l.kind) {
            .command => color.command,
            .answer => color.answer,
            .fault => color.fault,
        };
        try f.text(pad, y, l.text[0..l.len], c, @tagName(l.kind));
    }
    const y: i32 = @intCast(pad + 30 + n_lines * line_h);
    try f.text(pad, y, ">", color.prompt, "prompt");
    try f.text(pad + 2 * g.paint.font.w, y, input[0..input_len], color.text, "input");
    try f.fill(.{ .x = pad + @as(i32, @intCast(2 + input_len)) * g.paint.font.w, .y = y + 2, .w = 2, .h = 15 }, color.cursor, "cursor");
    try f.present();
}

// ---------------------------------------------------------------------------
// Commands

fn run(line: []const u8) void {
    const cmd = std.mem.trim(u8, line, " ");
    if (cmd.len == 0) return;
    sayf(.command, "> {s}", .{cmd});
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    const verb = it.next().?;
    const ok = dispatch(verb, &it) catch |e| blk: {
        sayf(.fault, "{s}: {s}", .{ verb, switch (e) {
            error.Transport => "not available here",
            error.NotFound => "not found",
            error.InvalidArgs => "that does not look right",
            error.Unknown => "no such command (try help)",
            else => @errorName(e),
        } });
        break :blk false;
    };
    g.log("shell_ran", .{ .command = verb, .ok = ok });
}

fn number(it: anytype) !u64 {
    const t = it.next() orelse return error.InvalidArgs;
    return std.fmt.parseUnsigned(u64, t, 10) catch error.InvalidArgs;
}

fn service(name: []const u8) !g.CPtr {
    return g.use(name) orelse error.Transport;
}

fn dispatch(verb: []const u8, it: anytype) !bool {
    const eq = std.mem.eql;
    if (eq(u8, verb, "help")) {
        say(.answer, "whoami          this instance's identity");
        say(.answer, "store           the content store's disk");
        say(.answer, "ledger          the signed record of authority");
        say(.answer, "get K / put K V the key-value store");
        say(.answer, "echo TEXT       say it back");
        say(.answer, "clear           start a fresh page");
    } else if (eq(u8, verb, "whoami")) {
        const r = try idl.call(proto.kumara.whoami, try service("kumara"), .{});
        sayf(.answer, "{s}", .{r.name.slice()});
        sayf(.answer, "key {x}", .{r.public_key.slice()[0..12]});
    } else if (eq(u8, verb, "store")) {
        const r = try idl.call(proto.tablecloth.info, try service("tablecloth"), .{});
        sayf(.answer, "{d} objects, commit {d}", .{ r.objects, r.seq });
        sayf(.answer, "{d} of {d} blocks free{s}", .{ r.free, r.blocks, if (r.locked) " (locked)" else "" });
    } else if (eq(u8, verb, "ledger")) {
        const r = try idl.call(proto.ledger.head, try service("ledger"), .{});
        sayf(.answer, "{d} entries, newest {x}", .{ r.seq, r.hash.slice()[0..@min(8, r.hash.len)] });
    } else if (eq(u8, verb, "get")) {
        const k = try number(it);
        const r = try idl.call(proto.kv.get, try service("kv"), .{ .key = k });
        if (r.found) sayf(.answer, "{d} = {d}", .{ k, r.value }) else sayf(.answer, "{d} is not set", .{k});
    } else if (eq(u8, verb, "put")) {
        const k = try number(it);
        const v = try number(it);
        _ = try idl.call(proto.kv.put, try service("kv"), .{ .key = k, .value = v });
        sayf(.answer, "{d} = {d}", .{ k, v });
    } else if (eq(u8, verb, "echo")) {
        say(.answer, it.rest());
    } else if (eq(u8, verb, "clear")) {
        n_lines = 0;
    } else return error.Unknown;
    return true;
}

// ---------------------------------------------------------------------------

pub fn main() !u16 {
    var space: g.Space = .{ .untyped = D.Slot.memory, .vspace = D.Slot.vspace, .next_slot = D.Slot.first_free };
    const sig = try space.retype(.signal, 0);
    const surf = g.use("surf") orelse return error.NoService;
    _ = idl.call(S.open, surf, .{ .title = idl.Text(32).from("shell"), .width = width, .height = height, .shown = false }) catch {
        // No screen (Surf was skipped): nothing to show, so rest.
        g.log("shell_idle", .{ .reason = "no_screen" });
        while (true) _ = g.wait(sig);
    };
    // Surf may raise the signal, nothing more.
    const raise = try space.slot();
    if (!g.invoke(D.Slot.cnode, g.abi.CNodeMethod.mint, .{ raise, sig, (g.abi.Rights{ .send = true }).bits(), 1, 0 }).ok()) return error.MintFailed;
    _ = try idl.call(S.listen, surf, .{ .signal = .{ .slot = raise } });
    say(.answer, "grain shell. type help and press enter.");
    try draw(surf);
    g.log("shell_ready", .{});
    while (true) {
        _ = g.wait(sig);
        var changed = false;
        while (true) {
            const e = try idl.call(S.next_event, surf, .{});
            switch (e.kind) {
                .none => break,
                .key => switch (e.char) {
                    '\n' => {
                        run(input[0..input_len]);
                        input_len = 0;
                        changed = true;
                    },
                    0x08 => if (input_len > 0) {
                        input_len -= 1;
                        changed = true;
                    },
                    0 => {},
                    else => |c| if (c >= ' ' and input_len < input.len) {
                        input[input_len] = c;
                        input_len += 1;
                        changed = true;
                    },
                },
                .click => if (e.element == button_clear) {
                    n_lines = 0;
                    changed = true;
                },
                .shown, .hidden => {},
            }
        }
        if (changed) try draw(surf);
    }
}
