//! Brix: the declaring language.
//!
//! A `.brix` file says what a system is made of and how the parts fit. It
//! evaluates to plain data, shaped by a Zig type (for manifests,
//! `schema.Manifest`), which the manifest validator then checks. Brix adds
//! nothing the data can't hold: it is a friendlier way to write it.
//!
//!     # The development system.
//!     name = grain-dev
//!     halt_when_tasks_finish
//!
//!     template driver {
//!         priority = 200
//!         budget = 1ms
//!         period = 10ms
//!         restart = on_fault
//!     }
//!
//!     domain console like driver {
//!         program = virtio_console
//!         device port { virtio = 3 }
//!         provides console { protocol = console.v1 }
//!     }
//!
//! The rules, all of them:
//!
//!   - `key = value` sets a field. A line with just `key` sets a bool to true.
//!   - Values: numbers (`200`, `1_000`, `0x10`), numbers with a unit (`1ms`,
//!     `4s`, `250us`, `128KiB`, `2MiB`), `"strings"`, bare words (`on_fault`,
//!     `console.v1`, `grain-dev`: a string or an enum tag, as the field
//!     needs), lists `[a, b]` and records `{ k = v, k = v }`.
//!   - A unit picks the field: `budget = 1ms` sets `budget_us` to 1000.
//!     Conversions must be exact. Writing the full name (`budget_us = 1000`)
//!     works too.
//!   - `word label { ... }` is a block. If the type has a list field `words`
//!     (or `word`), the block adds one element whose `name` is the label
//!     (`device port {}` adds to `devices`). If it has a record field `word`,
//!     the block fills it (`agent {}`).
//!   - `template t { ... }` (top level) declares entries to reuse;
//!     `domain x like t, u { ... }` applies t, then u, then its own body.
//!     A later layer overrides an earlier one; setting a field twice in one
//!     body is an error.
//!   - `#` starts a comment. Newlines or commas separate entries.
//!
//! Evaluation is total and deterministic: no I/O, no recursion, no clock.
//! Every error names a line and column, and says how to fix it.
const std = @import("std");

pub const Pos = struct { line: u32 = 1, col: u32 = 1 };

pub const Diagnostic = struct {
    pos: Pos = .{},
    msg: []const u8 = "",
};

pub const Error = error{ Invalid, OutOfMemory };

pub const Unit = enum {
    none,
    us,
    ms,
    s,
    b,
    kib,
    mib,

    const Dim = enum { none, time, size };

    fn dim(u: Unit) Dim {
        return switch (u) {
            .none => .none,
            .us, .ms, .s => .time,
            .b, .kib, .mib => .size,
        };
    }

    /// In microseconds or bytes.
    fn factor(u: Unit) u64 {
        return switch (u) {
            .none, .us, .b => 1,
            .ms => 1_000,
            .s => 1_000_000,
            .kib => 1024,
            .mib => 1024 * 1024,
        };
    }

    fn spelling(u: Unit) []const u8 {
        return switch (u) {
            .none => "",
            .us => "us",
            .ms => "ms",
            .s => "s",
            .b => "B",
            .kib => "KiB",
            .mib => "MiB",
        };
    }

    const suffixes = [_]struct { []const u8, Unit }{
        .{ "us", .us }, .{ "ms", .ms },   .{ "s", .s },
        .{ "B", .b },   .{ "KiB", .kib }, .{ "MiB", .mib },
    };

    /// The unit a field name ends in: `budget_us` → us.
    const field_suffixes = [_]struct { []const u8, Unit }{
        .{ "_us", .us },   .{ "_ms", .ms },   .{ "_s", .s },
        .{ "_bytes", .b }, .{ "_kib", .kib }, .{ "_mib", .mib },
    };

    fn ofFieldName(name: []const u8) Unit {
        for (field_suffixes) |fs| if (std.mem.endsWith(u8, name, fs[0])) return fs[1];
        return .none;
    }
};

// ---------------------------------------------------------------------------
// Syntax

pub const Node = struct {
    pos: Pos,
    v: union(enum) {
        int: struct { n: u64, unit: Unit },
        string: []const u8,
        word: []const u8,
        list: []const Node,
        record: []const Entry,
    },

    fn describe(n: Node) []const u8 {
        return switch (n.v) {
            .int => |i| if (i.unit == .none) "a number" else "a number with a unit",
            .string => "a string",
            .word => "a word",
            .list => "a list",
            .record => "a record",
        };
    }
};

pub const Like = struct { name: []const u8, pos: Pos };

pub const Block = struct {
    label: ?[]const u8,
    like: []const Like,
    body: []const Entry,
};

