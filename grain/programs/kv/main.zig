//! kv: a small key-value store. Every write returns what it replaced, so
//! callers (and Envoy's plans) can undo it with `restore`.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");
const idl = g.idl;
const P = proto.kv;

pub const panic = g.panic;
comptime {
    g.exportStart();
}

const capacity = 64;

const Store = struct {
    keys: [capacity]u64 = undefined,
    values: [capacity]u64 = undefined,
    used: [capacity]bool = @splat(false),

    fn find(s: *Store, key: u64) ?usize {
        for (s.used, 0..) |u, i| if (u and s.keys[i] == key) return i;
        return null;
    }

    fn set(s: *Store, key: u64, value: u64) !void {
        if (s.find(key)) |i| {
            s.values[i] = value;
            return;
        }
        for (&s.used, 0..) |*u, i| if (!u.*) {
            u.* = true;
            s.keys[i] = key;
            s.values[i] = value;
            return;
        };
        return error.Unavailable; // full
    }

    pub fn get(s: *Store, p: P.get.Params, _: idl.Caller) !P.get.Results {
        const i = s.find(p.key) orelse return .{ .value = 0, .found = false };
        return .{ .value = s.values[i], .found = true };
    }
    pub fn put(s: *Store, p: P.put.Params, _: idl.Caller) !P.put.Results {
        const before = try s.get(.{ .key = p.key }, .{ .badge = 0 });
        try s.set(p.key, p.value);
        return .{ .previous = before.value, .had = before.found };
    }
    pub fn remove(s: *Store, p: P.remove.Params, _: idl.Caller) !P.remove.Results {
        const i = s.find(p.key) orelse return .{ .previous = 0, .had = false };
        s.used[i] = false;
        return .{ .previous = s.values[i], .had = true };
    }
    pub fn restore(s: *Store, p: P.restore.Params, _: idl.Caller) !P.restore.Results {
        if (p.had) try s.set(p.key, p.previous) else if (s.find(p.key)) |i| {
            s.used[i] = false;
        }
        return .{};
    }
    pub fn count(s: *Store, _: P.count.Params, _: idl.Caller) !P.count.Results {
        var n: u64 = 0;
        for (s.used) |u| n += @intFromBool(u);
        return .{ .count = n };
    }
};

pub fn main() !u16 {
    var store: Store = .{};
    g.log("serving", .{ .capacity = capacity });
    idl.serve(P, g.provided("kv") orelse return error.NoService, &store);
}
