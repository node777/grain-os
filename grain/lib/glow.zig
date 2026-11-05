//! Glow: Grain's command language.
//!
//! A line of Glow calls the capabilities a program holds and works with what
//! comes back, which is typed data, not text:
//!
//!     kv.put key=7 value=42
//!     let r = kv.get key=7; print r.value + 1
//!     kumara.whoami | .name
//!     kv.get key=7 | kv.put key=8          (missing arguments come from the
//!                                           record on the left, by name)
//!     for i in 0..3 { kv.put key=i value=(i*i) }
//!     if (kv.get key=9).found { print "yes" } else { print "no" }
//!
//! Values: none, integers, true/false, "text", bytes (shown in hex) and
//! records ({name: value, ...}). A call is `<capability>.<method>` with
//! `name=value` arguments; an argument that is more than a literal, a name
//! or a field goes in parentheses. A statement's value is shown unless it is
//! none; `print` shows values in a line, text without quotes.
//!
//! This file is the language alone: it calls out through a `World` (what the
//! program holds, proto/glow_call.zig in a domain, a stand-in in the tests),
//! so it runs and is tested on the host.
const std = @import("std");

pub const Value = union(enum) {
    none,
    int: i128,
    boolean: bool,
    text: []const u8,
    bytes: []const u8,
    record: []const Field,

    pub fn field(v: Value, name: []const u8) ?Value {
        if (v != .record) return null;
        for (v.record) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
        return null;
    }

    fn typeName(v: Value) []const u8 {
        return switch (v) {
            .none => "none",
            .int => "an integer",
            .boolean => "true or false",
            .text => "text",
            .bytes => "bytes",
            .record => "a record",
        };
    }
};

pub const Field = struct { name: []const u8, value: Value };

/// Where output goes: one line at a time.
pub const Out = struct {
    ctx: *anyopaque,
    line: *const fn (ctx: *anyopaque, text: []const u8) void,

    pub fn print(o: Out, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const t: []const u8 = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
        o.line(o.ctx, t);
    }
};

/// What a program holds. `call` gets the explicit arguments, and the record
/// a pipe brought (`from`), whose fields fill parameters not given; on an
/// error it writes why into `why`.
pub const World = struct {
    ctx: *anyopaque,
    has: *const fn (ctx: *anyopaque, cap: []const u8) bool,
    call: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, cap: []const u8, method: []const u8, args: []const Field, from: ?Value, why: *Why) error{Failed}!Value,
    /// `caps`: every capability, a line each.
    list: *const fn (ctx: *anyopaque, out: Out) void,
    /// `describe <cap>`: its methods, a line each; false if not held.
    describe: *const fn (ctx: *anyopaque, cap: []const u8, out: Out) bool,
};

/// An error's explanation, written where it happened.
pub const Why = struct {
    buf: [200]u8 = undefined,
    len: usize = 0,

    pub fn set(w: *Why, comptime fmt: []const u8, args: anytype) void {
        const t: []const u8 = std.fmt.bufPrint(&w.buf, fmt, args) catch &w.buf;
        w.len = t.len;
    }

    pub fn text(w: *const Why) []const u8 {
        return w.buf[0..w.len];
    }
};

pub const Error = error{ Syntax, Failed, OutOfMemory, TooMuch };

// ---------------------------------------------------------------------------
// Tokens

const Tag = enum { int, string, name, dot, dotdot, pipe, assign, eq, ne, lt, le, gt, ge, plus, minus, star, slash, percent, lparen, rparen, lbrace, rbrace, semi, comma, end };

const Token = struct {
    tag: Tag,
    text: []const u8 = "",
    int: i128 = 0,
    col: usize = 0,
};