pub const Entry = struct {
    pos: Pos,
    key: []const u8,
    kind: union(enum) {
        field: Node,
        flag,
        block: Block,
    },
};

const Ctx = struct {
    arena: std.mem.Allocator,
    diag: *Diagnostic,
    templates: std.StringHashMapUnmanaged(Template) = .empty,
    labels: std.ArrayList(Label) = .empty,

    fn fail(c: *Ctx, pos: Pos, comptime fmt: []const u8, args: anytype) Error {
        c.diag.* = .{ .pos = pos, .msg = std.fmt.allocPrint(c.arena, fmt, args) catch return error.OutOfMemory };
        return error.Invalid;
    }
};

const Template = struct { pos: Pos, block: Block };

/// Where a labelled block was declared (`domain console` → kind "domain").
pub const Label = struct { kind: []const u8, name: []const u8, pos: Pos };

const TokKind = enum { word, string, number, lbrace, rbrace, lbracket, rbracket, equals, comma, newline, eof };

const Tok = struct { kind: TokKind, text: []const u8, pos: Pos };

const Lexer = struct {
    src: []const u8,
    i: usize = 0,
    pos: Pos = .{},

    fn peekByte(l: *Lexer) ?u8 {
        return if (l.i < l.src.len) l.src[l.i] else null;
    }

    fn bump(l: *Lexer) void {
        if (l.src[l.i] == '\n') {
            l.pos.line += 1;
            l.pos.col = 1;
        } else {
            l.pos.col += 1;
        }
        l.i += 1;
    }

    fn isWordStart(ch: u8) bool {
        return std.ascii.isAlphabetic(ch) or ch == '_';
    }

    fn isWordByte(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '-';
    }

    fn next(l: *Lexer, c: *Ctx) Error!Tok {
        while (l.peekByte()) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                l.bump();
            } else if (ch == '#') {
                while (l.peekByte()) |d| {
                    if (d == '\n') break;
                    l.bump();
                }
            } else break;
        }
        const start = l.pos;
        const ch = l.peekByte() orelse return .{ .kind = .eof, .text = "", .pos = start };
        const begin = l.i;
        const single: ?TokKind = switch (ch) {
            '{' => .lbrace,
            '}' => .rbrace,
            '[' => .lbracket,
            ']' => .rbracket,
            '=' => .equals,
            ',' => .comma,
            '\n' => .newline,
            else => null,
        };
        if (single) |k| {
            l.bump();
            return .{ .kind = k, .text = l.src[begin..l.i], .pos = start };
        }
        if (ch == '"') {
            l.bump();
            var out: std.ArrayList(u8) = .empty;
            while (true) {
                const d = l.peekByte() orelse return c.fail(start, "this string never ends: add a closing `\"`", .{});
                if (d == '\n') return c.fail(start, "this string never ends: add a closing `\"` on the same line", .{});
                l.bump();
                if (d == '"') break;
                if (d == '\\') {
                    const e = l.peekByte() orelse return c.fail(start, "this string never ends", .{});
                    l.bump();
                    try out.append(c.arena, switch (e) {
                        'n' => '\n',
                        't' => '\t',
                        '"' => '"',
                        '\\' => '\\',
                        else => return c.fail(start, "unknown escape `\\{c}` in a string (use \\n, \\t, \\\" or \\\\)", .{e}),
                    });
                } else try out.append(c.arena, d);
            }
            return .{ .kind = .string, .text = out.items, .pos = start };
        }
        if (std.ascii.isDigit(ch)) {
            while (l.peekByte()) |d| {
                if (!std.ascii.isAlphanumeric(d) and d != '_') break;
                l.bump();
            }
            return .{ .kind = .number, .text = l.src[begin..l.i], .pos = start };
        }
        if (isWordStart(ch)) {
            while (l.peekByte()) |d| {
                if (!isWordByte(d)) break;
                l.bump();
            }
            return .{ .kind = .word, .text = l.src[begin..l.i], .pos = start };
        }
        return c.fail(start, "unexpected `{c}`", .{ch});
    }
};

