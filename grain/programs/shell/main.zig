//! shell: the first application on the desktop. The owner types a command,
//! presses enter, and the answer appears: who this instance is, what the
//! store holds, how long the Ledger is, keys in the key-value store.
//!
//! It is drawn with grain/lib/ui.zig in a window the owner may resize, as
//! brushstrokes (surf.v1), so every line it shows is an element an agent can
//! read back through scene.v1.
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

const ui = g.ui;

const width = 640;
const height = 404;
const line_h = 20;

const color = struct {
    const command: u32 = 0xb8a6e0;
    const answer: u32 = 0xe9dfcf;
    const fault: u32 = 0xf0a07a;
};

const max_cols = 120;
const Kind = enum { command, answer, fault };
const Line = struct { kind: Kind = .answer, text: [max_cols]u8 = undefined, len: u8 = 0 };

/// What has been said, oldest first; the window shows as much of the end
/// as fits.
var lines: [64]Line = @splat(.{});
var n_lines: usize = 0;

fn say(kind: Kind, text: []const u8) void {
    if (n_lines == lines.len) {
        std.mem.copyForwards(Line, lines[0 .. lines.len - 1], lines[1..lines.len]);
        n_lines -= 1;
    }
    const l = &lines[n_lines];
    l.kind = kind;
    l.len = @intCast(@min(text.len, max_cols));
    @memcpy(l.text[0..l.len], text[0..l.len]);
    n_lines += 1;
}

fn sayf(kind: Kind, comptime fmt: []const u8, args: anytype) void {
    var buf: [max_cols]u8 = undefined;
    say(kind, std.fmt.bufPrint(&buf, fmt, args) catch buf[0..]);
}

const Shell = struct {
    input: ui.Field = .{},

    pub fn draw(sh: *Shell, u: *ui.Ui) void {
        u.background();
        u.moveTo(u.width - ui.pad - 64, ui.pad - 4);
        if (u.button("clear")) n_lines = 0;
        u.space(26);
        // As many of the newest lines as fit above the prompt.
        const room: usize = @intCast(@max(1, @divTrunc(u.height - u.y - ui.button_h - 2 * ui.pad, line_h)));
        const first = n_lines -| room;
        for (lines[first..n_lines]) |*l| {
            const c = switch (l.kind) {
                .command => color.command,
                .answer => color.answer,
                .fault => color.fault,
            };
            u.labelAs(l.text[0..l.len], c, @tagName(l.kind));
            u.y -= ui.gap - (line_h - ui.char_h);
        }
        const y = @max(u.y, u.height - ui.button_h - ui.pad);
        u.moveTo(u.left, y + @divTrunc(ui.button_h - ui.char_h, 2));
        u.labelAs(">", u.theme.accent, "prompt");
        u.moveTo(u.left + 2 * ui.char_w, y);
        u.focusNext();
        if (u.field(&sh.input, u.right - u.left - 2 * ui.char_w, "type a command (help)") == .submitted) {
            run(sh.input.text());
            sh.input.clear();
        }
        u.end();
    }
};

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
    var app = S.App.open(&space, "shell", width, height, .{ .min_width = 360, .min_height = 200 }) catch |e| {
        // No screen (Surf was skipped): nothing to show, so rest.
        g.log("shell_idle", .{ .reason = "no_screen", .err = @errorName(e) });
        const sig = try space.retype(.signal, 0);
        while (true) _ = g.wait(sig);
    };
    say(.answer, "grain shell. type help and press enter.");
    var sh: Shell = .{};
    g.log("shell_ready", .{});
    try app.run(&sh);
}
