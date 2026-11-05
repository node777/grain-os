//! settings: the owner's settings. Four tabs:
//!   System    who this instance is, what it runs, how long it has been up
//!   Desktop   the desktop's style (desktop.v1), kept in the content store
//!   Storage   the disk: space, commits, generations, and a rollback
//!   Security  changing the passphrase (tablecloth.v1, given the current one)
//!
//! At boot it reads the saved style from the content store (which waits for
//! the passphrase) and puts the desktop in it, then waits in the dock.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");
const S = proto.surf;
const TC = proto.tablecloth;
const idl = g.idl;
const D = g.domain;
const ui = g.ui;

pub const panic = g.panic;
pub const std_options = g.std_options;
comptime {
    g.exportStart();
}

const style_name = "style";

const Settings = struct {
    desktop: ?g.CPtr,
    steward: ?g.CPtr,
    kumara: ?g.CPtr,
    ledger: ?g.CPtr,
    store: ?g.CPtr,

    tab: usize = 0,
    note: [96]u8 = undefined,
    note_len: u8 = 0,

    // System
    identity: [14]u8 = undefined,
    identity_len: u8 = 0,
    key: [16]u8 = undefined,
    system: [32]u8 = undefined,
    system_len: u8 = 0,
    closure: [16]u8 = undefined,
    harts: u8 = 0,
    uptime_us: u64 = 0,
    ledger_entries: u64 = 0,

    // Desktop
    style: proto.desktop.Style = .dusk,

    // Storage
    info: ?TC.info.Results = null,
    confirm_rollback: bool = false,

    // Security
    current: ui.Field = .{ .secret = true },
    new: ui.Field = .{ .secret = true },
    again: ui.Field = .{ .secret = true },

    fn say(s: *Settings, comptime fmt: []const u8, args: anytype) void {
        const t = std.fmt.bufPrint(&s.note, fmt, args) catch s.note[0..];
        s.note_len = @intCast(t.len);
    }

    /// Read everything the tabs show.
    fn refresh(s: *Settings) void {
        if (s.kumara) |k| if (idl.call(proto.kumara.whoami, k, .{})) |r| {
            s.identity_len = @intCast(r.name.slice().len);
            @memcpy(s.identity[0..s.identity_len], r.name.slice());
            _ = std.fmt.bufPrint(&s.key, "{x}", .{r.public_key.slice()[0..8]}) catch {};
        } else |_| {};
        if (s.steward) |st| if (idl.call(proto.steward.system, st, .{})) |r| {
            s.system_len = @intCast(r.name.slice().len);
            @memcpy(s.system[0..s.system_len], r.name.slice());
            _ = std.fmt.bufPrint(&s.closure, "{x}", .{r.closure.slice()[0..8]}) catch {};
            s.harts = r.harts;
            s.uptime_us = r.uptime_us;
        } else |_| {};
        if (s.ledger) |l| if (idl.call(proto.ledger.head, l, .{})) |r| {
            s.ledger_entries = r.seq;
        } else |_| {};
        if (s.desktop) |d| if (idl.call(proto.desktop.style, d, .{})) |r| {
            s.style = r.style;
        } else |_| {};
        if (s.store) |t| s.info = idl.call(TC.info, t, .{}) catch null;
    }

    pub fn tick(s: *Settings) void {
        s.refresh();
    }

    pub fn draw(s: *Settings, u: *ui.Ui) void {
        u.background();
        u.heading("Settings");
        if (u.tabs(&.{ "System", "Desktop", "Storage", "Security" }, &s.tab)) s.note_len = 0;
        switch (s.tab) {
            0 => s.drawSystem(u),
            1 => s.drawDesktop(u),
            2 => s.drawStorage(u),
            else => s.drawSecurity(u),
        }
        if (s.note_len > 0) {
            u.space(4);
            u.labelAs(s.note[0..s.note_len], u.theme.accent, "note");
        }
        u.end();
    }

    fn drawSystem(s: *Settings, u: *ui.Ui) void {
        var buf: [48]u8 = undefined;
        u.pair("Instance", if (s.identity_len > 0) s.identity[0..s.identity_len] else "(not unlocked yet)", 14);
        u.pair("Key", if (s.identity_len > 0) &s.key else "", 14);
        u.pair("System", s.system[0..s.system_len], 14);
        u.pair("Closure", &s.closure, 14);
        u.pair("Harts", std.fmt.bufPrint(&buf, "{d}", .{s.harts}) catch "", 14);
        const up = s.uptime_us / 1_000_000;
        u.pair("Up", std.fmt.bufPrint(&buf, "{d}h {d}m {d}s", .{ up / 3600, (up / 60) % 60, up % 60 }) catch "", 14);
        u.pair("Ledger", std.fmt.bufPrint(&buf, "{d} entries", .{s.ledger_entries}) catch "", 14);
        u.space(4);
        if (u.button("Refresh")) s.refresh();
    }

    fn drawDesktop(s: *Settings, u: *ui.Ui) void {
        u.label("Style of the desktop, its windows and the applications:");
        const hot = u.theme.button_hot;
        const cold = u.theme.button;
        if (u.buttonAs("Dusk", if (s.style == .dusk) hot else cold)) s.choose(.dusk);
        u.sameLine();
        if (u.buttonAs("Daylight", if (s.style == .daylight) hot else cold)) s.choose(.daylight);
        u.muted("Kept in the content store: the desktop comes back in it at the next boot.");
    }

    fn choose(s: *Settings, to: proto.desktop.Style) void {
        const d = s.desktop orelse return s.say("no desktop to style", .{});
        _ = idl.call(proto.desktop.set_style, d, .{ .style = to }) catch |e| return s.say("could not: {s}", .{@errorName(e)});
        s.style = to;
        if (save(s.store, to)) |_| {
            s.say("{s}, and kept for the next boot", .{@tagName(to)});
        } else |e| s.say("{s} (not kept: {s})", .{ @tagName(to), @errorName(e) });
        g.log("settings_style", .{ .style = @tagName(to) });
    }

    fn drawStorage(s: *Settings, u: *ui.Ui) void {
        const i = s.info orelse return u.muted("No content store here.");
        var buf: [64]u8 = undefined;
        const used = i.blocks - i.free;
        u.meter(@intCast(used * 1000 / @max(i.blocks, 1)), 360, std.fmt.bufPrint(&buf, "{d} of {d} MiB used", .{ used * 4 / 1024, i.blocks * 4 / 1024 }) catch "");
        u.pair("Objects", std.fmt.bufPrint(&buf, "{d}", .{i.objects}) catch "", 14);
        u.pair("Commits", std.fmt.bufPrint(&buf, "{d}", .{i.seq}) catch "", 14);
        u.pair("Generation", short(&buf, i.current.slice()), 14);
        const pending = !allZero(i.pending.slice());
        if (pending) u.pair("On trial", short(&buf, i.pending.slice()), 14);
        const previous = !allZero(i.previous.slice());
        u.pair("Previous", if (previous) short(&buf, i.previous.slice()) else "none", 14);
        u.space(4);
        if (!previous) return;
        if (!s.confirm_rollback) {
            if (u.button("Roll back to the previous generation")) {
                s.confirm_rollback = true;
                s.say("Click again to boot the previous generation next.", .{});
            }
        } else {
            if (u.buttonAs("Yes, roll back", u.theme.danger)) {
                s.confirm_rollback = false;
                if (idl.call(TC.rollback, s.store.?, .{})) |_| {
                    s.say("The previous generation boots next, on trial.", .{});
                } else |e| s.say("rollback: {s}", .{@errorName(e)});
                s.refresh();
            }
            u.sameLine();
            if (u.button("Cancel")) {
                s.confirm_rollback = false;
                s.note_len = 0;
            }
        }
    }

    fn drawSecurity(s: *Settings, u: *ui.Ui) void {
        u.label("Change the passphrase that opens the content store:");
        u.muted("Current passphrase");
        const a = u.field(&s.current, 320, "");
        u.muted("New passphrase");
        const b = u.field(&s.new, 320, "");
        u.muted("The new one again");
        const c = u.field(&s.again, 320, "");
        u.space(4);
        if (u.button("Change passphrase") or a == .submitted or b == .submitted or c == .submitted) s.changePassphrase();
    }

    fn changePassphrase(s: *Settings) void {
        defer {
            std.crypto.secureZero(u8, &s.current.buf);
            std.crypto.secureZero(u8, &s.new.buf);
            std.crypto.secureZero(u8, &s.again.buf);
            s.current.clear();
            s.new.clear();
            s.again.clear();
        }
        const store = s.store orelse return s.say("No content store here.", .{});
        if (s.new.len == 0) return s.say("The new passphrase is empty.", .{});
        if (!std.mem.eql(u8, s.new.text(), s.again.text())) return s.say("The new passphrases differ.", .{});
        s.say("Changing...", .{});
        if (idl.call(TC.passphrase, store, .{ .current = idl.Text(96).from(s.current.text()), .new = idl.Text(96).from(s.new.text()) })) |_| {
            s.say("Passphrase changed: use the new one from the next boot.", .{});
            g.log("settings_passphrase", .{ .changed = true });
        } else |e| {
            s.say("{s}", .{if (e == error.InvalidArgs) "That is not the current passphrase." else @errorName(e)});
            g.log("settings_passphrase", .{ .changed = false });
        }
    }
};