const Parser = struct {
    lx: Lexer,
    c: *Ctx,
    tok: Tok = undefined,

    fn advance(p: *Parser) Error!void {
        p.tok = try p.lx.next(p.c);
    }

    fn skipSeparators(p: *Parser) Error!void {
        while (p.tok.kind == .newline or p.tok.kind == .comma) try p.advance();
    }

    fn skipNewlines(p: *Parser) Error!void {
        while (p.tok.kind == .newline) try p.advance();
    }

    fn entries(p: *Parser, end: TokKind) Error![]const Entry {
        var list: std.ArrayList(Entry) = .empty;
        while (true) {
            try p.skipSeparators();
            if (p.tok.kind == end) break;
            if (p.tok.kind == .eof) return p.c.fail(p.tok.pos, "a `{{` is never closed: add `}}`", .{});
            try list.append(p.c.arena, try p.entry());
            switch (p.tok.kind) {
                .newline, .comma => {},
                else => if (p.tok.kind != end) return p.c.fail(p.tok.pos, "expected a new line after this entry, found `{s}`", .{p.tok.text}),
            }
        }
        return list.items;
    }

    fn entry(p: *Parser) Error!Entry {
        if (p.tok.kind != .word) return p.c.fail(p.tok.pos, "expected a name (like `priority = 200`), found `{s}`", .{p.tok.text});
        const key = p.tok.text;
        const pos = p.tok.pos;
        try p.advance();
        switch (p.tok.kind) {
            .equals => {
                try p.advance();
                return .{ .pos = pos, .key = key, .kind = .{ .field = try p.value() } };
            },
            .newline, .comma, .rbrace, .eof => return .{ .pos = pos, .key = key, .kind = .flag },
            .word, .lbrace => {
                var label: ?[]const u8 = null;
                if (p.tok.kind == .word and !std.mem.eql(u8, p.tok.text, "like")) {
                    label = p.tok.text;
                    try p.advance();
                }
                var likes: std.ArrayList(Like) = .empty;
                if (p.tok.kind == .word and std.mem.eql(u8, p.tok.text, "like")) {
                    try p.advance();
                    while (true) {
                        if (p.tok.kind != .word) return p.c.fail(p.tok.pos, "expected a template name after `like`", .{});
                        try likes.append(p.c.arena, .{ .name = p.tok.text, .pos = p.tok.pos });
                        try p.advance();
                        if (p.tok.kind != .comma) break;
                        try p.advance();
                    }
                }
                try p.skipNewlines();
                if (p.tok.kind != .lbrace) return p.c.fail(p.tok.pos, "expected `{{` to start the `{s}` block", .{key});
                try p.advance();
                const body = try p.entries(.rbrace);
                try p.advance();
                return .{ .pos = pos, .key = key, .kind = .{ .block = .{ .label = label, .like = likes.items, .body = body } } };
            },
            else => return p.c.fail(p.tok.pos, "expected `=` or `{{` after `{s}`", .{key}),
        }
    }

    fn value(p: *Parser) Error!Node {
        const t = p.tok;
        switch (t.kind) {
            .number => {
                try p.advance();
                return .{ .pos = t.pos, .v = .{ .int = try number(p.c, t) } };
            },
            .string => {
                try p.advance();
                return .{ .pos = t.pos, .v = .{ .string = t.text } };
            },
            .word => {
                try p.advance();
                return .{ .pos = t.pos, .v = .{ .word = t.text } };
            },
            .lbracket => {
                try p.advance();
                var items: std.ArrayList(Node) = .empty;
                while (true) {
                    try p.skipSeparators();
                    if (p.tok.kind == .rbracket) break;
                    if (p.tok.kind == .eof) return p.c.fail(t.pos, "this list is never closed: add `]`", .{});
                    try items.append(p.c.arena, try p.value());
                    try p.skipNewlines();
                    if (p.tok.kind != .comma and p.tok.kind != .rbracket and p.tok.kind != .newline)
                        return p.c.fail(p.tok.pos, "expected `,` or `]` in the list, found `{s}`", .{p.tok.text});
                }
                try p.advance();
                return .{ .pos = t.pos, .v = .{ .list = items.items } };
            },
            .lbrace => {
                try p.advance();
                const body = try p.entries(.rbrace);
                try p.advance();
                return .{ .pos = t.pos, .v = .{ .record = body } };
            },
            .newline, .eof => return p.c.fail(t.pos, "a value is missing after `=`", .{}),
            else => return p.c.fail(t.pos, "expected a value, found `{s}`", .{t.text}),
        }
    }
};

fn number(c: *Ctx, t: Tok) Error!@FieldType(@FieldType(Node, "v"), "int") {
    var text = t.text;
    var base: u8 = 10;
    if (std.mem.startsWith(u8, text, "0x")) {
        base = 16;
        text = text[2..];
    }
    var end: usize = 0;
    while (end < text.len and (text[end] == '_' or std.ascii.isDigit(text[end]) or (base == 16 and std.ascii.isHex(text[end])))) end += 1;
    const digits = text[0..end];
    const suffix = text[end..];
    const n = std.fmt.parseUnsigned(u64, digits, base) catch return c.fail(t.pos, "`{s}` is not a number Brix can read", .{t.text});
    if (suffix.len == 0) return .{ .n = n, .unit = .none };
    for (Unit.suffixes) |s| if (std.mem.eql(u8, suffix, s[0])) return .{ .n = n, .unit = s[1] };
    return c.fail(t.pos, "unknown unit `{s}` (use us, ms, s, B, KiB or MiB)", .{suffix});
}

