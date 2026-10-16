//! Envoy: how an AI agent (or a script, or a person) operates Grain.
//!
//! Envoy drives its own virtio-console device and speaks JSON lines: one
//! request object per line in, one response object per line out.
//!
//!   {"id":1,"verb":"discover"}
//!   {"id":1,"ok":true,"result":{"capabilities":[...]}}
//!
//! The agent is a principal with exactly the services the manifest's
//! `agent` section grants, each held as a kernel lease. Envoy cannot widen
//! that authority: it can only use the leases, and `ask` for more, which
//! Steward approves or refuses on the owner's behalf.
//!
//! Verbs: hello, discover, describe, call, plan, apply, undo, ask, observe, bye.
//! Every verb that uses authority is recorded in a hash-chained audit log
//! (`observe`), so the agent's actions can always be accounted for.
const std = @import("std");
const g = @import("grain");
const proto = @import("proto");
const idl = g.idl;
const abi = g.abi;
const D = g.domain;
const virtio = g.virtio;
const Value = std.json.Value;
const Blake3 = std.crypto.hash.Blake3;

pub const panic = g.panic;
comptime {
    g.exportStart();
}

// ---------------------------------------------------------------------------
// Transport: the second virtio console

const rx_buffers = 16;
const rx_size = 256;

const Port = struct {
    dev: virtio.Device,
    rx: virtio.Queue,
    tx: virtio.Queue,
    rx_page: virtio.Dma,
    tx_page: virtio.Dma,
    signal: g.CPtr,
    irq: g.CPtr,
    line: [4096]u8 = undefined,
    line_len: usize = 0,
    pending: [rx_size * 2]u8 = undefined,
    pending_len: usize = 0,
    pending_off: usize = 0,

    fn waitIrq(p: *Port) void {
        _ = g.wait(p.signal);
        _ = p.dev.ackInterrupt();
        _ = g.invoke(p.irq, abi.IrqMethod.ack, .{});
    }

    fn nextByte(p: *Port) u8 {
        while (p.pending_off == p.pending_len) {
            if (p.rx.poll()) |used| {
                const id: u16 = @intCast(used.id);
                const buf = p.rx_page.bytes()[@as(usize, id) * rx_size ..][0..rx_size];
                const n = @min(used.len, rx_size);
                @memcpy(p.pending[0..n], buf[0..n]);
                p.pending_len = n;
                p.pending_off = 0;
                p.rx.submitDesc(id, p.rx_page.pa + @as(u64, id) * rx_size, rx_size, true);
            } else p.waitIrq();
        }
        const c = p.pending[p.pending_off];
        p.pending_off += 1;
        return c;
    }

    /// One request line (without the newline). Over-long lines are cut.
    fn readLine(p: *Port) []const u8 {
        p.line_len = 0;
        while (true) {
            const c = p.nextByte();
            if (c == '\n') return p.line[0..p.line_len];
            if (c == '\r') continue;
            if (p.line_len < p.line.len) {
                p.line[p.line_len] = c;
                p.line_len += 1;
            }
        }
    }

    fn write(p: *Port, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = @min(rest.len, 4096);
            @memcpy(p.tx_page.bytes()[0..n], rest[0..n]);
            _ = p.tx.submit(p.tx_page.pa, @intCast(n), false) catch return;
            while (p.tx.poll() == null) p.waitIrq();
            rest = rest[n..];
        }
    }
};

// ---------------------------------------------------------------------------
// A small JSON writer: Envoy controls every response shape.

