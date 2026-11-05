//! grain-emu: run a Caravan kernel (or Aurora) on the emulated RISC-V machine.
//!
//!   grain-emu [options] KERNEL.elf
//!     --harts N             harts (default 1)
//!     --ram MIB             memory (default 256)
//!     --rng FILE            an entropy device reading FILE (wrapping at its end);
//!                           --rng seed:N uses a fixed pseudo-random stream
//!     --disk FILE           a block device on FILE (written in place)
//!     --console-socket P    a console device, served as a Unix socket at P;
//!                           the machine waits for a client before starting
//!     --envoy-socket P      a second console device at P (no waiting)
//!     --display             a screen (virtio-gpu, 1024x768), a keyboard and a tablet
//!     --display-size WxH    the same, with a screen of that size
//!     --screenshot FILE     at the end, write the screen to FILE (PPM)
//!     --realtime            time from the host's clock (default: instruction counts)
//!     --max-seconds S       stop after S seconds of guest time
//!     --stats               print instructions run and the rate, on stderr
//!
//! Devices take virtio slots in the order screen, keyboard, tablet, rng,
//! disk, console, envoy, as the QEMU harness creates them, so manifests find
//! them at the same instances.
//! The serial console goes to stdout. The exit status is the guest's (the
//! test finisher's code; 0 on power-off), 124 if --max-seconds ran out,
//! 125 if every hart idles with nothing left to wake it.
const std = @import("std");
const c = std.c;
const emu = @import("machine.zig");

const usage =
    \\usage: grain-emu [--harts N] [--ram MIB] [--rng FILE|seed:N] [--disk FILE]
    \\                 [--console-socket PATH] [--envoy-socket PATH] [--display]
    \\                 [--display-size WxH] [--screenshot FILE] [--realtime]
    \\                 [--max-seconds S] KERNEL
    \\
;

const Port = struct {
    listen_fd: c.fd_t = -1,
    client_fd: c.fd_t = -1,
    /// Received from the client, not yet taken by the guest.
    pending: [4096]u8 = undefined,
    pending_len: usize = 0,
};