const Lexer = struct {
    src: []const u8,
    i: usize = 0,
    why: *Why,

    fn next(l: *Lexer) Error!Token {
        while (l.i < l.src.len and (l.src[l.i] == ' ' or l.src[l.i] == '\t' or l.src[l.i] == '\r')) l.i += 1;
        // A comment runs to the end of the line.
        if (l.i < l.src.len and l.src[l.i] == '#') {
            while (l.i < l.src.len and l.src[l.i] != '\n') l.i += 1;
        }
        const col = l.i + 1;
        if (l.i >= l.src.len) return .{ .tag = .end, .col = col };
        const c = l.src[l.i];
        if (std.ascii.isDigit(c)) {
            const start = l.i;
            while (l.i < l.src.len and (std.ascii.isAlphanumeric(l.src[l.i]) or l.src[l.i] == '_')) l.i += 1;
            const lit = l.src[start..l.i];
            const n = std.fmt.parseInt(i128, lit, 0) catch {
                l.why.set("column {d}: '{s}' is not a number", .{ col, lit });
                return error.Syntax;
            };
            return .{ .tag = .int, .int = n, .text = lit, .col = col };
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = l.i;
            while (l.i < l.src.len and (std.ascii.isAlphanumeric(l.src[l.i]) or l.src[l.i] == '_')) l.i += 1;
            return .{ .tag = .name, .text = l.src[start..l.i], .col = col };
        }
        if (c == '"') {
            l.i += 1;
            const start = l.i;
            while (l.i < l.src.len and l.src[l.i] != '"') : (l.i += 1) {
                if (l.src[l.i] == '\\') l.i += 1;
            }
            if (l.i >= l.src.len) {
                l.why.set("column {d}: this text has no closing quote", .{col});
                return error.Syntax;
            }
            const raw = l.src[start..l.i];
            l.i += 1;
            return .{ .tag = .string, .text = raw, .col = col };
        }
        const two: []const u8 = if (l.i + 1 < l.src.len) l.src[l.i .. l.i + 2] else "";
        const doubles = [_]struct { []const u8, Tag }{ .{ "..", .dotdot }, .{ "==", .eq }, .{ "!=", .ne }, .{ "<=", .le }, .{ ">=", .ge } };
        for (doubles) |d| if (std.mem.eql(u8, two, d[0])) {
            l.i += 2;
            return .{ .tag = d[1], .col = col };
        };
        const tag: Tag = switch (c) {
            '.' => .dot,
            '|' => .pipe,
            '=' => .assign,
            '<' => .lt,
            '>' => .gt,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            ';', '\n' => .semi,
            ',' => .comma,
            else => {
                l.why.set("column {d}: '{c}' means nothing here", .{ col, c });
                return error.Syntax;
            },
        };
        l.i += 1;
        return .{ .tag = tag, .col = col };
    }
};

// ---------------------------------------------------------------------------
// The tree

const Node = union(enum) {
    literal: Value,
    /// A text literal, its escapes still in it.
    string: []const u8,
    variable: []const u8,
    /// `_`: what came down the pipe.
    piped,
    field: struct { base: *const Node, name: []const u8 },
    /// `cap.method k=v ...`
    call: struct { cap: []const u8, method: []const u8, args: []const Arg },
    unary: struct { op: Tag, a: *const Node },
    binary: struct { op: Tag, a: *const Node, b: *const Node },
    logic: struct { is_and: bool, a: *const Node, b: *const Node },
    negate: *const Node,
    /// `a | stage | stage`
    pipe: struct { first: *const Node, stages: []const *const Node },
};

const Arg = struct { name: []const u8, value: *const Node };

const Stmt = union(enum) {
    let: struct { name: []const u8, value: *const Node },
    print: []const *const Node,
    expr: *const Node,
    if_: struct { cond: *const Node, then: []const Stmt, otherwise: []const Stmt },
    for_: struct { name: []const u8, from: *const Node, to: *const Node, body: []const Stmt },
    caps,
    describe: []const u8,
    help,
};

