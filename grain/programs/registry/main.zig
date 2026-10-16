//! registry: serves the descriptor of every protocol in the system by id,
//! so any holder of a capability can find out what it speaks and how to
//! call it. The descriptors are generated from grain/proto at compile time.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");
const idl = g.idl;

pub const panic = g.panic;
comptime {
    g.exportStart();
}

const Entry = struct { id: u64, name: []const u8, descriptor: []const u8 };

const entries = blk: {
    var list: [proto.all.len]Entry = undefined;
    for (proto.all, 0..) |P, i| list[i] = .{ .id = idl.id(P), .name = idl.fullName(P), .descriptor = idl.descriptor(P) };
    break :blk list;
};

fn find(id: u64) ?Entry {
    for (entries) |e| if (e.id == id) return e;
    return null;
}

const Registry = struct {
    pub fn count(_: *Registry, _: proto.registry.count.Params, _: idl.Caller) !proto.registry.count.Results {
        return .{ .count = entries.len };
    }
    pub fn nth(_: *Registry, p: proto.registry.nth.Params, _: idl.Caller) !proto.registry.nth.Results {
        if (p.index >= entries.len) return error.NotFound;
        const e = entries[@intCast(p.index)];
        return .{ .id = e.id, .name = idl.Bytes(24).from(e.name) };
    }
    pub fn lookup(_: *Registry, p: proto.registry.lookup.Params, _: idl.Caller) !proto.registry.lookup.Results {
        const e = find(p.id) orelse return .{ .name = .{}, .found = false };
        return .{ .name = idl.Bytes(24).from(e.name), .found = true };
    }
    pub fn describe(_: *Registry, p: proto.registry.describe.Params, _: idl.Caller) !proto.registry.describe.Results {
        const e = find(p.id) orelse return error.NotFound;
        const d = e.descriptor;
        const start: usize = @intCast(@min(p.offset, d.len));
        return .{ .total = d.len, .chunk = idl.Bytes(24).from(d[start..@min(d.len, start + 24)]) };
    }
};

pub fn main() !u16 {
    g.log("serving", .{ .protocols = entries.len });
    var r: Registry = .{};
    idl.serve(proto.registry, g.provided("registry") orelse return error.NoService, &r);
}