const Host = struct {
    io: std.Io,
    out: *std.Io.Writer,
    rng_file: ?std.Io.File = null,
    rng_size: u64 = 0,
    rng_pos: u64 = 0,
    rng_state: u64 = 0x9e3779b97f4a7c15,
    disk: ?std.Io.File = null,
    ports: [2]Port = .{ .{}, .{} },
    start: std.Io.Timestamp = .zero,

    fn self(ctx: ?*anyopaque) *Host {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn console(ctx: ?*anyopaque, bytes: []const u8) void {
        const h = self(ctx);
        h.out.writeAll(bytes) catch {};
        if (std.mem.indexOfScalar(u8, bytes, '\n') != null) h.out.flush() catch {};
    }

    fn portWrite(ctx: ?*anyopaque, port: u8, bytes: []const u8) void {
        const h = self(ctx);
        if (port >= h.ports.len) return;
        const fd = h.ports[port].client_fd;
        if (fd < 0) return; // no client: dropped, as QEMU does
        var rest = bytes;
        while (rest.len > 0) {
            const n = c.send(fd, rest.ptr, rest.len, 0);
            if (n <= 0) return;
            rest = rest[@intCast(n)..];
        }
    }

    fn entropy(ctx: ?*anyopaque, out: []u8) void {
        const h = self(ctx);
        if (h.rng_file) |f| {
            var done: usize = 0;
            while (done < out.len) {
                if (h.rng_pos >= h.rng_size) h.rng_pos = 0;
                const want = @min(out.len - done, h.rng_size - h.rng_pos);
                const n = f.readPositionalAll(h.io, out[done..][0..want], h.rng_pos) catch 0;
                if (n == 0) break;
                done += n;
                h.rng_pos += n;
            }
            return;
        }
        for (out) |*b| {
            // xorshift64*: a fixed stream for deterministic runs.
            h.rng_state ^= h.rng_state >> 12;
            h.rng_state ^= h.rng_state << 25;
            h.rng_state ^= h.rng_state >> 27;
            b.* = @truncate((h.rng_state *% 0x2545f4914f6cdd1d) >> 56);
        }
    }

    fn diskRead(ctx: ?*anyopaque, offset: u64, out: []u8) bool {
        const h = self(ctx);
        const f = h.disk orelse return false;
        const n = f.readPositionalAll(h.io, out, offset) catch return false;
        if (n < out.len) @memset(out[n..], 0);
        return true;
    }

    fn diskWrite(ctx: ?*anyopaque, offset: u64, bytes: []const u8) bool {
        const h = self(ctx);
        const f = h.disk orelse return false;
        f.writePositionalAll(h.io, bytes, offset) catch return false;
        return true;
    }

    fn diskFlush(ctx: ?*anyopaque) bool {
        const h = self(ctx);
        const f = h.disk orelse return false;
        f.sync(h.io) catch return false;
        return true;
    }

    fn nowNs(ctx: ?*anyopaque) u64 {
        const h = self(ctx);
        const d = h.start.durationTo(std.Io.Timestamp.now(h.io, .awake));
        return @intCast(@max(0, d.nanoseconds));
    }

    /// Accept clients and move what they sent into the machine. Waits up to
    /// `timeout_ms` for something to happen (0: just look).
    fn poll(h: *Host, m: *emu.Machine, timeout_ms: i32) void {
        var fds: [4]c.pollfd = undefined;
        var which: [4]struct { port: usize, listen: bool } = undefined;
        var n: usize = 0;
        for (&h.ports, 0..) |*p, i| {
            // Offer what the guest did not take yet.
            if (p.pending_len > 0) {
                const took = m.consoleInput(@intCast(i), p.pending[0..p.pending_len]);
                std.mem.copyForwards(u8, p.pending[0 .. p.pending_len - took], p.pending[took..p.pending_len]);
                p.pending_len -= took;
            }
            if (p.client_fd >= 0) {
                if (p.pending_len < p.pending.len) {
                    fds[n] = .{ .fd = p.client_fd, .events = c.POLL.IN, .revents = 0 };
                    which[n] = .{ .port = i, .listen = false };
                    n += 1;
                }
            } else if (p.listen_fd >= 0) {
                fds[n] = .{ .fd = p.listen_fd, .events = c.POLL.IN, .revents = 0 };
                which[n] = .{ .port = i, .listen = true };
                n += 1;
            }
        }
        if (n == 0) {
            if (timeout_ms > 0) _ = c.poll(&fds, 0, timeout_ms);
            return;
        }
        if (c.poll(&fds, @intCast(n), timeout_ms) <= 0) return;
        for (fds[0..n], which[0..n]) |fd, w| {
            if (fd.revents == 0) continue;
            const p = &h.ports[w.port];
            if (w.listen) {
                p.client_fd = c.accept(p.listen_fd, null, null);
                continue;
            }
            const got = c.recv(p.client_fd, &p.pending[p.pending_len], p.pending.len - p.pending_len, 0);
            if (got <= 0) {
                _ = c.close(p.client_fd);
                p.client_fd = -1;
                continue;
            }
            p.pending_len += @intCast(got);
            const took = m.consoleInput(@intCast(w.port), p.pending[0..p.pending_len]);
            std.mem.copyForwards(u8, p.pending[0 .. p.pending_len - took], p.pending[took..p.pending_len]);
            p.pending_len -= took;
        }
    }
};

fn listenUnix(path: []const u8) !c.fd_t {
    var addr = std.mem.zeroes(c.sockaddr.un);
    addr.family = c.AF.UNIX;
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    _ = c.unlink(@ptrCast(&addr.path));
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) return error.BindFailed;
    if (c.listen(fd, 1) != 0) return error.ListenFailed;
    return fd;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var config: emu.Config = .{};
    var max_seconds: u64 = 0;
    var kernel: ?[]const u8 = null;
    var rng_arg: ?[]const u8 = null;
    var disk_path: ?[]const u8 = null;
    var console_path: ?[]const u8 = null;
    var envoy_path: ?[]const u8 = null;
    var stats = false;
    var display = false;
    var screenshot: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const has_value = i + 1 < args.len;
        if (std.mem.eql(u8, a, "--harts") and has_value) {
            i += 1;
            config.harts = std.fmt.parseInt(u32, args[i], 10) catch return bad(a);
            if (config.harts < 1 or config.harts > emu.max_harts) return bad(a);
        } else if (std.mem.eql(u8, a, "--ram") and has_value) {
            i += 1;
            config.ram_mib = std.fmt.parseInt(u32, args[i], 10) catch return bad(a);
        } else if (std.mem.eql(u8, a, "--max-seconds") and has_value) {
            i += 1;
            max_seconds = std.fmt.parseInt(u64, args[i], 10) catch return bad(a);
        } else if (std.mem.eql(u8, a, "--rng") and has_value) {
            i += 1;
            rng_arg = args[i];
        } else if (std.mem.eql(u8, a, "--disk") and has_value) {
            i += 1;
            disk_path = args[i];
        } else if (std.mem.eql(u8, a, "--console-socket") and has_value) {
            i += 1;
            console_path = args[i];
        } else if (std.mem.eql(u8, a, "--envoy-socket") and has_value) {
            i += 1;
            envoy_path = args[i];
        } else if (std.mem.eql(u8, a, "--display")) {
            display = true;
        } else if (std.mem.eql(u8, a, "--display-size") and has_value) {
            i += 1;
            const size = parseSize(args[i]) orelse return bad(a);
            config.display_width = size[0];
            config.display_height = size[1];
            display = true;
        } else if (std.mem.eql(u8, a, "--screenshot") and has_value) {
            i += 1;
            screenshot = args[i];
        } else if (std.mem.eql(u8, a, "--stats")) {
            stats = true;
        } else if (std.mem.eql(u8, a, "--realtime")) {
            config.realtime = true;
        } else if (a.len > 0 and a[0] == '-') {
            return bad(a);
        } else kernel = a;
    }
    const path = kernel orelse {
        std.debug.print(usage, .{});
        return 2;
    };
    const cwd = std.Io.Dir.cwd();
    const image = cwd.readFileAlloc(io, path, arena, .limited(64 << 20)) catch |e| {
        std.debug.print("grain-emu: cannot read {s} ({s})\n", .{ path, @errorName(e) });
        return 2;
    };

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    var host: Host = .{ .io = io, .out = &stdout.interface, .start = std.Io.Timestamp.now(io, .awake) };
    defer stdout.interface.flush() catch {};

    var specs: [7]emu.DeviceSpec = undefined;
    var nspecs: usize = 0;
    if (display) {
        for ([_]emu.virtio.Kind{ .gpu, .keyboard, .tablet }) |k| {
            specs[nspecs] = .{ .kind = k };
            nspecs += 1;
        }
    }
    if (rng_arg) |r| {
        if (std.mem.startsWith(u8, r, "seed:")) {
            host.rng_state = std.fmt.parseInt(u64, r[5..], 0) catch return bad(r);
            if (host.rng_state == 0) host.rng_state = 1;
        } else {
            const f = cwd.openFile(io, r, .{}) catch |e| {
                std.debug.print("grain-emu: cannot open {s} ({s})\n", .{ r, @errorName(e) });
                return 2;
            };
            host.rng_file = f;
            host.rng_size = f.length(io) catch 0;
            // A character device (/dev/urandom) has no length: read on forever.
            if (host.rng_size == 0) host.rng_size = std.math.maxInt(u64);
        }
        specs[nspecs] = .{ .kind = .rng };
        nspecs += 1;
    }
    if (disk_path) |d| {
        const f = cwd.openFile(io, d, .{ .mode = .read_write }) catch |e| {
            std.debug.print("grain-emu: cannot open {s} ({s})\n", .{ d, @errorName(e) });
            return 2;
        };
        host.disk = f;
        config.disk_bytes = f.length(io) catch 0;
        specs[nspecs] = .{ .kind = .blk };
        nspecs += 1;
    }
    if (console_path) |p| {
        host.ports[0].listen_fd = listenUnix(p) catch |e| {
            std.debug.print("grain-emu: cannot serve {s} ({s})\n", .{ p, @errorName(e) });
            return 2;
        };
        specs[nspecs] = .{ .kind = .console };
        nspecs += 1;
    }
    if (envoy_path) |p| {
        if (console_path == null) {
            std.debug.print("grain-emu: --envoy-socket needs --console-socket (it is the second console)\n", .{});
            return 2;
        }
        host.ports[1].listen_fd = listenUnix(p) catch |e| {
            std.debug.print("grain-emu: cannot serve {s} ({s})\n", .{ p, @errorName(e) });
            return 2;
        };
        specs[nspecs] = .{ .kind = .console };
        nspecs += 1;
    }
    config.devices = specs[0..nspecs];

    const m = try emu.Machine.init(std.heap.page_allocator, config, .{
        .ctx = &host,
        .console = Host.console,
        .port_write = Host.portWrite,
        .entropy = Host.entropy,
        .disk_read = Host.diskRead,
        .disk_write = Host.diskWrite,
        .disk_flush = Host.diskFlush,
        .now_ns = Host.nowNs,
    });
    defer m.deinit();
    const entry = m.loadElf(image) catch |e| {
        std.debug.print("grain-emu: {s}: {s}\n", .{ path, @errorName(e) });
        return 2;
    };
    try m.boot(entry);

    // Like QEMU's `wait=on`: no output is lost before the console client comes.
    if (host.ports[0].listen_fd >= 0) host.ports[0].client_fd = c.accept(host.ports[0].listen_fd, null, null);

    const limit: u64 = if (max_seconds == 0) std.math.maxInt(u64) else max_seconds * 1_000_000_000;
    const status: u8 = while (true) {
        const slice = @min(limit -| m.ns, 2_000_000);
        if (slice == 0) break 124;
        switch (m.run(slice)) {
            .exited => break @truncate(m.exit_code.?),
            .budget => host.poll(m, 0),
            .waiting => {
                const now = Host.nowNs(&host);
                const ms: i32 = if (m.wake_ns > now) @intCast(@min((m.wake_ns - now) / 1_000_000 + 1, 50)) else 0;
                host.poll(m, ms);
                m.ns = @max(m.ns, Host.nowNs(&host));
            },
            .idle => {
                // Only outside input can wake the guest now.
                if (host.ports[0].listen_fd < 0 and host.ports[1].listen_fd < 0) break 125;
                host.poll(m, 50);
            },
        }
    };
    stdout.interface.flush() catch {};
    if (screenshot) |shot| if (m.screen()) |scr| {
        writePpm(io, shot, scr) catch |e| std.debug.print("grain-emu: cannot write {s} ({s})\n", .{ shot, @errorName(e) });
    };
    if (stats) {
        var retired: u64 = 0;
        for (m.harts) |*h| retired += h.instret;
        const wall = Host.nowNs(&host);
        std.debug.print("grain-emu: {d} instructions in {d} ms ({d} MIPS); guest time {d} ms; decoded pages dropped {d}\n", .{
            retired, wall / 1_000_000, if (wall == 0) 0 else retired * 1000 / wall, m.ns / 1_000_000, m.code_drops,
        });
    }
    return status;
}