pub fn parse(arena: std.mem.Allocator, source: []const u8, diag: *Diagnostic) Error![]const Entry {
    var c: Ctx = .{ .arena = arena, .diag = diag };
    return parseWith(&c, source);
}

fn parseWith(c: *Ctx, source: []const u8) Error![]const Entry {
    var p: Parser = .{ .lx = .{ .src = source }, .c = c };
    try p.advance();
    return p.entries(.eof);
}

// ---------------------------------------------------------------------------
// Evaluation, directed by the target type

pub fn Result(comptime T: type) type {
    return struct { value: T, labels: []const Label };
}

/// Evaluate Brix source into a `T`. On error.Invalid, `diag` says where and why.
pub fn evaluate(comptime T: type, arena: std.mem.Allocator, source: []const u8, diag: *Diagnostic) Error!Result(T) {
    var c: Ctx = .{ .arena = arena, .diag = diag };
    const top = try parseWith(&c, source);
    var root: std.ArrayList(Entry) = .empty;
    for (top) |e| {
        if (std.mem.eql(u8, e.key, "template")) {
            const b = switch (e.kind) {
                .block => |b| b,
                else => return c.fail(e.pos, "`template` declares a template: `template name {{ ... }}`", .{}),
            };
            const name = b.label orelse return c.fail(e.pos, "a template needs a name: `template driver {{ ... }}`", .{});
            const got = try c.templates.getOrPut(arena, name);
            if (got.found_existing) return c.fail(e.pos, "template `{s}` is declared twice (first at line {d})", .{ name, got.value_ptr.pos.line });
            got.value_ptr.* = .{ .pos = e.pos, .block = b };
        } else try root.append(arena, e);
    }
    const layers = [_][]const Entry{root.items};
    const v = try evalRecord(T, &c, &layers, null, .{}, "the file");
    return .{ .value = v, .labels = c.labels.items };
}

/// The bodies a block evaluates, in order: its templates (each with its own
/// templates first), then its own body. A template reached twice (`like a, b`
/// where b is also `like a`) applies once, at its first place.
fn layersOf(c: *Ctx, b: Block, out: *std.ArrayList([]const Entry), depth: u32) Error!void {
    var applied: std.ArrayList([]const u8) = .empty;
    try layersInner(c, b, out, &applied, depth);
}

fn layersInner(c: *Ctx, b: Block, out: *std.ArrayList([]const Entry), applied: *std.ArrayList([]const u8), depth: u32) Error!void {
    for (b.like) |l| {
        const t = c.templates.get(l.name) orelse return c.fail(l.pos, "no template named `{s}` (declare it with `template {s} {{ ... }}`)", .{ l.name, l.name });
        if (depth > 16) return c.fail(l.pos, "templates refer to each other in a cycle (through `{s}`)", .{l.name});
        const dup = for (applied.items) |a| {
            if (std.mem.eql(u8, a, l.name)) break true;
        } else false;
        if (dup) continue;
        try layersInner(c, t.block, out, applied, depth + 1);
        try applied.append(c.arena, l.name);
    }
    try out.append(c.arena, b.body);
}

const Seen = struct { layer: usize, pos: Pos };

fn isSlice(comptime F: type) bool {
    const info = @typeInfo(F);
    return info == .pointer and info.pointer.size == .slice and info.pointer.child != u8;
}

fn sliceChild(comptime F: type) type {
    return @typeInfo(F).pointer.child;
}

fn recordType(comptime F: type) ?type {
    return switch (@typeInfo(F)) {
        .@"struct" => F,
        .optional => |o| if (@typeInfo(o.child) == .@"struct") o.child else null,
        else => null,
    };
}

fn hasName(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "name") and @FieldType(T, "name") == []const u8;
}

const Target = struct { field: usize, unit: Unit, exact: bool };

/// Which field an entry `key` sets in T.
fn resolve(comptime T: type, key: []const u8, is_block: bool) ?Target {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, 0..) |name, j| {
        if (std.mem.eql(u8, name, key)) return .{ .field = j, .unit = Unit.ofFieldName(name), .exact = true };
    }
    if (is_block) {
        inline for (info.field_names, info.field_types, 0..) |name, F, j| {
            if (comptime isSlice(F)) {
                if (name.len == key.len + 1 and std.mem.startsWith(u8, name, key) and name[key.len] == 's') return .{ .field = j, .unit = .none, .exact = false };
            }
        }
    } else {
        // `budget` sets `budget_us`: the key plus a unit suffix.
        inline for (info.field_names, 0..) |name, j| {
            const l = comptime suffixLen(name);
            if (l > 0 and name.len - l == key.len and std.mem.startsWith(u8, name, key)) return .{ .field = j, .unit = comptime Unit.ofFieldName(name), .exact = false };
        }
    }
    return null;
}

