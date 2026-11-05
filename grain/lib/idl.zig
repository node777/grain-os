//! Zig as the interface definition language.
//!
//! A protocol is a Zig file with `name`, `version`, `doc`, and one
//! declaration per method:
//!
//!     pub const ping = idl.Method(.{ .label = 1, .effect = .pure, .doc = "..." },
//!         struct { value: u64, pub const docs = .{ .value = "..." }; },   // params
//!         struct { value: u64, pub const docs = .{ .value = "..." }; });  // results
//!
//! From that, `comptime` makes everything else:
//!   - `call(Proto.method, ep, args)`: a typed client call;
//!   - `serve(Proto, ep, impl)`: server dispatch to `impl.<method>(params, caller)`;
//!   - the wire encoding: up to 64 message words each way, the first five in
//!     registers and the rest through the IPC buffer (the kernel copies them);
//!   - `descriptor(Proto)`: canonical JSON naming every method, parameter,
//!     result, type, effect and doc, for the Registry and for agents;
//!   - `id(Proto)`: a 64-bit hash of that descriptor. Steward stamps its low
//!     16 bits on endpoint capabilities, and the kernel refuses a message
//!     whose sender and receiver disagree.
const std = @import("std");
const grain = @import("grain.zig");

/// What calling a method does to the world. Agents use this to plan.
pub const Effect = enum {
    /// Reads only; calling it again gives the same answer and changes nothing.
    pure,
    /// Changes the service's state.
    mutates,
    /// Acts on the outside world (output, a device); cannot be taken back.
    external,
};

pub const MethodSpec = struct {
    label: u32,
    doc: []const u8,
    effect: Effect,
    /// A method of the same protocol that reverses this one. Its parameters
    /// are filled by name from this call's results, then its arguments.
    undo: ?[]const u8 = null,
};

pub const register_words = 5;
pub const max_words = 64;
/// One message's words: 0..4 in registers, 5..63 in the IPC buffer.
pub const Words = [max_words]usize;

pub fn Method(comptime spec: MethodSpec, comptime P: type, comptime R: type) type {
    comptime {
        if (spec.label == 0) @compileError("method labels start at 1");
        if (words(P) > max_words) @compileError("parameters need " ++ std.fmt.comptimePrint("{d}", .{words(P)}) ++ " words; a message holds 64");
        if (words(R) > max_words) @compileError("results need " ++ std.fmt.comptimePrint("{d}", .{words(R)}) ++ " words; a message holds 64");
    }
    return struct {
        pub const idl_method = true;
        pub const label = spec.label;
        pub const doc = spec.doc;
        pub const effect = spec.effect;
        pub const undo = spec.undo;
        pub const Params = P;
        pub const Results = R;
    };
}

/// The most bytes a `Bytes`/`Text` field can hold: a message is 64 words,
/// one of them the length.
pub const max_bytes = (max_words - 1) * 8;

/// Up to `n` bytes of binary data (agents see hex), carried as a length word
/// plus packed words.
pub fn Bytes(comptime n: usize) type {
    return Sized(n, false);
}

/// Up to `n` bytes of UTF-8 text (agents see a string).
pub fn Text(comptime n: usize) type {
    return Sized(n, true);
}

fn Sized(comptime n: usize, comptime text: bool) type {
    comptime std.debug.assert(n > 0 and n <= max_bytes);
    return struct {
        pub const idl_bytes = n;
        pub const idl_text = text;
        len: u16 = 0,
        data: [n]u8 = @splat(0),

        pub fn from(s: []const u8) @This() {
            var b: @This() = .{};
            b.len = @intCast(@min(s.len, n));
            @memcpy(b.data[0..b.len], s[0..b.len]);
            return b;
        }

        pub fn slice(b: *const @This()) []const u8 {
            return b.data[0..@min(b.len, n)];
        }
    };
}