/// Comma rules: `field(k)` starts a member of the current object; values
/// written right after it take no comma; values in arrays are separated.
const Out = struct {
    buf: [16384]u8 = undefined,
    len: usize = 0,
    first: [32]bool = undefined,
    depth: usize = 0,
    overflow: bool = false,
    after_key: bool = false,

    fn raw(o: *Out, s: []const u8) void {
        if (o.len + s.len > o.buf.len) {
            o.overflow = true;
            return;
        }
        @memcpy(o.buf[o.len..][0..s.len], s);
        o.len += s.len;
    }

    fn valueSep(o: *Out) void {
        if (o.after_key) {
            o.after_key = false;
            return;
        }
        if (o.first[o.depth]) o.first[o.depth] = false else o.raw(",");
    }

    fn strRaw(o: *Out, s: []const u8) void {
        o.raw("\"");
        for (s) |c| switch (c) {
            '"' => o.raw("\\\""),
            '\\' => o.raw("\\\\"),
            '\n' => o.raw("\\n"),
            0...9, 11...0x1f, 0x7f => {
                var b: [6]u8 = undefined;
                o.raw(std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch "?");
            },
            else => o.raw(&[_]u8{c}),
        };
        o.raw("\"");
    }

    fn field(o: *Out, k: []const u8) void {
        if (o.first[o.depth]) o.first[o.depth] = false else o.raw(",");
        o.strRaw(k);
        o.raw(":");
        o.after_key = true;
    }

    fn str(o: *Out, s: []const u8) void {
        o.valueSep();
        o.strRaw(s);
    }
    fn num(o: *Out, v: anytype) void {
        o.valueSep();
        var b: [24]u8 = undefined;
        o.raw(std.fmt.bufPrint(&b, "{d}", .{v}) catch "0");
    }
    fn boolean(o: *Out, v: bool) void {
        o.valueSep();
        o.raw(if (v) "true" else "false");
    }
    fn nul(o: *Out) void {
        o.valueSep();
        o.raw("null");
    }
    /// Already-encoded JSON (the Registry's descriptors).
    fn json(o: *Out, s: []const u8) void {
        o.valueSep();
        o.raw(s);
    }
    fn hex(o: *Out, bytes: []const u8) void {
        o.valueSep();
        o.raw("\"");
        for (bytes) |c| {
            var b: [2]u8 = undefined;
            o.raw(std.fmt.bufPrint(&b, "{x:0>2}", .{c}) catch "??");
        }
        o.raw("\"");
    }
    fn obj(o: *Out) void {
        o.valueSep();
        o.raw("{");
        o.depth += 1;
        o.first[o.depth] = true;
    }
    fn arr(o: *Out) void {
        o.valueSep();
        o.raw("[");
        o.depth += 1;
        o.first[o.depth] = true;
    }
    fn end(o: *Out, c: []const u8) void {
        o.depth -= 1;
        o.raw(c);
    }
};

// ---------------------------------------------------------------------------
// The agent's capabilities and the audit log

const Cap = struct {
    info: D.AgentCap,
    fn name(c: *const Cap) []const u8 {
        return D.nameOf(&c.info.name);
    }
    fn granted(c: *const Cap) bool {
        return c.info.flags & D.AgentCap.granted != 0;
    }
};

var caps: [D.max_agent_caps]Cap = undefined;
var cap_count: usize = 0;
var ticks_per_ms: u64 = 10_000;

fn findCap(name: []const u8) ?*Cap {
    for (caps[0..cap_count]) |*c| if (std.mem.eql(u8, c.name(), name)) return c;
    return null;
}

const LeaseState = struct { valid: bool, uses_left: ?u64, expires_in_ms: ?u64 };

fn leaseState(c: *const Cap) LeaseState {
    if (!c.granted()) return .{ .valid = false, .uses_left = null, .expires_in_ms = null };
    const r = g.invoke(D.Slot.cnode, abi.CNodeMethod.lease_info, .{c.info.slot});
    if (!r.ok()) return .{ .valid = false, .uses_left = null, .expires_in_ms = null };
    const uses: ?u64 = if (r.w[0] == std.math.maxInt(u64)) null else r.w[0];
    const now = g.time();
    const expires: ?u64 = if (r.w[1] == 0) null else if (r.w[1] > now) (r.w[1] - now) / ticks_per_ms else 0;
    const valid = (uses == null or uses.? > 0) and (expires == null or expires.? > 0);
    return .{ .valid = valid, .uses_left = uses, .expires_in_ms = expires };
}

const max_log = 128;

const Action = struct {
    seq: u64,
    verb: [12]u8,
    cap: D.Name,
    method: D.Name,
    outcome: [24]u8,
    hash: [32]u8,
    undo_of: u64,
    /// For undoable calls: the words of the original arguments and results,
    /// so `undo` can fill the undo method's parameters by name.
    args: [5]usize,
    results: [5]usize,
    undoable: bool,
    undone: bool,
};

var log_entries: [max_log]Action = undefined;
var log_len: usize = 0;
var seq_next: u64 = 1;
var chain: [32]u8 = @splat(0);

fn setFixed(dst: []u8, s: []const u8) void {
    @memset(dst, 0);
    const n = @min(s.len, dst.len - 1);
    @memcpy(dst[0..n], s[0..n]);
}

