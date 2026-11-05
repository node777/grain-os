//! taskman: the task manager. What Steward runs, as a table the owner can
//! read at a glance: each domain's status, its share of a hart over the
//! last second, the CPU time charged to it, its restarts, budget and
//! memory; and the owner's two levers, restart and stop (steward.v1).
//!
//! It refreshes once a second while its window is shown, and is drawn with
//! grain/lib/ui.zig, so an agent reading the scene reads the same table.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");
const S = proto.surf;
const SP = proto.steward;
const idl = g.idl;
const D = g.domain;
const ui = g.ui;

pub const panic = g.panic;
pub const std_options = g.std_options;
comptime {
    g.exportStart();
}

const max_rows = 32;

const Row = struct {
    name: [24]u8 = undefined,
    name_len: u8 = 0,
    program: [24]u8 = undefined,
    program_len: u8 = 0,
    kind: SP.Kind = .service,
    status: SP.Status = .not_started,
    restarts: u32 = 0,
    exit_code: u16 = 0,
    priority: u8 = 0,
    hart: u8 = 0,
    budget_us: u32 = 0,
    period_us: u32 = 0,
    memory_kib: u32 = 0,
    cpu_us: u64 = 0,
    /// Share of one hart over the last refresh, in tenths of a percent.
    load: u32 = 0,

    fn nameS(r: *const Row) []const u8 {
        return r.name[0..r.name_len];
    }
};

const Tasks = struct {
    steward: g.CPtr,
    rows: [max_rows]Row = @splat(.{}),
    n: usize = 0,
    system: [32]u8 = undefined,
    system_len: u8 = 0,
    harts: u8 = 0,
    uptime_us: u64 = 0,
    table: ui.TableState = .{},
    note: [96]u8 = undefined,
    note_len: u8 = 0,

    fn say(t: *Tasks, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&t.note, fmt, args) catch t.note[0..];
        t.note_len = @intCast(s.len);
    }

    /// Ask Steward how everything stands.
    fn refresh(t: *Tasks) void {
        const sys = idl.call(SP.system, t.steward, .{}) catch |e| {
            t.say("steward: {s}", .{@errorName(e)});
            return;
        };
        const elapsed = sys.uptime_us -| t.uptime_us;
        t.uptime_us = sys.uptime_us;
        t.harts = sys.harts;
        t.system_len = @intCast(sys.name.slice().len);
        @memcpy(t.system[0..t.system_len], sys.name.slice());
        t.n = @min(sys.domains, max_rows);
        for (t.rows[0..t.n], 0..) |*r, i| {
            const d = idl.call(SP.domain, t.steward, .{ .index = @intCast(i) }) catch continue;
            const before = r.cpu_us;
            const same = r.name_len == d.name.slice().len;
            r.name_len = @intCast(d.name.slice().len);
            @memcpy(r.name[0..r.name_len], d.name.slice());
            r.program_len = @intCast(d.program.slice().len);
            @memcpy(r.program[0..r.program_len], d.program.slice());
            r.kind = d.kind;
            r.status = d.status;
            r.restarts = d.restarts;
            r.exit_code = d.exit_code;
            r.priority = d.priority;
            r.hart = d.hart;
            r.budget_us = d.budget_us;
            r.period_us = d.period_us;
            r.memory_kib = d.memory_kib;
            r.cpu_us = d.cpu_us;
            // A rebuild starts the count again: no share for that second.
            r.load = if (same and elapsed > 0 and d.cpu_us >= before) @intCast(@min(1000, (d.cpu_us - before) * 1000 / elapsed)) else 0;
        }
    }

    pub fn tick(t: *Tasks) void {
        t.refresh();
    }

    pub fn cell(t: *Tasks, row: usize, col: usize, buf: []u8) []const u8 {
        const r = &t.rows[row];
        return switch (col) {
            0 => r.nameS(),
            1 => switch (r.status) {
                .exited => std.fmt.bufPrint(buf, "exited {d}", .{r.exit_code}) catch "",
                .not_started => "waiting",
                else => @tagName(r.status),
            },
            2 => std.fmt.bufPrint(buf, "{d}.{d}%", .{ r.load / 10, r.load % 10 }) catch "",
            3 => duration(buf, r.cpu_us),
            4 => std.fmt.bufPrint(buf, "{d}", .{r.restarts}) catch "",
            5 => std.fmt.bufPrint(buf, "{d}", .{r.hart}) catch "",
            6 => std.fmt.bufPrint(buf, "{d}%", .{@as(u64, r.budget_us) * 100 / @max(r.period_us, 1)}) catch "",
            7 => kib(buf, r.memory_kib),
            else => "",
        };
    }

    pub fn draw(t: *Tasks, u: *ui.Ui) void {
        u.background();
        u.heading("Tasks");
        var line: [96]u8 = undefined;
        var running: usize = 0;
        for (t.rows[0..t.n]) |*r| running += @intFromBool(r.status == .running);
        var up: [24]u8 = undefined;
        u.muted(std.fmt.bufPrint(&line, "{s} - {d} harts - up {s} - {d} of {d} domains running", .{ t.system[0..t.system_len], t.harts, duration(&up, t.uptime_us), running, t.n }) catch "");
        const visible: usize = @intCast(@max(3, @divTrunc(u.height - u.y - 4 * ui.button_h - 3 * ui.pad, ui.line_h)));
        _ = u.table(&.{
            .{ .title = "domain", .chars = 11 },
            .{ .title = "status", .chars = 9 },
            .{ .title = "cpu", .chars = 6, .right = true },
            .{ .title = "time", .chars = 7, .right = true },
            .{ .title = "rs", .chars = 2, .right = true },
            .{ .title = "hart", .chars = 4, .right = true },
            .{ .title = "budget", .chars = 6, .right = true },
            .{ .title = "memory", .chars = 7, .right = true },
        }, t.n, visible, &t.table, t);
        if (t.table.selected) |sel| if (sel < t.n) {
            const r = &t.rows[sel];
            u.labelf("{s}: {s} ({s}), priority {d}, {d} us per {d} ms", .{ r.nameS(), r.program[0..r.program_len], @tagName(r.kind), r.priority, r.budget_us, r.period_us / 1000 });
            if (r.status != .skipped and u.button("Restart")) t.act(.restart, sel);
            if (r.status == .running) {
                u.sameLine();
                if (u.buttonAs("Stop", u.theme.danger)) t.act(.stop, sel);
            }
        } else {} else u.muted("Select a domain to restart or stop it.");
        if (t.note_len > 0) u.labelAs(t.note[0..t.note_len], u.theme.accent, "note");
        u.end();
    }

    fn act(t: *Tasks, what: enum { restart, stop }, index: usize) void {
        const r = &t.rows[index];
        var name: [24]u8 = undefined;
        const n = r.nameS();
        @memcpy(name[0..n.len], n);
        const result: idl.CallError!void = switch (what) {
            .restart => if (idl.call(SP.restart, t.steward, .{ .index = @intCast(index) })) |_| {} else |e| e,
            .stop => if (idl.call(SP.stop, t.steward, .{ .index = @intCast(index) })) |_| {} else |e| e,
        };
        if (result) |_| {
            t.say("{s}: {s}", .{ name[0..n.len], if (what == .restart) "restarted" else "stopped" });
        } else |e| t.say("{s}: {s} failed ({s})", .{ name[0..n.len], @tagName(what), @errorName(e) });
        g.log("taskman_action", .{ .action = @tagName(what), .domain = name[0..n.len], .ok = if (result) |_| true else |_| false });
        t.refresh();
    }
};