/// The screen as a binary PPM (RGB).
fn writePpm(io: std.Io, path: []const u8, scr: emu.Machine.Screen) !void {
    const gpa = std.heap.page_allocator;
    const header = try std.fmt.allocPrint(gpa, "P6\n{d} {d}\n255\n", .{ scr.width, scr.height });
    defer gpa.free(header);
    const rgb = try gpa.alloc(u8, header.len + @as(usize, scr.width) * scr.height * 3);
    defer gpa.free(rgb);
    @memcpy(rgb[0..header.len], header);
    var o: usize = header.len;
    var p: usize = 0;
    while (p < scr.pixels.len) : (p += 4) {
        @memcpy(rgb[o..][0..3], scr.pixels[p..][0..3]);
        o += 3;
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = rgb });
}

/// "1280x800" -> .{ 1280, 800 }, within what a screen can be.
fn parseSize(text: []const u8) ?[2]u32 {
    const x = std.mem.indexOfScalar(u8, text, 'x') orelse return null;
    const w = std.fmt.parseInt(u32, text[0..x], 10) catch return null;
    const h = std.fmt.parseInt(u32, text[x + 1 ..], 10) catch return null;
    if (w < 320 or h < 240 or w > 4096 or h > 4096) return null;
    return .{ w, h };
}

fn bad(arg: []const u8) u8 {
    std.debug.print("grain-emu: bad argument {s}\n{s}", .{ arg, usage });
    return 2;
}