fn fixedStr(s: []const u8) []const u8 {
    return std.mem.sliceTo(s, 0);
}

/// Record an action: its hash covers the previous hash and the entry, so
/// rewriting history changes every later hash.
fn audit(verb: []const u8, cap: []const u8, method: []const u8, outcome: []const u8, undoable: bool, args: [5]usize, results: [5]usize, undo_of: u64) *Action {
    const slot = &log_entries[log_len % max_log];
    if (log_len < max_log) log_len += 1;
    slot.* = .{ .seq = seq_next, .verb = undefined, .cap = undefined, .method = undefined, .outcome = undefined, .hash = undefined, .undo_of = undo_of, .args = args, .results = results, .undoable = undoable, .undone = false };
    seq_next += 1;
    setFixed(&slot.verb, verb);
    setFixed(&slot.cap, cap);
    setFixed(&slot.method, method);
    setFixed(&slot.outcome, outcome);
    var h = Blake3.init(.{});
    h.update(&chain);
    var line: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "{d}|{s}|{s}|{s}|{s}|{d}", .{ slot.seq, verb, cap, method, outcome, undo_of }) catch "";
    h.update(text);
    h.final(&slot.hash);
    chain = slot.hash;
    g.log("envoy_action", .{ .seq = slot.seq, .verb = verb, .cap = cap, .method = method, .outcome = outcome });
    return slot;
}

fn findAction(seq: u64) ?*Action {
    for (log_entries[0..log_len]) |*a| if (a.seq == seq) return a;
    return null;
}

// ---------------------------------------------------------------------------
// Typed calls from JSON, through the IDL

fn argOf(args: ?Value, name: []const u8) ?Value {
    const a = args orelse return null;
    if (a != .object) return null;
    return a.object.get(name);
}

fn parseParams(comptime T: type, args: ?Value) error{InvalidArgs}!T {
    var v: T = undefined;
    inline for (comptime std.meta.fieldNames(T)) |f| {
        const F = @FieldType(T, f);
        const j = argOf(args, f) orelse return error.InvalidArgs;
        if (@typeInfo(F) == .@"struct" and @hasDecl(F, "idl_bytes")) {
            if (j != .string or j.string.len > F.idl_bytes) return error.InvalidArgs;
            @field(v, f) = F.from(j.string);
        } else switch (@typeInfo(F)) {
            .int => {
                if (j != .integer) return error.InvalidArgs;
                @field(v, f) = std.math.cast(F, j.integer) orelse return error.InvalidArgs;
            },
            .bool => {
                if (j != .bool) return error.InvalidArgs;
                @field(v, f) = j.bool;
            },
            .@"enum" => {
                if (j != .string) return error.InvalidArgs;
                @field(v, f) = std.meta.stringToEnum(F, j.string) orelse return error.InvalidArgs;
            },
            else => comptime unreachable,
        }
    }
    return v;
}

fn printable(s: []const u8) bool {
    for (s) |c| if (c < 0x20 or c >= 0x7f) return false;
    return true;
}

fn writeFields(o: *Out, comptime T: type, v: T) void {
    o.obj();
    inline for (comptime std.meta.fieldNames(T)) |f| {
        const F = @FieldType(T, f);
        o.field(f);
        const x = @field(v, f);
        if (@typeInfo(F) == .@"struct" and @hasDecl(F, "idl_bytes")) {
            if (printable(x.slice())) o.str(x.slice()) else {
                o.obj();
                o.field("hex");
                o.hex(x.slice());
                o.end("}");
            }
        } else switch (@typeInfo(F)) {
            .int => o.num(x),
            .bool => o.boolean(x),
            .@"enum" => o.str(@tagName(x)),
            else => comptime unreachable,
        }
    }
    o.end("}");
}

const CallOutcome = struct {
    ok: bool,
    /// Kernel status for transport failures (lease expired, revoked, ...).
    status: abi.Status = .ok,
    /// Service error code if the call reached the service and it failed.
    code: usize = 0,
    args: [5]usize = @splat(0),
    results: [5]usize = @splat(0),
};

fn outcomeText(c: CallOutcome) []const u8 {
    if (c.ok) return "ok";
    if (c.status != .ok) return @tagName(c.status);
    return @tagName(@as(idl.ErrorCode, @fromBackingInt(@intCast(c.code))));
}