fn suffixLen(comptime name: []const u8) usize {
    for (Unit.field_suffixes) |fs| if (std.mem.endsWith(u8, name, fs[0])) return fs[0].len;
    return 0;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 32 or b.len > 32) return 99;
    var prev: [33]usize = undefined;
    var cur: [33]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const sub = prev[j] + @intFromBool(ca != cb);
            cur[j + 1] = @min(sub, @min(prev[j + 1] + 1, cur[j] + 1));
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// The closest name an entry could have meant, as the user would write it.
fn suggest(comptime T: type, key: []const u8) ?[]const u8 {
    const info = @typeInfo(T).@"struct";
    var best: ?[]const u8 = null;
    var best_d: usize = @max(2, key.len / 3) + 1;
    inline for (info.field_names) |name| {
        const short = comptime name[0 .. name.len - suffixLen(name)];
        inline for (.{ name, short }) |cand| {
            const d = editDistance(key, cand);
            if (d < best_d) {
                best_d = d;
                best = cand;
            }
        }
    }
    return best;
}

fn fieldList(comptime T: type) []const u8 {
    const list = comptime blk: {
        var s: []const u8 = "";
        for (@typeInfo(T).@"struct".field_names) |name| s = s ++ (if (s.len == 0) "" else ", ") ++ name[0 .. name.len - suffixLen(name)];
        break :blk s;
    };
    return list;
}

fn evalRecord(comptime T: type, c: *Ctx, layers: []const []const Entry, label: ?[]const u8, pos: Pos, what: []const u8) Error!T {
    const info = @typeInfo(T).@"struct";
    const n = info.field_names.len;
    var out: T = undefined;
    var seen: [n]?Seen = @splat(null);
    var items: [n]std.ArrayList(*const Entry) = @splat(.empty);

    if (label) |l| {
        if (comptime hasName(T)) {
            out.name = l;
            seen[comptime std.meta.fieldIndex(T, "name").?] = .{ .layer = std.math.maxInt(usize), .pos = pos };
        } else unreachable;
    }

    for (layers, 0..) |layer, li| for (layer) |*e| {
        const is_block = e.kind == .block;
        const t = resolve(T, e.key, is_block) orelse {
            if (std.mem.eql(u8, e.key, "template")) return c.fail(e.pos, "templates are declared at the top level of the file", .{});
            if (suggest(T, e.key)) |s| return c.fail(e.pos, "{s} has no `{s}`; did you mean `{s}`?", .{ what, e.key, s });
            return c.fail(e.pos, "{s} has no `{s}` (it has: {s})", .{ what, e.key, fieldList(T) });
        };
        switch (t.field) {
            inline 0...n - 1 => |j| {
                const name = info.field_names[j];
                const F = info.field_types[j];
                const list_block = comptime isSlice(F) and @typeInfo(sliceChild(F)) == .@"struct";
                if (is_block and list_block) {
                    if (seen[j]) |s| if (s.layer != std.math.maxInt(usize) and items[j].items.len == 0)
                        return c.fail(e.pos, "`{s}` is already given as a list (line {d}); use blocks or a list, not both", .{ name, s.pos.line });
                    const b = e.kind.block;
                    if (comptime hasName(sliceChild(F))) {
                        if (b.label == null) return c.fail(e.pos, "this `{s}` needs a name: `{s} <name> {{ ... }}`", .{ e.key, e.key });
                    } else if (b.label != null) return c.fail(e.pos, "a `{s}` has no name; remove `{s}`", .{ e.key, b.label.? });
                    try items[j].append(c.arena, e);
                } else {
                    if (name.len > 0 and std.mem.eql(u8, name, "name") and label != null)
                        return c.fail(e.pos, "the name is already given by the label (`{s}`)", .{label.?});
                    if (seen[j]) |s| if (s.layer == li)
                        return c.fail(e.pos, "`{s}` is set twice (first at line {d})", .{ e.key, s.pos.line });
                    if (comptime isSlice(F)) items[j].clearRetainingCapacity();
                    @field(out, name) = try assign(F, c, e, t, name);
                    seen[j] = .{ .layer = li, .pos = e.pos };
                }
            },
            else => unreachable,
        }
    };

    inline for (info.field_names, info.field_types, 0..) |name, F, j| {
        if (comptime isSlice(F) and @typeInfo(sliceChild(F)) == .@"struct") {
            if (items[j].items.len > 0) {
                const Elem = sliceChild(F);
                const arr = try c.arena.alloc(Elem, items[j].items.len);
                for (items[j].items, arr) |e, *slot| {
                    const b = e.kind.block;
                    var sub: std.ArrayList([]const Entry) = .empty;
                    try layersOf(c, b, &sub, 0);
                    const desc = if (b.label) |l| try std.fmt.allocPrint(c.arena, "{s} '{s}'", .{ e.key, l }) else e.key;
                    slot.* = try evalRecord(Elem, c, sub.items, b.label, e.pos, desc);
                    if (b.label) |l| try c.labels.append(c.arena, .{ .kind = e.key, .name = l, .pos = e.pos });
                }
                @field(out, name) = arr;
                seen[j] = .{ .layer = 0, .pos = items[j].items[0].pos };
            }
        }
        if (seen[j] == null) {
            if (info.field_attrs[j].defaultValue(F)) |d| {
                @field(out, name) = d;
            } else {
                return c.fail(pos, "{s} needs `{s}`", .{ what, comptime name[0 .. name.len - suffixLen(name)] });
            }
        }
    }
    return out;
}