/// "1.25s", "3m 20s", "2h 5m".
fn duration(buf: []u8, us: u64) []const u8 {
    const s = us / 1_000_000;
    if (s < 60) return std.fmt.bufPrint(buf, "{d}.{d:0>2}s", .{ s, (us / 10_000) % 100 }) catch "";
    if (s < 3600) return std.fmt.bufPrint(buf, "{d}m {d}s", .{ s / 60, s % 60 }) catch "";
    return std.fmt.bufPrint(buf, "{d}h {d}m", .{ s / 3600, (s / 60) % 60 }) catch "";
}

fn kib(buf: []u8, k: u32) []const u8 {
    if (k >= 1024) return std.fmt.bufPrint(buf, "{d} MiB", .{k / 1024}) catch "";
    return std.fmt.bufPrint(buf, "{d} KiB", .{k}) catch "";
}

var tasks: Tasks = undefined;

pub fn main() !u16 {
    var space: g.Space = .{ .untyped = D.Slot.memory, .vspace = D.Slot.vspace, .next_slot = D.Slot.first_free };
    tasks = .{ .steward = g.use("steward") orelse return error.NoService };
    var app = S.App.open(&space, "tasks", 640, 440, .{ .min_width = 620, .min_height = 300 }) catch |e| {
        g.log("taskman_idle", .{ .reason = "no_screen", .err = @errorName(e) });
        const sig = try space.retype(.signal, 0);
        while (true) _ = g.wait(sig);
    };
    tasks.refresh();
    app.every(1000);
    g.log("taskman_ready", .{ .domains = tasks.n });
    try app.run(&tasks);
}