fn rawCall(comptime M: type, slot: u32, w: [5]usize) CallOutcome {
    const r = g.syscall(.call, slot, @bitCast(g.Tag{ .label = M.label, .length = @intCast(idl.words(M.Params)) }), w);
    if (r.status != .ok) return .{ .ok = false, .status = r.status, .args = w };
    if (r.tag.label != 0) return .{ .ok = false, .code = r.w[0], .args = w };
    return .{ .ok = true, .args = w, .results = r.w };
}

/// Method metadata without calling, for plan.
const MethodInfo = struct { effect: idl.Effect, undo: ?[]const u8 };

fn methodInfo(comptime P: type, method: []const u8) ?MethodInfo {
    inline for (comptime idl.methodNames(P)) |n| {
        if (std.mem.eql(u8, n, method)) return .{ .effect = @field(P, n).effect, .undo = @field(P, n).undo };
    }
    return null;
}

fn infoFor(c: *const Cap, method: []const u8) ?MethodInfo {
    inline for (proto.all) |P| if (idl.id(P) == c.info.protocol_id) return methodInfo(P, method);
    return null;
}

const ParseOutcome = union(enum) { ok: [5]usize, unknown_method, invalid_args };

fn encodeArgs(c: *const Cap, method: []const u8, args: ?Value) ParseOutcome {
    inline for (proto.all) |P| if (idl.id(P) == c.info.protocol_id) {
        inline for (comptime idl.methodNames(P)) |n| if (std.mem.eql(u8, n, method)) {
            const M = @field(P, n);
            const params = parseParams(M.Params, args) catch return .invalid_args;
            return .{ .ok = idl.encode(M.Params, params) };
        };
        return .unknown_method;
    };
    return .unknown_method;
}

fn invokeMethod(c: *const Cap, method: []const u8, w: [5]usize) CallOutcome {
    inline for (proto.all) |P| if (idl.id(P) == c.info.protocol_id) {
        inline for (comptime idl.methodNames(P)) |n| if (std.mem.eql(u8, n, method)) {
            return rawCall(@field(P, n), c.info.slot, w);
        };
    };
    return .{ .ok = false, .code = @backingInt(idl.ErrorCode.unknown_method) };
}

fn writeResults(o: *Out, c: *const Cap, method: []const u8, w: [5]usize) void {
    inline for (proto.all) |P| if (idl.id(P) == c.info.protocol_id) {
        inline for (comptime idl.methodNames(P)) |n| if (std.mem.eql(u8, n, method)) {
            const M = @field(P, n);
            if (idl.decode(M.Results, w)) |res| writeFields(o, M.Results, res) else |_| o.nul();
            return;
        };
    };
    o.nul();
}

/// Fill the undo method's parameters by name: from the original results
/// first, then the original arguments.
fn undoArgs(c: *const Cap, method: []const u8, undo: []const u8, args: [5]usize, results: [5]usize) ?[5]usize {
    inline for (proto.all) |P| if (idl.id(P) == c.info.protocol_id) {
        inline for (comptime idl.methodNames(P)) |n| if (std.mem.eql(u8, n, method)) {
            const M = @field(P, n);
            if (M.undo) |u_name| {
                if (!std.mem.eql(u8, u_name, undo)) return null;
                const U = @field(P, u_name);
                const a = idl.decode(M.Params, args) catch return null;
                const r = idl.decode(M.Results, results) catch return null;
                var up: U.Params = undefined;
                inline for (comptime std.meta.fieldNames(U.Params)) |f| {
                    if (@hasField(M.Results, f)) @field(up, f) = @field(r, f) else @field(up, f) = @field(a, f);
                }
                return idl.encode(U.Params, up);
            }
            return null;
        };
    };
    return null;
}

// ---------------------------------------------------------------------------
// Verbs

var registry: g.CPtr = 0;

fn err(o: *Out, code: []const u8, detail: []const u8) void {
    o.field("ok");
    o.boolean(false);
    o.field("error");
    o.str(code);
    o.field("detail");
    o.str(detail);
}

fn okResult(o: *Out) void {
    o.field("ok");
    o.boolean(true);
    o.field("result");
}

fn verbHello(o: *Out) void {
    const e = g.env();
    okResult(o);
    o.obj();
    o.field("system");
    o.str(D.nameOf(&e.system));
    o.field("closure");
    o.hex(&e.closure);
    o.field("envoy");
    o.str("envoy.v1");
    o.field("principal");
    o.str("agent");
    o.field("verbs");
    o.arr();
    for ([_][]const u8{ "hello", "discover", "describe", "call", "plan", "apply", "undo", "ask", "observe", "bye" }) |v| o.str(v);
    o.end("]");
    o.end("}");
}