const Parser = struct {
    lex: Lexer,
    tok: Token,
    gpa: std.mem.Allocator,
    why: *Why,

    fn init(gpa: std.mem.Allocator, src: []const u8, why: *Why) Error!Parser {
        var p: Parser = .{ .lex = .{ .src = src, .why = why }, .tok = undefined, .gpa = gpa, .why = why };
        p.tok = try p.lex.next();
        return p;
    }

    fn advance(p: *Parser) Error!Token {
        const t = p.tok;
        p.tok = try p.lex.next();
        return t;
    }

    fn peekIsAssign(p: *Parser) Error!bool {
        // Look one token past a name for '=' (an argument), without moving.
        const saved = p.lex;
        const t = try p.lex.next();
        p.lex = saved;
        return t.tag == .assign;
    }

    fn expect(p: *Parser, tag: Tag, what: []const u8) Error!Token {
        if (p.tok.tag != tag) {
            p.why.set("column {d}: expected {s}", .{ p.tok.col, what });
            return error.Syntax;
        }
        return p.advance();
    }

    fn isWord(p: *const Parser, w: []const u8) bool {
        return p.tok.tag == .name and std.mem.eql(u8, p.tok.text, w);
    }

    fn node(p: *Parser, n: Node) Error!*const Node {
        const out = try p.gpa.create(Node);
        out.* = n;
        return out;
    }

    fn program(p: *Parser, until: Tag) Error![]const Stmt {
        var list: std.ArrayList(Stmt) = .empty;
        while (true) {
            while (p.tok.tag == .semi) _ = try p.advance();
            if (p.tok.tag == until or p.tok.tag == .end) break;
            try list.append(p.gpa, try p.statement());
            if (p.tok.tag != .semi and p.tok.tag != until and p.tok.tag != .end) {
                p.why.set("column {d}: expected ';' or the end of the line", .{p.tok.col});
                return error.Syntax;
            }
        }
        return list.items;
    }

    fn block(p: *Parser) Error![]const Stmt {
        _ = try p.expect(.lbrace, "'{'");
        const body = try p.program(.rbrace);
        _ = try p.expect(.rbrace, "'}'");
        return body;
    }

    fn statement(p: *Parser) Error!Stmt {
        if (p.isWord("let")) {
            _ = try p.advance();
            const name = try p.expect(.name, "a name after let");
            _ = try p.expect(.assign, "'=' after the name");
            return .{ .let = .{ .name = name.text, .value = try p.pipeline() } };
        }
        if (p.isWord("print")) {
            _ = try p.advance();
            var items: std.ArrayList(*const Node) = .empty;
            while (p.tok.tag != .semi and p.tok.tag != .end and p.tok.tag != .rbrace) {
                try items.append(p.gpa, try p.expr());
                if (p.tok.tag == .comma) _ = try p.advance();
            }
            return .{ .print = items.items };
        }
        if (p.isWord("if")) {
            _ = try p.advance();
            const cond = try p.expr();
            const then = try p.block();
            var otherwise: []const Stmt = &.{};
            if (p.isWord("else")) {
                _ = try p.advance();
                if (p.isWord("if")) {
                    const nested = try p.gpa.alloc(Stmt, 1);
                    nested[0] = try p.statement();
                    otherwise = nested;
                } else otherwise = try p.block();
            }
            return .{ .if_ = .{ .cond = cond, .then = then, .otherwise = otherwise } };
        }
        if (p.isWord("for")) {
            _ = try p.advance();
            const name = try p.expect(.name, "a name after for");
            if (!p.isWord("in")) {
                p.why.set("column {d}: expected 'in'", .{p.tok.col});
                return error.Syntax;
            }
            _ = try p.advance();
            const from = try p.additive();
            _ = try p.expect(.dotdot, "'..' (as in 0..10)");
            const to = try p.additive();
            return .{ .for_ = .{ .name = name.text, .from = from, .to = to, .body = try p.block() } };
        }
        if (p.isWord("caps")) {
            _ = try p.advance();
            return .caps;
        }
        if (p.isWord("help")) {
            _ = try p.advance();
            return .help;
        }
        if (p.isWord("describe")) {
            _ = try p.advance();
            const name = try p.expect(.name, "a capability to describe");
            return .{ .describe = name.text };
        }
        return .{ .expr = try p.pipeline() };
    }

    fn pipeline(p: *Parser) Error!*const Node {
        const first = try p.expr();
        if (p.tok.tag != .pipe) return first;
        var stages: std.ArrayList(*const Node) = .empty;
        while (p.tok.tag == .pipe) {
            _ = try p.advance();
            // `| .a.b` selects from what came down the pipe.
            if (p.tok.tag == .dot) {
                var n = try p.node(.piped);
                while (p.tok.tag == .dot) {
                    _ = try p.advance();
                    const f = try p.expect(.name, "a field name");
                    n = try p.node(.{ .field = .{ .base = n, .name = f.text } });
                }
                try stages.append(p.gpa, n);
            } else try stages.append(p.gpa, try p.expr());
        }
        return p.node(.{ .pipe = .{ .first = first, .stages = stages.items } });
    }

    fn expr(p: *Parser) Error!*const Node {
        var a = try p.andExpr();
        while (p.isWord("or")) {
            _ = try p.advance();
            a = try p.node(.{ .logic = .{ .is_and = false, .a = a, .b = try p.andExpr() } });
        }
        return a;
    }

    fn andExpr(p: *Parser) Error!*const Node {
        var a = try p.notExpr();
        while (p.isWord("and")) {
            _ = try p.advance();
            a = try p.node(.{ .logic = .{ .is_and = true, .a = a, .b = try p.notExpr() } });
        }
        return a;
    }

    fn notExpr(p: *Parser) Error!*const Node {
        if (p.isWord("not")) {
            _ = try p.advance();
            return p.node(.{ .negate = try p.notExpr() });
        }
        return p.comparison();
    }

    fn comparison(p: *Parser) Error!*const Node {
        const a = try p.additive();
        switch (p.tok.tag) {
            .eq, .ne, .lt, .le, .gt, .ge => {
                const op = (try p.advance()).tag;
                return p.node(.{ .binary = .{ .op = op, .a = a, .b = try p.additive() } });
            },
            else => return a,
        }
    }

    fn additive(p: *Parser) Error!*const Node {
        var a = try p.multiplicative();
        while (p.tok.tag == .plus or p.tok.tag == .minus) {
            const op = (try p.advance()).tag;
            a = try p.node(.{ .binary = .{ .op = op, .a = a, .b = try p.multiplicative() } });
        }
        return a;
    }

    fn multiplicative(p: *Parser) Error!*const Node {
        var a = try p.unary();
        while (p.tok.tag == .star or p.tok.tag == .slash or p.tok.tag == .percent) {
            const op = (try p.advance()).tag;
            a = try p.node(.{ .binary = .{ .op = op, .a = a, .b = try p.unary() } });
        }
        return a;
    }

    fn unary(p: *Parser) Error!*const Node {
        if (p.tok.tag == .minus) {
            _ = try p.advance();
            return p.node(.{ .unary = .{ .op = .minus, .a = try p.unary() } });
        }
        return p.postfix();
    }

    /// A primary, then `.field`s; `name.name` with `k=v` arguments (or none,
    /// when `name` is not a variable) is a call, decided when it runs.
    fn postfix(p: *Parser) Error!*const Node {
        var n = try p.primary();
        while (p.tok.tag == .dot) {
            _ = try p.advance();
            const f = try p.expect(.name, "a field or method name");
            n = try p.node(.{ .field = .{ .base = n, .name = f.text } });
            // `cap.method k=v ...`: arguments make it a call for certain.
            if (p.tok.tag == .name and try p.peekIsAssign()) {
                const base = n.field.base.*;
                if (base != .variable) {
                    p.why.set("column {d}: arguments follow a call, as in kv.get key=1", .{p.tok.col});
                    return error.Syntax;
                }
                var args: std.ArrayList(Arg) = .empty;
                while (p.tok.tag == .name and try p.peekIsAssign()) {
                    const name = try p.advance();
                    _ = try p.advance(); // '='
                    try args.append(p.gpa, .{ .name = name.text, .value = try p.unary() });
                }
                n = try p.node(.{ .call = .{ .cap = base.variable, .method = f.text, .args = args.items } });
            }
        }
        return n;
    }

    fn primary(p: *Parser) Error!*const Node {
        const t = try p.advance();
        switch (t.tag) {
            .int => return p.node(.{ .literal = .{ .int = t.int } }),
            .string => return p.node(.{ .string = t.text }),
            .lparen => {
                const inner = try p.pipeline();
                _ = try p.expect(.rparen, "')'");
                return inner;
            },
            .name => {
                if (std.mem.eql(u8, t.text, "true")) return p.node(.{ .literal = .{ .boolean = true } });
                if (std.mem.eql(u8, t.text, "false")) return p.node(.{ .literal = .{ .boolean = false } });
                if (std.mem.eql(u8, t.text, "none")) return p.node(.{ .literal = .none });
                if (std.mem.eql(u8, t.text, "_")) return p.node(.piped);
                return p.node(.{ .variable = t.text });
            },
            else => {
                p.why.set("column {d}: expected a value", .{t.col});
                return error.Syntax;
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Running

pub const help_text = [_][]const u8{
    "Glow: call what this program holds, and work with what comes back.",
    "  kv.put key=7 value=42          a call: <capability>.<method> name=value ...",
    "  let r = kv.get key=7           a name for a value; r.value is a field",
    "  kumara.whoami | .name          pipes: select a field, or call with _ = the left",
    "  kv.get key=7 | kv.put key=8    missing arguments come from the left record",
    "  for i in 0..3 { print i * i }  loops; if c { } else { }; and, or, not",
    "  caps   describe <cap>   help",
};

pub const Interp = struct {
    gpa: std.mem.Allocator,
    world: World,
    out: Out,
    why: Why = .{},
    vars: std.StringArrayHashMapUnmanaged(Value) = .empty,
    /// Work left before a runaway script is stopped.
    budget: u32 = 100_000,

    pub fn init(gpa: std.mem.Allocator, world: World, out: Out) Interp {
        return .{ .gpa = gpa, .world = world, .out = out };
    }

    /// Run a line (or several, separated by ';' or newlines). On an error,
    /// `why` says what and where.
    pub fn run(it: *Interp, src: []const u8) Error!void {
        it.budget = 100_000;
        var p = try Parser.init(it.gpa, src, &it.why);
        const prog = try p.program(.end);
        if (p.tok.tag != .end) {
            it.why.set("column {d}: unexpected '}}'", .{p.tok.col});
            return error.Syntax;
        }
        for (prog) |s| try it.statement(s, true);
    }

    fn fail(it: *Interp, comptime fmt: []const u8, args: anytype) Error {
        it.why.set(fmt, args);
        return error.Failed;
    }

    fn tick(it: *Interp) Error!void {
        if (it.budget == 0) {
            it.why.set("stopped: this ran too long (a loop without end?)", .{});
            return error.TooMuch;
        }
        it.budget -= 1;
    }

    fn statement(it: *Interp, s: Stmt, top: bool) Error!void {
        try it.tick();
        switch (s) {
            .let => |l| try it.vars.put(it.gpa, l.name, try it.eval(l.value, null)),
            .print => |items| {
                var line: std.ArrayList(u8) = .empty;
                for (items, 0..) |n, i| {
                    if (i > 0) try line.append(it.gpa, ' ');
                    try format(it.gpa, &line, try it.eval(n, null), false);
                }
                it.out.line(it.out.ctx, line.items);
            },
            .expr => |n| {
                const v = try it.eval(n, null);
                if (top and v != .none) try it.show(v);
            },
            .if_ => |c| {
                const body = if (try it.truth(try it.eval(c.cond, null))) c.then else c.otherwise;
                for (body) |b| try it.statement(b, false);
            },
            .for_ => |f| {
                const from = try it.integer(try it.eval(f.from, null), "a loop's start");
                const to = try it.integer(try it.eval(f.to, null), "a loop's end");
                var i = from;
                while (i < to) : (i += 1) {
                    try it.vars.put(it.gpa, f.name, .{ .int = i });
                    for (f.body) |b| try it.statement(b, false);
                }
            },
            .caps => it.world.list(it.world.ctx, it.out),
            .describe => |cap| if (!it.world.describe(it.world.ctx, cap, it.out)) return it.fail("you hold no capability named '{s}' (try caps)", .{cap}),
            .help => for (help_text) |l| it.out.line(it.out.ctx, l),
        }
    }

    pub fn show(it: *Interp, v: Value) Error!void {
        var line: std.ArrayList(u8) = .empty;
        try format(it.gpa, &line, v, true);
        it.out.line(it.out.ctx, line.items);
    }

    fn truth(it: *Interp, v: Value) Error!bool {
        return switch (v) {
            .boolean => |b| b,
            .none => false,
            else => it.fail("a condition must be true or false, not {s}", .{v.typeName()}),
        };
    }

    fn integer(it: *Interp, v: Value, what: []const u8) Error!i128 {
        return switch (v) {
            .int => |n| n,
            else => it.fail("{s} must be an integer, not {s}", .{ what, v.typeName() }),
        };
    }

    fn eval(it: *Interp, n: *const Node, piped: ?Value) Error!Value {
        try it.tick();
        switch (n.*) {
            .literal => |v| return v,
            .string => |raw| return .{ .text = try unescape(it.gpa, raw) },
            .piped => return piped orelse it.fail("'_' means what came down a pipe; there is no pipe here", .{}),
            .variable => |name| {
                if (it.vars.get(name)) |v| return v;
                if (it.world.has(it.world.ctx, name)) return it.fail("'{s}' is a capability: call one of its methods, as in {s}.<method> (describe {s})", .{ name, name, name });
                return it.fail("nothing is named '{s}'", .{name});
            },
            .field => |f| {
                // `cap.method` with no arguments, when `cap` names no variable.
                if (f.base.* == .variable) {
                    const name = f.base.variable;
                    if (it.vars.get(name) == null and it.world.has(it.world.ctx, name)) return it.call(name, f.name, &.{}, piped);
                }
                const base = try it.eval(f.base, piped);
                return base.field(f.name) orelse switch (base) {
                    .record => |fields| {
                        var names: std.ArrayList(u8) = .empty;
                        for (fields, 0..) |x, i| {
                            if (i > 0) try names.appendSlice(it.gpa, ", ");
                            try names.appendSlice(it.gpa, x.name);
                        }
                        return it.fail("this record has no field '{s}' (it has {s})", .{ f.name, names.items });
                    },
                    else => it.fail("'.{s}' needs a record; this is {s}", .{ f.name, base.typeName() }),
                };
            },
            .call => |c| {
                if (it.vars.get(c.cap) != null) return it.fail("'{s}' is a variable, not a capability", .{c.cap});
                return it.call(c.cap, c.method, c.args, piped);
            },
            .unary => |u| return .{ .int = -(try it.integer(try it.eval(u.a, piped), "'-'")) },
            .negate => |a| return .{ .boolean = !(try it.truth(try it.eval(a, piped))) },
            .logic => |l| {
                const a = try it.truth(try it.eval(l.a, piped));
                if (l.is_and and !a) return .{ .boolean = false };
                if (!l.is_and and a) return .{ .boolean = true };
                return .{ .boolean = try it.truth(try it.eval(l.b, piped)) };
            },
            .binary => |b| return it.binary(b.op, try it.eval(b.a, piped), try it.eval(b.b, piped)),
            .pipe => |p| {
                var v = try it.eval(p.first, piped);
                for (p.stages) |s| v = try it.eval(s, v);
                return v;
            },
        }
    }

    fn call(it: *Interp, cap: []const u8, method: []const u8, arg_nodes: []const Arg, piped: ?Value) Error!Value {
        if (!it.world.has(it.world.ctx, cap)) return it.fail("you hold no capability named '{s}' (try caps)", .{cap});
        const args = try it.gpa.alloc(Field, arg_nodes.len);
        for (arg_nodes, 0..) |a, i| args[i] = .{ .name = a.name, .value = try it.eval(a.value, piped) };
        return it.world.call(it.world.ctx, it.gpa, cap, method, args, piped, &it.why) catch error.Failed;
    }

    fn binary(it: *Interp, op: Tag, a: Value, b: Value) Error!Value {
        switch (op) {
            .eq, .ne => {
                const same = equal(a, b);
                return .{ .boolean = if (op == .eq) same else !same };
            },
            .plus => if (a == .text and b == .text) {
                return .{ .text = try std.mem.concat(it.gpa, u8, &.{ a.text, b.text }) };
            },
            else => {},
        }
        const x = try it.integer(a, "arithmetic");
        const y = try it.integer(b, "arithmetic");
        return switch (op) {
            .plus => .{ .int = x + y },
            .minus => .{ .int = x - y },
            .star => .{ .int = std.math.mul(i128, x, y) catch return it.fail("too large", .{}) },
            .slash, .percent => blk: {
                if (y == 0) return it.fail("division by zero", .{});
                break :blk .{ .int = if (op == .slash) @divTrunc(x, y) else @rem(x, y) };
            },
            .lt => .{ .boolean = x < y },
            .le => .{ .boolean = x <= y },
            .gt => .{ .boolean = x > y },
            .ge => .{ .boolean = x >= y },
            else => unreachable,
        };
    }
};

fn equal(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .none => true,
        .int => |x| x == b.int,
        .boolean => |x| x == b.boolean,
        .text => |x| std.mem.eql(u8, x, b.text),
        .bytes => |x| std.mem.eql(u8, x, b.bytes),
        .record => |x| blk: {
            if (x.len != b.record.len) break :blk false;
            for (x, b.record) |f, g| if (!std.mem.eql(u8, f.name, g.name) or !equal(f.value, g.value)) break :blk false;
            break :blk true;
        },
    };
}

fn unescape(gpa: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            try out.append(gpa, switch (raw[i]) {
                'n' => '\n',
                't' => '\t',
                else => raw[i],
            });
        } else try out.append(gpa, raw[i]);
    }
    return out.items;
}

/// A value as text: records as {name: value, ...}, bytes in hex (long
/// ones shortened), text quoted inside records or when `quote`.
pub fn format(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: Value, quote: bool) Error!void {
    switch (v) {
        .none => try out.appendSlice(gpa, "none"),
        .int => |n| try out.print(gpa, "{d}", .{n}),
        .boolean => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
        .text => |t| if (quote) try out.print(gpa, "\"{s}\"", .{t}) else try out.appendSlice(gpa, t),
        .bytes => |b| {
            try out.appendSlice(gpa, "0x");
            for (b[0..@min(b.len, 16)]) |c| try out.print(gpa, "{x:0>2}", .{c});
            if (b.len > 16) try out.print(gpa, "... ({d} bytes)", .{b.len});
        },
        .record => |fields| {
            try out.appendSlice(gpa, "{");
            for (fields, 0..) |f, i| {
                if (i > 0) try out.appendSlice(gpa, ", ");
                try out.print(gpa, "{s}: ", .{f.name});
                try format(gpa, out, f.value, true);
            }
            try out.appendSlice(gpa, "}");
        },
    }
}

// ---------------------------------------------------------------------------
// Tests: a stand-in world with a key-value store and an identity.

const Fake = struct {
    store: [16]?i128 = @splat(null),
    calls: usize = 0,

    fn has(_: *anyopaque, cap: []const u8) bool {
        return std.mem.eql(u8, cap, "kv") or std.mem.eql(u8, cap, "kumara");
    }

    fn arg(args: []const Field, from: ?Value, name: []const u8) ?Value {
        for (args) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        if (from) |f| return f.field(name);
        return null;
    }

    fn call(ctx: *anyopaque, gpa: std.mem.Allocator, cap: []const u8, method: []const u8, args: []const Field, from: ?Value, why: *Why) error{Failed}!Value {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.calls += 1;
        if (std.mem.eql(u8, cap, "kumara") and std.mem.eql(u8, method, "whoami")) {
            const fields = gpa.dupe(Field, &.{ .{ .name = "name", .value = .{ .text = "kelp-oryx-lute" } }, .{ .name = "public_key", .value = .{ .bytes = &.{ 0xab, 0xcd } } } }) catch return error.Failed;
            return .{ .record = fields };
        }
        if (!std.mem.eql(u8, cap, "kv")) {
            why.set("{s} has no method {s}", .{ cap, method });
            return error.Failed;
        }
        const key = arg(args, from, "key") orelse {
            why.set("{s}.{s} needs key", .{ cap, method });
            return error.Failed;
        };
        const k: usize = @intCast(key.int);
        if (std.mem.eql(u8, method, "put")) {
            const v = arg(args, from, "value") orelse {
                why.set("kv.put needs value", .{});
                return error.Failed;
            };
            const had = f.store[k] != null;
            f.store[k] = v.int;
            const fields = gpa.dupe(Field, &.{.{ .name = "had", .value = .{ .boolean = had } }}) catch return error.Failed;
            return .{ .record = fields };
        }
        if (std.mem.eql(u8, method, "get")) {
            const fields = gpa.dupe(Field, &.{ .{ .name = "found", .value = .{ .boolean = f.store[k] != null } }, .{ .name = "value", .value = .{ .int = f.store[k] orelse 0 } } }) catch return error.Failed;
            return .{ .record = fields };
        }
        why.set("kv has no method {s}", .{method});
        return error.Failed;
    }

    fn list(_: *anyopaque, out: Out) void {
        out.line(out.ctx, "kv  kv.v1");
        out.line(out.ctx, "kumara  kumara.v1");
    }

    fn describe(_: *anyopaque, cap: []const u8, out: Out) bool {
        if (!std.mem.eql(u8, cap, "kv")) return false;
        out.line(out.ctx, "get(key: u64) -> (found: bool, value: u64)");
        return true;
    }

    fn world(f: *Fake) World {
        return .{ .ctx = f, .has = has, .call = call, .list = list, .describe = describe };
    }
};

const Lines = struct {
    buf: [32][128]u8 = undefined,
    lens: [32]usize = undefined,
    n: usize = 0,

    fn line(ctx: *anyopaque, text: []const u8) void {
        const l: *Lines = @ptrCast(@alignCast(ctx));
        const len = @min(text.len, 128);
        @memcpy(l.buf[l.n][0..len], text[0..len]);
        l.lens[l.n] = len;
        l.n += 1;
    }

    fn get(l: *const Lines, i: usize) []const u8 {
        return l.buf[i][0..l.lens[i]];
    }

    fn out(l: *Lines) Out {
        return .{ .ctx = l, .line = line };
    }
};

fn expectRun(it: *Interp, lines: *Lines, src: []const u8, want: []const []const u8) !void {
    lines.n = 0;
    it.run(src) catch |e| {
        std.debug.print("{s}: {s}\n", .{ @errorName(e), it.why.text() });
        return e;
    };
    try std.testing.expectEqual(want.len, lines.n);
    for (want, 0..) |w, i| try std.testing.expectEqualStrings(w, lines.get(i));
}

fn expectFail(it: *Interp, src: []const u8, why: []const u8) !void {
    try std.testing.expectError(error.Failed, it.run(src) catch |e| switch (e) {
        error.Syntax => error.Failed,
        else => e,
    });
    if (std.mem.indexOf(u8, it.why.text(), why) == null) {
        std.debug.print("want '{s}' in '{s}'\n", .{ why, it.why.text() });
        return error.TestUnexpectedResult;
    }
}

test "calls, records, fields, variables" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    var lines: Lines = .{};
    var it = Interp.init(arena.allocator(), fake.world(), lines.out());
    try expectRun(&it, &lines, "kv.put key=7 value=42", &.{"{had: false}"});
    try expectRun(&it, &lines, "kv.get key=7", &.{"{found: true, value: 42}"});
    try expectRun(&it, &lines, "let r = kv.get key=7; print r.value + 1", &.{"43"});
    try expectRun(&it, &lines, "kumara.whoami", &.{"{name: \"kelp-oryx-lute\", public_key: 0xabcd}"});
    try expectRun(&it, &lines, "print kumara.whoami.name", &.{"kelp-oryx-lute"});
    try expectRun(&it, &lines, "(kv.get key=7).value * 2", &.{"84"});
}