pub const ErrorCode = enum(usize) {
    failed = 1,
    invalid_args = 2,
    not_found = 3,
    unavailable = 4,
    unknown_method = 5,
    _,
};

pub const CallError = error{ Failed, InvalidArgs, NotFound, Unavailable, UnknownMethod, Transport };

fn errorOf(code: ErrorCode) CallError {
    return switch (code) {
        .invalid_args => error.InvalidArgs,
        .not_found => error.NotFound,
        .unavailable => error.Unavailable,
        .unknown_method => error.UnknownMethod,
        else => error.Failed,
    };
}

pub fn codeOf(e: anyerror) ErrorCode {
    return switch (e) {
        error.InvalidArgs => .invalid_args,
        error.NotFound => .not_found,
        error.Unavailable => .unavailable,
        error.UnknownMethod => .unknown_method,
        else => .failed,
    };
}

// ---------------------------------------------------------------------------
// Types and encoding

fn isBytes(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "idl_bytes");
}

/// A capability passed with a call (parameters only). It travels in the IPC
/// buffer, not as words, and only if the caller's capability to the
/// endpoint has the `grant` right. The server finds it in `recv_slot` and
/// must move it elsewhere to keep it; it is deleted after the handler.
pub const Cap = struct {
    pub const idl_cap = true;
    slot: grain.CPtr = 0,
};

fn isCap(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "idl_cap");
}

/// Where a server receives a `Cap` parameter: an empty slot of its own, set
/// before serving (0: capabilities are not accepted).
pub var recv_slot: grain.CPtr = 0;

fn fieldWords(comptime T: type) usize {
    if (comptime isBytes(T)) return 1 + (T.idl_bytes + 7) / 8;
    if (comptime isCap(T)) return 0;
    return switch (@typeInfo(T)) {
        .int, .bool, .@"enum" => 1,
        else => @compileError("idl: unsupported field type " ++ @typeName(T) ++ " (use u8..u64, i64, bool, an enum, or idl.Bytes(n))"),
    };
}

pub fn words(comptime T: type) usize {
    const n = comptime blk: {
        var c: usize = 0;
        for (std.meta.fieldNames(T)) |f| c += fieldWords(@FieldType(T, f));
        break :blk c;
    };
    return n;
}

pub fn encode(comptime T: type, v: T) Words {
    var out: Words = @splat(0);
    var i: usize = 0;
    inline for (comptime std.meta.fieldNames(T)) |f| {
        const F = @FieldType(T, f);
        const x = @field(v, f);
        if (comptime isCap(F)) {
            // Not a word: see `call`.
        } else if (comptime isBytes(F)) {
            out[i] = x.len;
            var buf: [((F.idl_bytes + 7) / 8) * 8]u8 = @splat(0);
            @memcpy(buf[0..F.idl_bytes], &x.data);
            inline for (0..(F.idl_bytes + 7) / 8) |k| out[i + 1 + k] = std.mem.readInt(u64, buf[k * 8 ..][0..8], .little);
            i += 1 + (F.idl_bytes + 7) / 8;
        } else {
            out[i] = switch (@typeInfo(F)) {
                .int => |info| if (info.signedness == .signed) @bitCast(@as(i64, x)) else x,
                .bool => @intFromBool(x),
                .@"enum" => @backingInt(x),
                else => unreachable,
            };
            i += 1;
        }
    }
    return out;
}