fn writeLease(o: *Out, c: *const Cap) void {
    const ls = leaseState(c);
    o.obj();
    o.field("valid");
    o.boolean(ls.valid);
    o.field("uses_left");
    if (ls.uses_left) |u| o.num(u) else o.nul();
    o.field("expires_in_ms");
    if (ls.expires_in_ms) |x| o.num(x) else o.nul();
    o.end("}");
}

fn verbDiscover(o: *Out) void {
    okResult(o);
    o.obj();
    o.field("capabilities");
    o.arr();
    for (caps[0..cap_count]) |*c| {
        o.obj();
        o.field("name");
        o.str(c.name());
        o.field("protocol");
        o.str(D.nameOf(&c.info.protocol));
        o.field("protocol_id");
        var idb: [16]u8 = undefined;
        o.str(std.fmt.bufPrint(&idb, "{x:0>16}", .{c.info.protocol_id}) catch "");
        o.field("granted");
        o.boolean(c.granted());
        o.field("askable");
        o.boolean(c.info.flags & D.AgentCap.askable != 0);
        o.field("lease");
        if (c.granted()) writeLease(o, c) else o.nul();
        o.end("}");
    }
    o.end("]");
    o.end("}");
}

fn verbDescribe(o: *Out, req: Value) void {
    const name = (req.object.get("cap") orelse return err(o, "invalid_request", "describe needs \"cap\""));
    if (name != .string) return err(o, "invalid_request", "\"cap\" must be a string");
    const c = findCap(name.string) orelse return err(o, "unknown_cap", "the agent holds no capability by that name");
    // Ask the Registry: the descriptor comes 24 bytes at a time.
    var desc: [4096]u8 = undefined;
    var total: usize = 0;
    var off: usize = 0;
    while (true) {
        const r = idl.call(proto.registry.describe, registry, .{ .id = c.info.protocol_id, .offset = off }) catch return err(o, "registry_failed", "the registry did not answer");
        total = @intCast(@min(r.total, desc.len));
        const chunk = r.chunk.slice();
        if (chunk.len == 0 or off >= total) break;
        @memcpy(desc[off..][0..@min(chunk.len, total - off)], chunk[0..@min(chunk.len, total - off)]);
        off += chunk.len;
        if (off >= total) break;
    }
    okResult(o);
    o.obj();
    o.field("cap");
    o.str(c.name());
    o.field("descriptor");
    o.json(desc[0..total]);
    o.end("}");
}

const Step = struct {
    cap: *Cap,
    method: []const u8,
    args: ?Value,
    info: MethodInfo,
    words: [5]usize,
};

const StepProblem = struct { index: usize, code: []const u8, detail: []const u8 };

fn parseStep(v: Value, out: *Step) ?StepProblem {
    if (v != .object) return .{ .index = 0, .code = "invalid_request", .detail = "each step is an object" };
    const cap_name = v.object.get("cap") orelse return .{ .index = 0, .code = "invalid_request", .detail = "a step needs \"cap\"" };
    const method = v.object.get("method") orelse return .{ .index = 0, .code = "invalid_request", .detail = "a step needs \"method\"" };
    if (cap_name != .string or method != .string) return .{ .index = 0, .code = "invalid_request", .detail = "\"cap\" and \"method\" are strings" };
    const c = findCap(cap_name.string) orelse return .{ .index = 0, .code = "unknown_cap", .detail = "the agent holds no capability by that name" };
    if (!c.granted()) return .{ .index = 0, .code = "not_granted", .detail = "this capability must be asked for first" };
    const info = infoFor(c, method.string) orelse return .{ .index = 0, .code = "unknown_method", .detail = "the protocol has no such method" };
    const args = v.object.get("args");
    const w = switch (encodeArgs(c, method.string, args)) {
        .ok => |w| w,
        .unknown_method => return .{ .index = 0, .code = "unknown_method", .detail = "the protocol has no such method" },
        .invalid_args => return .{ .index = 0, .code = "invalid_args", .detail = "arguments do not match the method's parameters (see describe)" },
    };
    out.* = .{ .cap = c, .method = method.string, .args = args, .info = info, .words = w };
    return null;
}