test "pipes select fields and fill arguments from the left" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    var lines: Lines = .{};
    var it = Interp.init(arena.allocator(), fake.world(), lines.out());
    try expectRun(&it, &lines, "kumara.whoami | .name", &.{"\"kelp-oryx-lute\""});
    _ = try it.run("kv.put key=1 value=5");
    // The record {found, value} fills put's missing `value`; key is given.
    try expectRun(&it, &lines, "kv.get key=1 | kv.put key=2", &.{"{had: false}"});
    try std.testing.expectEqual(@as(?i128, 5), fake.store[2]);
    try expectRun(&it, &lines, "kv.get key=2 | _.value + 1", &.{"6"});
}

test "loops, conditions, arithmetic, text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    var lines: Lines = .{};
    var it = Interp.init(arena.allocator(), fake.world(), lines.out());
    try expectRun(&it, &lines, "for i in 0..4 { kv.put key=i value=(i*i) }", &.{});
    try std.testing.expectEqual(@as(?i128, 9), fake.store[3]);
    try expectRun(&it, &lines, "for i in 1..3 { print i, (kv.get key=i).value }", &.{ "1 1", "2 4" });
    try expectRun(&it, &lines, "if (kv.get key=9).found { print \"yes\" } else { print \"no\" }", &.{"no"});
    try expectRun(&it, &lines, "if 2 > 1 and not false { print \"a\" + \"b\" }", &.{"ab"});
    try expectRun(&it, &lines, "print 7 / 2, 7 % 2, -3 + 0x10, 1 == 1, \"x\" != \"y\"", &.{"3 1 13 true true"});
    try expectRun(&it, &lines, "let n = 0\nfor i in 0..10 { let n = n + i }\nprint n", &.{"45"});
    try expectRun(&it, &lines, "print \"tab\\there\" # a comment", &.{"tab\there"});
}