pub fn decode(comptime T: type, w: *const Words) error{InvalidArgs}!T {
    var v: T = undefined;
    var i: usize = 0;
    inline for (comptime std.meta.fieldNames(T)) |f| {
        const F = @FieldType(T, f);
        if (comptime isCap(F)) {
            @field(v, f) = .{}; // filled in by the server loop
        } else if (comptime isBytes(F)) {
            var b: F = .{};
            if (w[i] > F.idl_bytes) return error.InvalidArgs;
            b.len = @intCast(w[i]);
            var buf: [((F.idl_bytes + 7) / 8) * 8]u8 = undefined;
            inline for (0..(F.idl_bytes + 7) / 8) |k| std.mem.writeInt(u64, buf[k * 8 ..][0..8], w[i + 1 + k], .little);
            @memcpy(&b.data, buf[0..F.idl_bytes]);
            @field(v, f) = b;
            i += 1 + (F.idl_bytes + 7) / 8;
        } else {
            @field(v, f) = switch (@typeInfo(F)) {
                .int => |info| if (info.signedness == .signed)
                    std.math.cast(F, @as(i64, @bitCast(w[i]))) orelse return error.InvalidArgs
                else
                    std.math.cast(F, w[i]) orelse return error.InvalidArgs,
                .bool => switch (w[i]) {
                    0 => false,
                    1 => true,
                    else => return error.InvalidArgs,
                },
                .@"enum" => std.enums.fromInt(F, w[i]) orelse return error.InvalidArgs,
                else => unreachable,
            };
            i += 1;
        }
    }
    return v;
}

// ---------------------------------------------------------------------------
// Protocols

/// Method declaration names of a protocol, in declaration order.
pub fn methodNames(comptime P: type) []const []const u8 {
    const names = comptime blk: {
        var list: []const []const u8 = &.{};
        for (@typeInfo(P).@"struct".decl_names) |n| {
            const d = @field(P, n);
            if (@TypeOf(d) == type and @typeInfo(d) == .@"struct" and @hasDecl(d, "idl_method")) list = list ++ .{n};
        }
        break :blk list;
    };
    return names;
}

pub fn fullName(comptime P: type) []const u8 {
    return P.name ++ ".v" ++ std.fmt.comptimePrint("{d}", .{P.version});
}

pub fn id(comptime P: type) u64 {
    const h = comptime blk: {
        @setEvalBranchQuota(10_000_000);
        break :blk std.hash.Fnv1a_64.hash(descriptor(P));
    };
    return h;
}

/// The 16 bits of the id the kernel checks on endpoint capabilities (never 0).
pub fn kernelId(comptime P: type) u16 {
    const low: u16 = @truncate(id(P));
    return if (low == 0) 1 else low;
}

fn jsonString(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "\"";
        for (s) |c| out = out ++ switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            else => &[_]u8{c},
        };
        return out ++ "\"";
    }
}

pub fn typeName(comptime T: type) []const u8 {
    comptime {
        if (isBytes(T)) return std.fmt.comptimePrint("{s}({d})", .{ if (T.idl_text) "text" else "bytes", T.idl_bytes });
        if (isCap(T)) return "cap";
        return switch (@typeInfo(T)) {
            .int => @typeName(T),
            .bool => "bool",
            .@"enum" => blk: {
                var s: []const u8 = "enum(";
                for (std.meta.fieldNames(T), 0..) |n, i| s = s ++ (if (i > 0) "|" else "") ++ n;
                break :blk s ++ ")";
            },
            else => unreachable,
        };
    }
}

fn fieldsJson(comptime T: type) []const u8 {
    comptime {
        var s: []const u8 = "[";
        for (std.meta.fieldNames(T), 0..) |f, i| {
            const doc = if (@hasDecl(T, "docs") and @hasField(@TypeOf(T.docs), f)) @field(T.docs, f) else "";
            s = s ++ (if (i > 0) "," else "") ++ "{\"name\":" ++ jsonString(f) ++ ",\"type\":" ++ jsonString(typeName(@FieldType(T, f))) ++ ",\"doc\":" ++ jsonString(doc) ++ "}";
        }
        return s ++ "]";
    }
}

/// Canonical JSON describing the protocol (stable field order, no spaces).
pub fn descriptor(comptime P: type) []const u8 {
    const d = comptime descriptorText(P);
    return d;
}