fn verbCall(o: *Out, req: Value) void {
    var st: Step = undefined;
    if (parseStep(req, &st)) |p| return err(o, p.code, p.detail);
    const out = invokeMethod(st.cap, st.method, st.words);
    const a = audit("call", st.cap.name(), st.method, outcomeText(out), st.info.undo != null and out.ok, out.args, out.results, 0);
    if (!out.ok) {
        err(o, outcomeText(out), if (out.status != .ok) "the kernel refused the call (see lease in discover)" else "the service returned an error");
        o.field("action");
        o.num(a.seq);
        return;
    }
    okResult(o);
    writeResults(o, st.cap, st.method, out.results);
    o.field("action");
    o.num(a.seq);
}

const max_steps = 16;

fn planSteps(o: *Out, req: Value, steps: *[max_steps]Step, n: *usize) ?bool {
    const list = req.object.get("steps") orelse {
        err(o, "invalid_request", "plan and apply need \"steps\"");
        return null;
    };
    if (list != .array or list.array.items.len == 0 or list.array.items.len > max_steps) {
        err(o, "invalid_request", "\"steps\" is a list of 1-16 calls");
        return null;
    }
    var atomic = true;
    for (list.array.items, 0..) |item, i| {
        if (parseStep(item, &steps[i])) |p| {
            err(o, p.code, p.detail);
            o.field("step");
            o.num(i);
            return null;
        }
        const s = steps[i];
        if (s.info.effect == .external or (s.info.effect == .mutates and s.info.undo == null)) atomic = false;
    }
    n.* = list.array.items.len;
    return atomic;
}

fn writePlan(o: *Out, steps: []const Step, atomic: bool) void {
    o.field("atomic");
    o.boolean(atomic);
    o.field("steps");
    o.arr();
    for (steps) |s| {
        o.obj();
        o.field("cap");
        o.str(s.cap.name());
        o.field("method");
        o.str(s.method);
        o.field("effect");
        o.str(@tagName(s.info.effect));
        o.field("undo");
        if (s.info.undo) |u| o.str(u) else o.nul();
        o.field("lease");
        writeLease(o, s.cap);
        o.end("}");
    }
    o.end("]");
}

fn verbPlan(o: *Out, req: Value) void {
    var steps: [max_steps]Step = undefined;
    var n: usize = 0;
    const atomic = planSteps(o, req, &steps, &n) orelse return;
    // Uses needed per capability versus uses left.
    var short = false;
    for (steps[0..n]) |s| {
        var need: u64 = 0;
        for (steps[0..n]) |t| if (t.cap == s.cap) {
            need += 1;
        };
        const ls = leaseState(s.cap);
        if (!ls.valid or (ls.uses_left != null and ls.uses_left.? < need)) short = true;
    }
    okResult(o);
    o.obj();
    writePlan(o, steps[0..n], atomic);
    o.field("executable");
    o.boolean(!short);
    o.field("changes_made");
    o.boolean(false);
    o.end("}");
}

fn undoAction(a: *Action) CallOutcome {
    const c = findCap(fixedStr(&a.cap)) orelse return .{ .ok = false, .code = @backingInt(idl.ErrorCode.not_found) };
    const method = fixedStr(&a.method);
    const info = infoFor(c, method) orelse return .{ .ok = false, .code = @backingInt(idl.ErrorCode.unknown_method) };
    const undo = info.undo orelse return .{ .ok = false, .code = @backingInt(idl.ErrorCode.unknown_method) };
    const w = undoArgs(c, method, undo, a.args, a.results) orelse return .{ .ok = false, .code = @backingInt(idl.ErrorCode.invalid_args) };
    const out = invokeMethod(c, undo, w);
    if (out.ok) a.undone = true;
    _ = audit("undo", c.name(), undo, outcomeText(out), false, w, out.results, a.seq);
    return out;
}