/// One entry's value, as field type F.
fn assign(comptime F: type, c: *Ctx, e: *const Entry, t: Target, comptime name: []const u8) Error!F {
    switch (e.kind) {
        .flag => {
            if (F != bool) return c.fail(e.pos, "`{s}` needs a value: `{s} = ...`", .{ e.key, e.key });
            return true;
        },
        .block => |b| {
            if (comptime recordType(F)) |R| {
                if (b.label != null) return c.fail(e.pos, "`{s}` takes no name; write `{s} {{ ... }}`", .{ e.key, e.key });
                var sub: std.ArrayList([]const Entry) = .empty;
                try layersOf(c, b, &sub, 0);
                try c.labels.append(c.arena, .{ .kind = e.key, .name = "", .pos = e.pos });
                return try evalRecord(R, c, sub.items, null, e.pos, e.key);
            }
            return c.fail(e.pos, "`{s}` is not a block; write `{s} = ...`", .{ e.key, e.key });
        },
        .field => |node| return convert(F, c, node, t, e.key, name),
    }
}

fn convert(comptime F: type, c: *Ctx, node: Node, t: Target, key: []const u8, comptime name: []const u8) Error!F {
    switch (@typeInfo(F)) {
        .bool => {
            if (node.v == .word) {
                if (std.mem.eql(u8, node.v.word, "true")) return true;
                if (std.mem.eql(u8, node.v.word, "false")) return false;
            }
            return c.fail(node.pos, "`{s}` is true or false, not {s}", .{ key, node.describe() });
        },
        .int => {
            if (node.v != .int) return c.fail(node.pos, "`{s}` is a number, not {s}", .{ key, node.describe() });
            const iv = node.v.int;
            var v = iv.n;
            if (iv.unit != .none) {
                if (t.unit == .none) return c.fail(node.pos, "`{s}` takes a plain number, not `{d}{s}`", .{ key, iv.n, iv.unit.spelling() });
                if (iv.unit.dim() != t.unit.dim()) return c.fail(node.pos, "`{s}` is a {s}, not a {s}", .{ key, @tagName(t.unit.dim()), @tagName(iv.unit.dim()) });
                const scaled = std.math.mul(u64, v, iv.unit.factor()) catch return c.fail(node.pos, "`{d}{s}` is too large", .{ iv.n, iv.unit.spelling() });
                if (scaled % t.unit.factor() != 0) return c.fail(node.pos, "`{d}{s}` is not a whole number of {s} (`{s}` counts {s})", .{ iv.n, iv.unit.spelling(), t.unit.spelling(), name, t.unit.spelling() });
                v = scaled / t.unit.factor();
            } else if (t.unit != .none and !t.exact) {
                return c.fail(node.pos, "`{s}` needs a unit, e.g. `{d}{s}`", .{ key, iv.n, t.unit.spelling() });
            }
            return std.math.cast(F, v) orelse c.fail(node.pos, "`{s}` = {d} is too large (at most {d})", .{ key, v, std.math.maxInt(F) });
        },
        .@"enum" => {
            const fields = @typeInfo(F).@"enum".field_names;
            if (node.v == .word) {
                inline for (fields) |tag| if (std.mem.eql(u8, tag, node.v.word)) return @field(F, tag);
            }
            const choices = comptime blk: {
                var s: []const u8 = "";
                for (fields) |tag| s = s ++ (if (s.len == 0) "" else ", ") ++ tag;
                break :blk s;
            };
            return c.fail(node.pos, "`{s}` is one of: {s}", .{ key, choices });
        },
        .optional => |o| return try convert(o.child, c, node, t, key, name),
        .pointer => |ptr| {
            if (ptr.size != .slice) @compileError("brix: unsupported field type " ++ @typeName(F));
            if (ptr.child == u8) return switch (node.v) {
                .string => |s| s,
                .word => |w| w,
                else => c.fail(node.pos, "`{s}` is text, not {s}", .{ key, node.describe() }),
            };
            if (node.v != .list) return c.fail(node.pos, "`{s}` is a list: `{s} = [ ... ]`", .{ key, key });
            const arr = try c.arena.alloc(ptr.child, node.v.list.len);
            for (node.v.list, arr) |item, *slot| slot.* = try convert(ptr.child, c, item, .{ .field = 0, .unit = .none, .exact = true }, key, name);
            return arr;
        },
        .@"struct" => {
            if (node.v != .record) return c.fail(node.pos, "`{s}` is a record: `{{ k = v, ... }}`", .{key});
            const layers = [_][]const Entry{node.v.record};
            return try evalRecord(F, c, &layers, null, node.pos, key);
        },
        else => @compileError("brix: unsupported field type " ++ @typeName(F)),
    }
}