fn descriptorText(comptime P: type) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var s: []const u8 = "{\"protocol\":" ++ jsonString(fullName(P)) ++ ",\"doc\":" ++ jsonString(P.doc) ++ ",\"methods\":[";
        for (methodNames(P), 0..) |n, i| {
            const M = @field(P, n);
            s = s ++ (if (i > 0) "," else "") ++ "{\"name\":" ++ jsonString(n) ++
                std.fmt.comptimePrint(",\"label\":{d}", .{M.label}) ++
                ",\"effect\":" ++ jsonString(@tagName(M.effect)) ++
                ",\"undo\":" ++ (if (M.undo) |u| jsonString(u) else "null") ++
                ",\"doc\":" ++ jsonString(M.doc) ++
                ",\"params\":" ++ fieldsJson(M.Params) ++
                ",\"results\":" ++ fieldsJson(M.Results) ++ "}";
        }
        return s ++ "]}";
    }
}

/// Compile-time checks for a protocol: unique labels, and every undo names
/// a method whose parameters can all be filled from this method's results
/// and arguments.
pub fn check(comptime P: type) void {
    comptime {
        const names = methodNames(P);
        if (names.len == 0) @compileError(fullName(P) ++ " declares no methods");
        for (names, 0..) |a, i| for (names[0..i]) |b| {
            if (@field(P, a).label == @field(P, b).label) @compileError(fullName(P) ++ ": methods '" ++ a ++ "' and '" ++ b ++ "' share a label");
        };
        for (names) |n| {
            const M = @field(P, n);
            if (M.undo) |u| {
                if (!@hasDecl(P, u)) @compileError(fullName(P) ++ "." ++ n ++ ": undo names unknown method '" ++ u ++ "'");
                const U = @field(P, u);
                for (std.meta.fieldNames(U.Params)) |f| {
                    if (!@hasField(M.Results, f) and !@hasField(M.Params, f))
                        @compileError(fullName(P) ++ "." ++ n ++ ": undo method '" ++ u ++ "' needs '" ++ f ++ "', which is neither a result nor an argument");
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Calls and serving

fn ipcWords() *Words {
    const ib: *grain.abi.IpcBuffer = @ptrFromInt(grain.ipc_buffer);
    return &ib.words;
}

/// Send-side half of a message: words 5.. go to the IPC buffer, 0..4 are
/// returned for the registers.
fn scatter(w: *const Words, n: usize) [register_words]usize {
    if (n > register_words) @memcpy(ipcWords()[register_words..n], w[register_words..n]);
    return w[0..register_words].*;
}

/// Receive-side half: a message's words, wherever they arrived.
fn gather(r: grain.Result) Words {
    var w: Words = @splat(0);
    w[0..register_words].* = r.w;
    const n = @min(r.tag.length, max_words);
    if (n > register_words) @memcpy(w[register_words..n], ipcWords()[register_words..n]);
    return w;
}

/// Call method `M` with already-encoded words; the raw result.
pub fn callWords(ep: grain.CPtr, label: u32, w: *const Words, n: usize) RawResult {
    return callWordsCaps(ep, label, w, n, 0);
}

pub const RawResult = struct { r: grain.Result, w: Words };

fn callWordsCaps(ep: grain.CPtr, label: u32, w: *const Words, n: usize, caps: u3) RawResult {
    const r = grain.syscall(.call, ep, @bitCast(grain.Tag{ .label = label, .length = @intCast(n), .caps = caps }), scatter(w, n));
    return .{ .r = r, .w = gather(r) };
}

/// Put a call's `Cap` parameters in the IPC buffer; returns how many.
fn sendCaps(comptime T: type, v: T) u3 {
    var n: u3 = 0;
    inline for (comptime std.meta.fieldNames(T)) |f| if (comptime isCap(@FieldType(T, f))) {
        const ib: *grain.abi.IpcBuffer = @ptrFromInt(grain.ipc_buffer);
        ib.send_caps[n] = @field(v, f).slot;
        n += 1;
    };
    return n;
}

/// A typed call: `try idl.call(echo.ping, ep, .{ .value = 41 })`.
pub fn call(comptime M: type, ep: grain.CPtr, args: M.Params) CallError!M.Results {
    const w = encode(M.Params, args);
    const out = callWordsCaps(ep, M.label, &w, words(M.Params), sendCaps(M.Params, args));
    if (out.r.status != .ok) return error.Transport;
    if (out.r.tag.label != 0) return errorOf(@fromBackingInt(@intCast(out.w[0])));
    return decode(M.Results, &out.w) catch error.Failed;
}

/// The raw status of the last failed transport, for callers that need it.
pub fn callStatus(comptime M: type, ep: grain.CPtr, args: M.Params) struct { status: grain.Status, label: u32, results: ?M.Results, code: usize } {
    const w = encode(M.Params, args);
    const out = callWords(ep, M.label, &w, words(M.Params));
    if (out.r.status != .ok or out.r.tag.label != 0) return .{ .status = out.r.status, .label = out.r.tag.label, .results = null, .code = out.w[0] };
    return .{ .status = out.r.status, .label = 0, .results = decode(M.Results, &out.w) catch null, .code = 0 };
}

/// Who is calling: the badge Steward gave their capability, and the protocol
/// it speaks (the kernel delivers both; neither can be forged).
pub const Caller = struct { badge: usize, protocol: u16 = 0 };

/// Serve protocol `P` on `ep` forever: each request goes to
/// `impl.<method>(params, caller) !Results`.
pub fn serve(comptime P: type, ep: grain.CPtr, impl: anytype) noreturn {
    serveAll(.{P}, ep, impl);
}

/// Serve several protocols on one endpoint. The kernel tells the server
/// which protocol each message speaks (the sender's capability), so a label
/// is only ever read as a method of the protocol the caller holds. `impl`
/// has every protocol's methods; their names must not clash. An unstamped
/// sender (Steward) speaks the first protocol.
pub fn serveAll(comptime protocols: anytype, ep: grain.CPtr, impl: anytype) noreturn {
    comptime {
        for (protocols, 0..) |P, i| {
            check(P);
            for (protocols, 0..) |Q, j| if (j < i) for (methodNames(P)) |a| for (methodNames(Q)) |b| {
                if (std.mem.eql(u8, a, b)) @compileError(fullName(P) ++ " and " ++ fullName(Q) ++ " both have a method '" ++ a ++ "'; one endpoint cannot serve both");
            };
        }
    }
    const ib: *grain.abi.IpcBuffer = @ptrFromInt(grain.ipc_buffer);
    ib.recv_slots[0] = recv_slot;
    var r = grain.recv(ep);
    while (true) {
        if (r.signalled) {
            // The thread's bound signal fired (devices, timers): no caller.
            if (@hasDecl(@TypeOf(impl.*), "onSignal")) impl.onSignal(r.w[0]);
            r = grain.recv(ep);
            continue;
        }
        const rep = dispatch(protocols, impl, r);
        r = grain.syscall(.reply_recv, ep, @bitCast(grain.Tag{ .label = rep.label, .length = rep.len }), scatter(&rep.w, rep.len));
    }
}

/// The answer to one request: a label (0 = ok, else an error code in w[0])
/// and words.
pub const Reply = struct { label: u32, w: Words, len: u7 };

/// Handle one received request `r` (see serveAll); the caller replies. For
/// a server with a loop of its own (Steward's).
pub fn dispatch(comptime protocols: anytype, impl: anytype, r: grain.Result) Reply {
    const req = gather(r);
    var reply_label: u32 = 1;
    var reply: Words = @splat(0);
    reply[0] = @backingInt(ErrorCode.unknown_method);
    var reply_len: u7 = 1;
    inline for (protocols, 0..) |P, pi| {
        const speaks = r.protocol == kernelId(P) or (r.protocol == 0 and pi == 0);
        if (speaks) inline for (comptime methodNames(P)) |n| {
            const M = @field(P, n);
            if (r.tag.label == M.label) {
                if (decode(M.Params, &req)) |decoded| {
                    var params = decoded;
                    inline for (comptime std.meta.fieldNames(M.Params)) |f| if (comptime isCap(@FieldType(M.Params, f))) {
                        @field(params, f).slot = if (r.tag.caps > 0) recv_slot else 0;
                    };
                    if (@field(@TypeOf(impl.*), n)(impl, params, .{ .badge = r.badge, .protocol = r.protocol })) |res| {
                        reply_label = 0;
                        reply = encode(M.Results, res);
                        reply_len = @intCast(words(M.Results));
                    } else |e| {
                        reply[0] = @backingInt(codeOf(e));
                    }
                } else |_| {
                    reply[0] = @backingInt(ErrorCode.invalid_args);
                }
            }
        };
    }
    // A capability the handler did not move is dropped, so the slot is
    // empty for the next one.
    if (r.tag.caps > 0 and recv_slot != 0) _ = grain.invoke(grain.S.cnode, grain.abi.CNodeMethod.delete, .{recv_slot});
    return .{ .label = reply_label, .w = reply, .len = reply_len };
}

/// Reply to the request just received with `rep`.
pub fn sendReply(rep: *const Reply) grain.Result {
    return grain.syscall(.reply, 0, @bitCast(grain.Tag{ .label = rep.label, .length = rep.len }), scatter(&rep.w, rep.len));
}

test "encode and decode round-trip; descriptors and ids are stable" {
    const P = struct {
        pub const name = "demo";
        pub const version = 2;
        pub const doc = "A \"demo\" protocol.";
        pub const Color = enum { red, green };
        pub const paint = Method(.{ .label = 1, .effect = .mutates, .doc = "Paint.", .undo = "unpaint" }, struct {
            color: Color,
            label: Text(16),
            blob: Bytes(300),
            pub const docs = .{ .color = "Which colour" };
        }, struct { previous: Color, count: u32 });
        pub const unpaint = Method(.{ .label = 2, .effect = .mutates, .doc = "Undo a paint." }, struct { previous: Color }, struct {});
    };
    comptime check(P);
    var big: [300]u8 = undefined;
    for (&big, 0..) |*c, i| c.* = @truncate(i *% 7);
    const v: P.paint.Params = .{ .color = .green, .label = Text(16).from("hello"), .blob = Bytes(300).from(&big) };
    const w = encode(P.paint.Params, v);
    const back = try decode(P.paint.Params, &w);
    try std.testing.expectEqual(P.Color.green, back.color);
    try std.testing.expectEqualStrings("hello", back.label.slice());
    try std.testing.expectEqualSlices(u8, &big, back.blob.slice());
    var bad: Words = @splat(0);
    bad[0] = 7;
    try std.testing.expectError(error.InvalidArgs, decode(P.paint.Params, &bad));
    const d = comptime descriptor(P);
    try std.testing.expect(std.mem.indexOf(u8, d, "\"protocol\":\"demo.v2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "{\"name\":\"color\",\"type\":\"enum(red|green)\",\"doc\":\"Which colour\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "A \\\"demo\\\" protocol.") != null);
    var a: std.json.Scanner = .initCompleteInput(std.testing.allocator, d);
    defer a.deinit();
    while (try a.next() != .end_of_document) {}
    try std.testing.expect(comptime id(P) != 0);
    try std.testing.expectEqual(@as(usize, 4 + 1 + 38), comptime words(P.paint.Params));
    try std.testing.expect(std.mem.indexOf(u8, d, "\"type\":\"text(16)\"") != null and std.mem.indexOf(u8, d, "\"type\":\"bytes(300)\"") != null);
}