fn verbApply(o: *Out, req: Value) void {
    var steps: [max_steps]Step = undefined;
    var n: usize = 0;
    const atomic = planSteps(o, req, &steps, &n) orelse return;
    const partial = if (req.object.get("allow_partial")) |v| v == .bool and v.bool else false;
    if (!atomic and !partial) return err(o, "not_atomic", "a step cannot be undone, so the plan cannot be all-or-nothing; pass \"allow_partial\":true to run it anyway");
    var done: [max_steps]*Action = undefined;
    var results: [max_steps][5]usize = undefined;
    var failed_at: ?usize = null;
    var failure: []const u8 = "";
    for (steps[0..n], 0..) |s, i| {
        const out = invokeMethod(s.cap, s.method, s.words);
        done[i] = audit("apply", s.cap.name(), s.method, outcomeText(out), s.info.undo != null and out.ok, out.args, out.results, 0);
        results[i] = out.results;
        if (!out.ok) {
            failed_at = i;
            failure = outcomeText(out);
            break;
        }
    }
    var rolled_back = false;
    if (failed_at) |f| if (atomic) {
        var i = f;
        while (i > 0) {
            i -= 1;
            _ = undoAction(done[i]);
        }
        rolled_back = true;
    };
    if (failed_at) |f| {
        err(o, failure, if (rolled_back) "a step failed; every earlier step was undone" else "a step failed; earlier steps stand");
        o.field("step");
        o.num(f);
        o.field("rolled_back");
        o.boolean(rolled_back);
        return;
    }
    okResult(o);
    o.obj();
    o.field("committed");
    o.boolean(true);
    o.field("results");
    o.arr();
    for (steps[0..n], 0..) |s, i| {
        o.obj();
        o.field("action");
        o.num(done[i].seq);
        o.field("result");
        writeResults(o, s.cap, s.method, results[i]);
        o.end("}");
    }
    o.end("]");
    o.end("}");
}

fn verbUndo(o: *Out, req: Value) void {
    const v = req.object.get("action") orelse return err(o, "invalid_request", "undo needs \"action\"");
    if (v != .integer) return err(o, "invalid_request", "\"action\" is a number from a call or apply");
    const a = findAction(@intCast(@max(v.integer, 0))) orelse return err(o, "unknown_action", "no such action in the log");
    if (!a.undoable) return err(o, "not_undoable", "that action cannot be undone");
    if (a.undone) return err(o, "already_undone", "that action was already undone");
    const out = undoAction(a);
    if (!out.ok) return err(o, outcomeText(out), "the undo call failed");
    okResult(o);
    o.obj();
    o.field("undone");
    o.num(a.seq);
    o.end("}");
}

fn verbAsk(o: *Out, req: Value) void {
    const name = req.object.get("cap") orelse return err(o, "invalid_request", "ask needs \"cap\"");
    if (name != .string) return err(o, "invalid_request", "\"cap\" must be a string");
    const c = findCap(name.string) orelse return err(o, "unknown_cap", "the manifest offers no service by that name");
    const index = (@intFromPtr(c) - @intFromPtr(&caps[0])) / @sizeOf(Cap);
    const r = g.syscall(.call, D.Slot.steward, @bitCast(g.Tag{ .label = @backingInt(D.Lifecycle.ask), .length = 1 }), .{ index, 0, 0, 0, 0 });
    if (r.status != .ok) return err(o, @tagName(r.status), "Steward did not answer");
    if (r.tag.label != 0) {
        const why: D.AskRefusal = @fromBackingInt(@intCast(r.w[0]));
        _ = audit("ask", c.name(), "", @tagName(why), false, @splat(0), @splat(0), 0);
        return err(o, "refused", @tagName(why));
    }
    c.info.slot = @intCast(r.w[0]);
    c.info.flags |= D.AgentCap.granted;
    _ = audit("ask", c.name(), "", "granted", false, @splat(0), @splat(0), 0);
    okResult(o);
    o.obj();
    o.field("granted");
    o.boolean(true);
    o.field("lease");
    writeLease(o, c);
    o.end("}");
}

fn verbObserve(o: *Out, req: Value) void {
    const since: u64 = if (req.object.get("since")) |v| (if (v == .integer) @intCast(@max(v.integer, 0)) else 0) else 0;
    okResult(o);
    o.obj();
    o.field("actions");
    o.arr();
    for (log_entries[0..log_len]) |*a| {
        if (a.seq <= since) continue;
        o.obj();
        o.field("seq");
        o.num(a.seq);
        o.field("verb");
        o.str(fixedStr(&a.verb));
        o.field("cap");
        o.str(fixedStr(&a.cap));
        o.field("method");
        o.str(fixedStr(&a.method));
        o.field("outcome");
        o.str(fixedStr(&a.outcome));
        o.field("undo_of");
        if (a.undo_of != 0) o.num(a.undo_of) else o.nul();
        o.field("undone");
        o.boolean(a.undone);
        o.field("hash");
        o.hex(&a.hash);
        o.end("}");
    }
    o.end("]");
    o.field("head");
    o.hex(&chain);
    o.field("hash_rule");
    o.str("hash[n] = blake3(hash[n-1] || \"seq|verb|cap|method|outcome|undo_of\"), hash[0] = 32 zero bytes");
    o.end("}");
}

