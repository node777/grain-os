//! Structured kernel log.
//!
//! Every line the kernel prints for machines starts with `@caravan`, then an
//! event name, then `key=value` fields:
//!
//!     @caravan boot hart=0 dtb=0x87e00000
//!     @caravan test name=timer_interrupt result=pass
//!
//! Humans can read it; harnesses and AI agents can parse it without guessing.
//! Firmware and other noise on the same serial line never starts with the
//! prefix, so filtering is a single `startsWith`.
const std = @import("std");

pub const prefix = "@caravan";

/// Wrap an integer to print it as 0x-prefixed hex.
pub fn Hex(comptime T: type) type {
    return struct { value: T };
}
pub fn hex(value: anytype) Hex(@TypeOf(value)) {
    return .{ .value = value };
}

pub const Error = error{NoSpaceLeft};

/// Format one kernel record (no trailing newline) into `buf`.
pub fn format(buf: []u8, comptime event: []const u8, fields: anytype) Error![]u8 {
    return formatPrefixed(prefix, buf, event, fields);
}

/// Format a record with another source prefix (user programs use `@grain`).
pub fn formatPrefixed(comptime source: []const u8, buf: []u8, comptime event: []const u8, fields: anytype) Error![]u8 {
    comptime validateName(event);
    var len: usize = 0;
    len += (try std.fmt.bufPrint(buf[len..], source ++ " " ++ event, .{})).len;
    inline for (comptime std.meta.fieldNames(@TypeOf(fields))) |name| {
        comptime validateName(name);
        len += (try std.fmt.bufPrint(buf[len..], " " ++ name ++ "=", .{})).len;
        len += (try formatValue(buf[len..], @field(fields, name))).len;
    }
    return buf[0..len];
}

/// Format only the ` k=v` fields of a record (for callers that write the
/// prefix and event themselves).
pub fn formatFields(buf: []u8, fields: anytype) Error![]u8 {
    var len: usize = 0;
    inline for (comptime std.meta.fieldNames(@TypeOf(fields))) |name| {
        comptime validateName(name);
        len += (try std.fmt.bufPrint(buf[len..], " " ++ name ++ "=", .{})).len;
        len += (try formatValue(buf[len..], @field(fields, name))).len;
    }
    return buf[0..len];
}

/// Format one value as it appears after `=` in a record.
pub fn formatValuePublic(buf: []u8, value: anytype) Error![]u8 {
    return formatValue(buf, value);
}

fn formatValue(buf: []u8, value: anytype) Error![]u8 {
    const T = @TypeOf(value);
    if (comptime isHex(T)) return std.fmt.bufPrint(buf, "0x{x}", .{value.value});
    return switch (@typeInfo(T)) {
        .int, .comptime_int => std.fmt.bufPrint(buf, "{d}", .{value}),
        .bool => std.fmt.bufPrint(buf, "{s}", .{if (value) "true" else "false"}),
        .@"enum", .enum_literal => std.fmt.bufPrint(buf, "{s}", .{@tagName(value)}),
        .pointer => formatString(buf, value),
        else => @compileError("klog: unsupported field type " ++ @typeName(T)),
    };
}

/// Strings print bare when they are a single token, otherwise double-quoted
/// with `"` and `\\` escaped, so a value never splits a record.
fn formatString(buf: []u8, value: []const u8) Error![]u8 {
    const bare = value.len > 0 and for (value) |c| {
        if (c <= ' ' or c == '"' or c == '=' or c == '\\' or c >= 0x7f) break false;
    } else true;
    if (bare) return std.fmt.bufPrint(buf, "{s}", .{value});
    var len: usize = 0;
    if (buf.len < 2) return error.NoSpaceLeft;
    buf[len] = '"';
    len += 1;
    for (value) |c| {
        const esc = c == '"' or c == '\\';
        const printable = c >= ' ' and c < 0x7f;
        const need: usize = if (esc) 2 else if (printable) 1 else 4;
        if (len + need + 1 > buf.len) return error.NoSpaceLeft;
        if (esc) {
            buf[len] = '\\';
            buf[len + 1] = c;
        } else if (printable) {
            buf[len] = c;
        } else {
            _ = std.fmt.bufPrint(buf[len..][0..4], "\\x{x:0>2}", .{c}) catch unreachable;
        }
        len += need;
    }
    buf[len] = '"';
    return buf[0 .. len + 1];
}

fn isHex(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "value") and
        T == Hex(@FieldType(T, "value"));
}

/// Event and field names are restricted to [a-z0-9_] so records stay trivially
/// parseable; this is enforced at compile time.
fn validateName(comptime name: []const u8) void {
    if (name.len == 0) @compileError("klog: empty name");
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '_' => {},
        else => @compileError("klog: invalid character in name '" ++ name ++ "'"),
    };
}

test "format renders event and typed fields" {
    var buf: [128]u8 = undefined;
    const line = try format(&buf, "boot", .{ .hart = 0, .dtb = hex(@as(u64, 0x87e00000)), .smp = false, .arch = .riscv64 });
    try std.testing.expectEqualStrings("@caravan boot hart=0 dtb=0x87e00000 smp=false arch=riscv64", line);
}

test "format with no fields and string values" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("@caravan halt", try format(&buf, "halt", .{}));
    try std.testing.expectEqualStrings(
        "@caravan test name=timer result=pass",
        try format(&buf, "test", .{ .name = "timer", .result = .pass }),
    );
}

test "format quotes strings that are not a single token" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings(
        \\@caravan panic msg="index out of bounds: \"x\"\x0a"
    , try format(&buf, "panic", .{ .msg = "index out of bounds: \"x\"\n" }));
    try std.testing.expectEqualStrings("@caravan note s=\"\"", try format(&buf, "note", .{ .s = "" }));
}

test "format reports a buffer that is too small" {
    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, format(&buf, "boot", .{ .hart = 0 }));
}