/// Where the block a message is about was declared: for "domain 'hello'
/// uses ..." the `domain hello` block (the first one the message names);
/// failing that, an unnamed block the message mentions ("agent.envoy ..."
/// → the `agent` block).
pub fn locate(labels: []const Label, msg: []const u8) ?Pos {
    var best: ?Pos = null;
    var best_at: usize = std.math.maxInt(usize);
    var buf: [128]u8 = undefined;
    for (labels) |l| {
        if (l.name.len == 0) continue;
        const needle = std.fmt.bufPrint(&buf, "{s} '{s}'", .{ l.kind, l.name }) catch continue;
        if (std.mem.indexOf(u8, msg, needle)) |at| if (at < best_at) {
            best_at = at;
            best = l.pos;
        };
    }
    if (best != null) return best;
    for (labels) |l| {
        if (l.name.len != 0) continue;
        var words = std.mem.tokenizeAny(u8, msg, " .,'");
        while (words.next()) |w| if (std.mem.eql(u8, w, l.kind)) return l.pos;
    }
    return null;
}

/// `path:line:col: message`, then the line and a caret under the column.
pub fn render(w: *std.Io.Writer, path: []const u8, source: []const u8, d: Diagnostic) std.Io.Writer.Error!void {
    try w.print("{s}:{d}:{d}: {s}\n", .{ path, d.pos.line, d.pos.col, d.msg });
    var it = std.mem.splitScalar(u8, source, '\n');
    var line: u32 = 1;
    while (it.next()) |text| : (line += 1) {
        if (line != d.pos.line) continue;
        try w.print("    {s}\n    ", .{text});
        for (0..d.pos.col -| 1) |i| try w.writeByte(if (i < text.len and text[i] == '\t') '\t' else ' ');
        try w.writeAll("^\n");
        break;
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const Demo = struct {
    name: []const u8,
    kind: enum { service, task } = .service,
    priority: u8 = 100,
    budget_us: u32 = 1_000,
    memory_kib: u32 = 64,
    debug: bool = false,
    tags: []const []const u8 = &.{},
    parts: []const Part = &.{},
    extra: ?Extra = null,

    const Part = struct { name: []const u8, size: u32 = 0 };
    const Extra = struct { note: []const u8 };
};

fn expectFail(src: []const u8, line: u32, col: u32, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    if (evaluate(Demo, arena.allocator(), src, &d)) |_| {
        std.debug.print("expected an error containing \"{s}\", got none\n", .{want});
        return error.TestExpectedError;
    } else |e| try testing.expectEqual(error.Invalid, e);
    if (std.mem.indexOf(u8, d.msg, want) == null or d.pos.line != line or d.pos.col != col) {
        std.debug.print("expected {d}:{d} \"{s}\", got {d}:{d} \"{s}\"\n", .{ line, col, want, d.pos.line, d.pos.col, d.msg });
        return error.TestUnexpectedError;
    }
}

test "fields, flags, words, units, blocks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const v = (try evaluate(Demo, arena.allocator(),
        \\# a comment
        \\name = demo-1        # words may hold dots and dashes
        \\kind = task
        \\debug
        \\budget = 2ms
        \\memory = 1MiB
        \\tags = [a, "b c", d.e]
        \\part first { size = 3 }
        \\part second
        \\    { size = 4 }
        \\extra { note = "hi\n" }
    , &d)).value;
    try testing.expectEqualStrings("demo-1", v.name);
    try testing.expectEqual(.task, v.kind);
    try testing.expect(v.debug);
    try testing.expectEqual(@as(u32, 2000), v.budget_us);
    try testing.expectEqual(@as(u32, 1024), v.memory_kib);
    try testing.expectEqual(@as(usize, 3), v.tags.len);
    try testing.expectEqualStrings("b c", v.tags[1]);
    try testing.expectEqual(@as(usize, 2), v.parts.len);
    try testing.expectEqualStrings("second", v.parts[1].name);
    try testing.expectEqual(@as(u32, 4), v.parts[1].size);
    try testing.expectEqualStrings("hi\n", v.extra.?.note);
    try testing.expectEqual(@as(u8, 100), v.priority);
}

