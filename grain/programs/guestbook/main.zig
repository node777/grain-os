//! guestbook: the first hosted application. It knows nothing of networks:
//! a visitor from another instance reaches it through Comlink, on a lease
//! its owner granted, and it sees Comlink as the caller.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");
const P = proto.guestbook;
const idl = g.idl;

pub const panic = g.panic;
pub const std_options = g.std_options;
comptime {
    g.exportStart();
}

const Line = struct { text: [120]u8 = undefined, len: u8 = 0, by: [23]u8 = undefined, by_len: u8 = 0 };
var lines: [64]Line = undefined;
var n_lines: u32 = 0;

const Server = struct {
    pub fn sign(_: *Server, p: P.sign.Params, c: idl.Caller) !P.sign.Results {
        if (n_lines == lines.len) return error.Unavailable;
        const by = if (c.badge == 0) "steward" else if (c.badge == g.domain.agent_badge) "agent" else g.env().clientName(c.badge) orelse "unknown";
        const l = &lines[n_lines];
        const t = p.text.slice();
        l.len = @intCast(t.len);
        @memcpy(l.text[0..t.len], t);
        l.by_len = @intCast(@min(by.len, l.by.len));
        @memcpy(l.by[0..l.by_len], by[0..l.by_len]);
        g.log("guestbook_signed", .{ .entry = n_lines, .by = by, .text = t });
        n_lines += 1;
        return .{ .entry = n_lines - 1 };
    }

    pub fn count(_: *Server, _: P.count.Params, _: idl.Caller) !P.count.Results {
        return .{ .count = n_lines };
    }

    pub fn read(_: *Server, p: P.read.Params, _: idl.Caller) !P.read.Results {
        if (p.entry >= n_lines) return error.NotFound;
        const l = &lines[p.entry];
        return .{ .text = idl.Text(120).from(l.text[0..l.len]), .by = idl.Text(23).from(l.by[0..l.by_len]) };
    }
};

pub fn main() !u16 {
    var s: Server = .{};
    idl.serve(P, g.provided("guestbook") orelse return error.NoService, &s);
}
