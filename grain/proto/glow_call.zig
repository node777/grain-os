//! Glow's world inside a domain: the services this domain uses (its
//! manifest's `uses`), each callable from Glow by its manifest name, through
//! the IDL. Arguments are checked against the method's parameters and
//! converted (integers in range, text within its length, enums by name);
//! results come back as records.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto.zig");
const glow = g.glow;
const idl = g.idl;
const D = g.domain;

var token: u8 = 0;

/// What this domain holds, for an Interp.
pub fn world() glow.World {
    return .{ .ctx = &token, .has = has, .call = call, .list = list, .describe = describe };
}

fn find(name: []const u8) ?*const D.Service {
    const e = g.env();
    for (e.uses[0..e.use_count]) |*sv| if (std.mem.eql(u8, D.nameOf(&sv.name), name)) return sv;
    return null;
}

fn has(_: *anyopaque, cap: []const u8) bool {
    return find(cap) != null;
}

fn list(_: *anyopaque, out: glow.Out) void {
    const e = g.env();
    for (e.uses[0..e.use_count]) |*sv| out.print("{s}  {s}", .{ D.nameOf(&sv.name), D.nameOf(&sv.protocol) });
}

fn describe(_: *anyopaque, cap: []const u8, out: glow.Out) bool {
    const sv = find(cap) orelse return false;
    const pname = D.nameOf(&sv.protocol);
    inline for (proto.all) |P| if (std.mem.eql(u8, idl.fullName(P), pname)) {
        out.print("{s}: {s}", .{ pname, P.doc });
        inline for (comptime idl.methodNames(P)) |n| {
            const M = @field(P, n);
            out.print("  {s}.{s} {s}-> {s}", .{ cap, n, comptime params(M.Params), comptime params(M.Results) });
        }
        return true;
    };
    out.print("{s}: (not a protocol Glow knows)", .{pname});
    return true;
}

/// "key=u64 value=u64 " for a describe line.
fn params(comptime T: type) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var s: []const u8 = "";
        for (std.meta.fieldNames(T)) |f| s = s ++ f ++ "=" ++ idl.typeName(@FieldType(T, f)) ++ " ";
        return if (s.len == 0) "() " else s;
    }
}

fn call(_: *anyopaque, gpa: std.mem.Allocator, cap: []const u8, method: []const u8, args: []const glow.Field, from: ?glow.Value, why: *glow.Why) error{Failed}!glow.Value {
    const sv = find(cap) orelse {
        why.set("you hold no capability named '{s}'", .{cap});
        return error.Failed;
    };
    const pname = D.nameOf(&sv.protocol);
    inline for (proto.all) |P| if (std.mem.eql(u8, idl.fullName(P), pname)) {
        inline for (comptime idl.methodNames(P)) |n| if (std.mem.eql(u8, n, method)) {
            const M = @field(P, n);
            const p = try build(M.Params, cap, n, args, from, why);
            const r = idl.call(M, sv.slot, p) catch |e| {
                why.set("{s}.{s}: {s}", .{ cap, n, switch (e) {
                    error.Transport => "not reachable (its provider is down, or a lease ran out)",
                    error.NotFound => "not found",
                    error.InvalidArgs => "refused these arguments",
                    error.Unavailable => "not available now (or not to you)",
                    error.UnknownMethod => "unknown to the provider",
                    error.Failed => "failed",
                } });
                return error.Failed;
            };
            return toValue(gpa, M.Results, r) catch {
                why.set("out of memory", .{});
                return error.Failed;
            };
        };
        why.set("{s} ({s}) has no method '{s}' (describe {s})", .{ cap, pname, method, cap });
        return error.Failed;
    };
    why.set("{s} speaks {s}, which Glow does not know", .{ cap, pname });
    return error.Failed;
}

fn arg(args: []const glow.Field, from: ?glow.Value, name: []const u8) ?glow.Value {
    for (args) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
    if (from) |f| return f.field(name);
    return null;
}

/// A method's parameters from Glow values: the named arguments, then the
/// fields of what came down a pipe.
fn build(comptime T: type, cap: []const u8, method: []const u8, args: []const glow.Field, from: ?glow.Value, why: *glow.Why) error{Failed}!T {
    const names = comptime std.meta.fieldNames(T);
    for (args) |a| {
        const known = for (names) |f| {
            if (std.mem.eql(u8, f, a.name)) break true;
        } else false;
        if (!known) {
            why.set("{s}.{s} has no parameter '{s}' (it takes {s})", .{ cap, method, a.name, comptime params(T) });
            return error.Failed;
        }
    }
    var v: T = undefined;
    inline for (names) |f| {
        const F = @FieldType(T, f);
        if (@typeInfo(F) == .@"struct" and @hasDecl(F, "idl_cap")) {
            why.set("{s}.{s} takes a capability ({s}), which Glow cannot pass", .{ cap, method, f });
            return error.Failed;
        }
        const x = arg(args, from, f) orelse {
            why.set("{s}.{s} needs {s} ({s})", .{ cap, method, f, comptime idl.typeName(F) });
            return error.Failed;
        };
        const bad = struct {
            fn say(w: *glow.Why, c: []const u8, m: []const u8, field: []const u8, want: []const u8) error{Failed} {
                w.set("{s}.{s}: {s} must be {s}", .{ c, m, field, want });
                return error.Failed;
            }
        }.say;
        const want = comptime idl.typeName(F);
        if (@typeInfo(F) == .@"struct" and @hasDecl(F, "idl_bytes")) {
            const data = switch (x) {
                .text => |t| t,
                .bytes => |b| b,
                else => return bad(why, cap, method, f, want),
            };
            if (data.len > F.idl_bytes) return bad(why, cap, method, f, want);
            @field(v, f) = F.from(data);
        } else switch (@typeInfo(F)) {
            .int => {
                if (x != .int) return bad(why, cap, method, f, want);
                @field(v, f) = std.math.cast(F, x.int) orelse return bad(why, cap, method, f, want);
            },
            .bool => {
                if (x != .boolean) return bad(why, cap, method, f, want);
                @field(v, f) = x.boolean;
            },
            .@"enum" => {
                if (x != .text) return bad(why, cap, method, f, want);
                @field(v, f) = std.meta.stringToEnum(F, x.text) orelse return bad(why, cap, method, f, want);
            },
            else => comptime unreachable,
        }
    }
    return v;
}

fn toValue(gpa: std.mem.Allocator, comptime T: type, v: T) error{OutOfMemory}!glow.Value {
    const names = comptime std.meta.fieldNames(T);
    const fields = try gpa.alloc(glow.Field, names.len);
    inline for (names, 0..) |f, i| {
        const F = @FieldType(T, f);
        const x = @field(v, f);
        fields[i] = .{ .name = f, .value = if (@typeInfo(F) == .@"struct" and @hasDecl(F, "idl_bytes"))
            (if (F.idl_text) .{ .text = try gpa.dupe(u8, x.slice()) } else .{ .bytes = try gpa.dupe(u8, x.slice()) })
        else switch (@typeInfo(F)) {
            .int => .{ .int = x },
            .bool => .{ .boolean = x },
            .@"enum" => .{ .text = @tagName(x) },
            else => comptime unreachable,
        } };
    }
    return .{ .record = fields };
}