fn short(buf: []u8, h: []const u8) []const u8 {
    if (allZero(h)) return "none";
    return std.fmt.bufPrint(buf, "{x}", .{h[0..8]}) catch "";
}

fn allZero(b: []const u8) bool {
    for (b) |x| if (x != 0) return false;
    return true;
}

/// Keep the style in the content store, under this domain's name "style".
fn save(store: ?g.CPtr, style: proto.desktop.Style) !void {
    const t = store orelse return error.Unavailable;
    const put = try idl.call(TC.put, t, .{ .data = idl.Bytes(TC.chunk).from(@tagName(style)) });
    _ = try idl.call(TC.bind, t, .{ .name = TC.NameText.from(style_name), .hash = put.hash, .secret = false, .tip = true });
    _ = try idl.call(TC.commit, t, .{});
}

/// The style kept by `save`, if any.
fn saved(store: ?g.CPtr) ?proto.desktop.Style {
    const t = store orelse return null;
    const l = idl.call(TC.lookup, t, .{ .name = TC.NameText.from(style_name), .secret = false }) catch return null;
    if (!l.found) return null;
    const r = idl.call(TC.read, t, .{ .hash = l.hash, .offset = 0 }) catch return null;
    return std.meta.stringToEnum(proto.desktop.Style, r.data.slice());
}

var settings: Settings = undefined;

pub fn main() !u16 {
    var space: g.Space = .{ .untyped = D.Slot.memory, .vspace = D.Slot.vspace, .next_slot = D.Slot.first_free };
    settings = .{
        .desktop = g.use("desktop"),
        .steward = g.use("steward"),
        .kumara = g.use("kumara"),
        .ledger = g.use("ledger"),
        .store = g.use("tablecloth"),
    };
    var app = S.App.open(&space, "settings", 560, 420, .{ .min_width = 500, .min_height = 380 }) catch |e| {
        g.log("settings_idle", .{ .reason = "no_screen", .err = @errorName(e) });
        const sig = try space.retype(.signal, 0);
        while (true) _ = g.wait(sig);
    };
    // The kept style (this waits for the store to be unlocked).
    if (saved(settings.store)) |st| {
        if (settings.desktop) |d| _ = idl.call(proto.desktop.set_style, d, .{ .style = st }) catch {};
        g.log("settings_restored", .{ .style = @tagName(st) });
    }
    settings.refresh();
    app.every(2000);
    g.log("settings_ready", .{});
    try app.run(&settings);
}