// ---------------------------------------------------------------------------

var heap: [64 * 1024]u8 = undefined;
var response: Out = .{};

pub fn main() !u16 {
    const info = g.device("port") orelse return error.NoDevice;
    var space: g.Space = .{ .untyped = D.Slot.memory, .vspace = D.Slot.vspace, .next_slot = D.Slot.first_free };
    const dev: virtio.Device = .{ .base = info.mmio };
    _ = try dev.init(3, 0);
    const rxq = try virtio.Dma.alloc(&space, D.Layout.heap);
    const txq = try virtio.Dma.alloc(&space, D.Layout.heap + 0x1000);
    const rx_page = try virtio.Dma.alloc(&space, D.Layout.heap + 0x2000);
    const tx_page = try virtio.Dma.alloc(&space, D.Layout.heap + 0x3000);
    var port: Port = .{
        .dev = dev,
        .rx = try virtio.Queue.init(dev, 0, rxq.va, rxq.pa),
        .tx = try virtio.Queue.init(dev, 1, txq.va, txq.pa),
        .rx_page = rx_page,
        .tx_page = tx_page,
        .signal = try space.retype(.signal, 0),
        .irq = info.irq_slot,
    };
    if (!g.invoke(info.irq_slot, abi.IrqMethod.set_signal, .{port.signal}).ok()) return error.IrqSetup;
    dev.ready();
    for (0..rx_buffers) |i| port.rx.submitDesc(@intCast(i), rx_page.pa + i * rx_size, rx_size, true);

    const e = g.env();
    ticks_per_ms = @max(e.timebase_hz / 1000, 1);
    registry = g.use("registry") orelse return error.NoRegistry;
    cap_count = e.agent_count;
    for (e.agent[0..cap_count], 0..) |c, i| caps[i] = .{ .info = c };
    g.log("envoy_ready", .{ .device = "virtio_console", .mmio = g.klog.hex(info.phys), .capabilities = cap_count });

    while (true) {
        const line = port.readLine();
        if (line.len == 0) continue;
        var fba = std.heap.FixedBufferAllocator.init(&heap);
        response = .{};
        response.raw("{");
        response.depth = 1;
        response.first[1] = true;
        var bye = false;
        const req = std.json.parseFromSliceLeaky(Value, fba.allocator(), line, .{}) catch null;
        if (req == null or req.? != .object) {
            err(&response, "invalid_json", "send one JSON object per line");
        } else {
            const r = req.?;
            response.field("id");
            if (r.object.get("id")) |idv| switch (idv) {
                .integer => |n| response.num(n),
                .string => |sv| response.str(sv),
                else => response.nul(),
            } else response.nul();
            const verb = if (r.object.get("verb")) |v| (if (v == .string) v.string else "") else "";
            if (std.mem.eql(u8, verb, "hello")) verbHello(&response) //
            else if (std.mem.eql(u8, verb, "discover")) verbDiscover(&response) //
            else if (std.mem.eql(u8, verb, "describe")) verbDescribe(&response, r) //
            else if (std.mem.eql(u8, verb, "call")) verbCall(&response, r) //
            else if (std.mem.eql(u8, verb, "plan")) verbPlan(&response, r) //
            else if (std.mem.eql(u8, verb, "apply")) verbApply(&response, r) //
            else if (std.mem.eql(u8, verb, "undo")) verbUndo(&response, r) //
            else if (std.mem.eql(u8, verb, "ask")) verbAsk(&response, r) //
            else if (std.mem.eql(u8, verb, "observe")) verbObserve(&response, r) //
            else if (std.mem.eql(u8, verb, "bye")) {
                okResult(&response);
                response.obj();
                response.field("actions");
                response.num(seq_next - 1);
                response.end("}");
                bye = true;
            } else err(&response, "unknown_verb", "verbs: hello discover describe call plan apply undo ask observe bye");
        }
        response.raw("}\n");
        if (response.overflow) {
            port.write("{\"ok\":false,\"error\":\"response_too_large\"}\n");
        } else port.write(response.buf[0..response.len]);
        if (bye) {
            g.log("envoy_bye", .{ .actions = seq_next - 1 });
            return 0;
        }
    }
}