test "errors say what and where" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    var lines: Lines = .{};
    var it = Interp.init(arena.allocator(), fake.world(), lines.out());
    try expectFail(&it, "store.get key=1", "no capability named 'store'");
    try expectFail(&it, "kv.get", "needs key");
    try expectFail(&it, "kv", "is a capability");
    try expectFail(&it, "print x", "nothing is named 'x'");
    try expectFail(&it, "(kv.get key=1).valu", "no field 'valu' (it has found, value)");
    try expectFail(&it, "kv.get key=", "column 12: expected a value");
    try expectFail(&it, "print \"open", "no closing quote");
    try expectFail(&it, "if 1 { }", "must be true or false");
    try expectFail(&it, "print 1 / 0", "division by zero");
    try expectFail(&it, "kv.get key=1 }", "column 14: expected ';'");
    try expectFail(&it, "print _", "there is no pipe here");
    try expectFail(&it, "describe nope", "no capability named 'nope'");
    try std.testing.expectError(error.TooMuch, it.run("for i in 0..1000000000 { let x = i }"));
}

test "caps, describe and help go to the world and the output" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var fake: Fake = .{};
    var lines: Lines = .{};
    var it = Interp.init(arena.allocator(), fake.world(), lines.out());
    try expectRun(&it, &lines, "caps", &.{ "kv  kv.v1", "kumara  kumara.v1" });
    try expectRun(&it, &lines, "describe kv", &.{"get(key: u64) -> (found: bool, value: u64)"});
    lines.n = 0;
    try it.run("help");
    try std.testing.expectEqual(help_text.len, lines.n);
}