test "templates layer in order and bodies override them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const W = struct { items: []const struct { name: []const u8, priority: u8 = 0, budget_us: u32 = 0, parts: []const Demo.Part = &.{} } };
    var d: Diagnostic = .{};
    const r = try evaluate(W, arena.allocator(),
        \\template base { priority = 7, budget = 1ms, part p { size = 1 } }
        \\template more like base { priority = 8 }
        \\item a like more { priority = 9 }
        \\item b like base
        \\{ }
        \\item c like more, base {}
    , &d);
    try testing.expectEqual(@as(usize, 3), r.value.items.len);
    try testing.expectEqual(@as(u8, 9), r.value.items[0].priority);
    try testing.expectEqual(@as(u32, 1000), r.value.items[0].budget_us);
    try testing.expectEqual(@as(usize, 1), r.value.items[0].parts.len);
    try testing.expectEqual(@as(u8, 7), r.value.items[1].priority);
    // `like more, base`: base already came in through more, so it applies
    // once (its part too), and more's priority stands.
    try testing.expectEqual(@as(u8, 8), r.value.items[2].priority);
    try testing.expectEqual(@as(usize, 1), r.value.items[2].parts.len);
    var items: usize = 0;
    for (r.labels) |l| if (std.mem.eql(u8, l.kind, "item")) {
        if (items == 0) try testing.expectEqual(@as(u32, 3), l.pos.line);
        items += 1;
    };
    try testing.expectEqual(@as(usize, 3), items);
}

test "errors name the line, the column and the fix" {
    try expectFail("name = x\nprority = 3\n", 2, 1, "did you mean `priority`?");
    try expectFail("name = x\nbudget = 1500us\nmemory = 1000B\n", 3, 10, "not a whole number of KiB");
    try expectFail("name = x\nbudget = 5\n", 2, 10, "needs a unit, e.g. `5us`");
    try expectFail("name = x\nbudget = 4KiB\n", 2, 10, "is a time, not a size");
    try expectFail("name = x\npriority = 300\n", 2, 12, "too large (at most 255)");
    try expectFail("name = x\nkind = daemon\n", 2, 8, "one of: service, task");
    try expectFail("name = x\npriority = 1\npriority = 2\n", 3, 1, "set twice (first at line 2)");
    try expectFail("kind = task\n", 1, 1, "the file needs `name`");
    try expectFail("name = x\npart { size = 1 }\n", 2, 1, "needs a name");
    try expectFail("name = x\npart p like nope {}\n", 2, 13, "no template named `nope`");
    try expectFail("template a like b {}\ntemplate b like a {}\nname = x\npart p like a {}\n", 1, 17, "cycle");
    try expectFail("name = \"x\nkind = task\n", 1, 8, "never ends");
    try expectFail("name = x\nbudget = 1h\n", 2, 10, "unknown unit `h`");
    try expectFail("name = x\npart p { size = 1\n", 3, 1, "never closed");
    try expectFail("name = x\npart p { colour = red }\n", 2, 10, "part 'p' has no `colour`");
    try expectFail("name = x\ndebug = yes\n", 2, 9, "true or false");
}

test "locate finds the block a validator message names" {
    const labels = [_]Label{
        .{ .kind = "domain", .name = "console", .pos = .{ .line = 3, .col = 1 } },
        .{ .kind = "domain", .name = "hello", .pos = .{ .line = 9, .col = 1 } },
    };
    try testing.expectEqual(@as(u32, 9), locate(&labels, "domain 'hello' uses 'console.consol', but no domain provides it").?.line);
    try testing.expect(locate(&labels, "the manifest needs a name") == null);
    const more = labels ++ [_]Label{.{ .kind = "agent", .name = "", .pos = .{ .line = 20, .col = 1 } }};
    try testing.expectEqual(@as(u32, 20), locate(&more, "agent.envoy names 'envoy', which is not a domain").?.line);
    try testing.expectEqual(@as(u32, 9), locate(&more, "the agent has two services named 'x'; domain 'hello' too").?.line);
}
