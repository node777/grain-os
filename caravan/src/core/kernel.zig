//! The Caravan kernel as a state machine.
//!
//! `Kernel(A)` holds all kernel state. Architecture code turns hardware into
//! calls to `handle(hart, now, event)`; after each call, `currentThread(hart)`
//! is the thread that hart should run (or null to idle). Nothing in here
//! touches hardware directly: every effect goes through the arch interface
//! `A`, so the same code runs on RISC-V and in the host simulator.
//!
//! Required declarations on `A`:
//!
//!   Context                 per-thread saved user state, with
//!                             fn init(pc, sp, arg0) Context
//!                             fn get(*const Context, Reg) usize
//!                             fn set(*Context, Reg, usize) void
//!   Paging                  page-table format: levels, entries, index(),
//!                           makeTable(), makeLeaf(Leaf{pa, level, read, write,
//!                           execute, device}), isValid(), address(),
//!                           levelShift(), user_top, user_root_entries
//!   physToVirt(u64) usize   kernel address of physical memory
//!   initRootTable(*[N]u64)  install kernel mappings in a new root table
//!   flushTlb(root)          after a change to tables under root table `root`
//!                           (physical address): every hart translating
//!                           through it, synchronously. Switching roots must
//!                           itself flush, so other harts need nothing.
//!   retireRoot(pa)          a root table is being destroyed: no hart may keep
//!                           translating through it once this returns
//!   setTimer(hart, ticks)   program a hart's timer (absolute)
//!   sendIpi(hart)           make another hart reschedule
//!   irqMask(line) / irqUnmask(line)
//!   debugWrite([]const u8)
//!   elf_machine: u16
//!
//! Power-off is not an effect the core performs: when the root task asks
//! for it, `exitRequested()` returns the code and the arch layer acts on it.
const std = @import("std");
const abi = @import("abi");
const klog = @import("klog.zig");
const fdt = @import("fdt.zig");
const elf = @import("elf.zig");

pub const ObjId = u32;
pub const max_harts = 16;
pub const max_irqs = 1024;
pub const page_size: u64 = 4096;
/// Untyped regions earn one object-table entry per this many bytes.
pub const bytes_per_object: u64 = 4096;
/// Longest scheduling period accepted (in timer ticks), so time arithmetic
/// can never overflow: about 325 days at 10 MHz.
pub const max_period: u64 = 1 << 48;
/// Leases can point at leases; resolution stops after this many hops.
pub const max_lease_depth = 4;
/// A table entry's last generation: it is retired there (never reused).
pub const max_gen: u32 = std.math.maxInt(u32);

/// Registers the core reads and writes in a thread's saved context.
pub const Reg = enum { pc, sp, a0, a1, a2, a3, a4, a5, a6, a7 };

/// A capability as stored in a CNode slot (16 bytes).
pub const Cap = extern struct {
    object: ObjId = 0,
    gen: u32 = 0,
    rights: u16 = 0,
    protocol: u16 = 0,
    badge: u32 = 0,

    pub fn isNull(c: Cap) bool {
        return c.object == 0;
    }
    pub fn r(c: Cap) abi.Rights {
        return abi.Rights.fromBits(c.rights);
    }
};

/// One object-table entry (32 bytes). The table is allocated once at boot
/// and never moves; generations survive memory reuse because they live here,
/// not in the object's memory.
pub const Entry = extern struct {
    gen: u32,
    kind: abi.Kind,
    size_bits: u8,
    /// Frames: slot index in the page table that maps them (bit 15 = device memory).
    /// Page tables: slot index in their parent table.
    flags: u16,
    parent: ObjId,
    first_child: ObjId,
    next_sibling: ObjId,
    /// Frames and page tables: the page table they are mapped in (0 = none).
    /// Free entries: next free entry.
    link: ObjId,
    /// Physical address of the object's memory (Irq: the line number).
    addr: u64,

    comptime {
        std.debug.assert(@sizeOf(Entry) == 32);
    }
};

const flag_device: u16 = 1 << 15;
const slot_mask: u16 = 0x7fff;

pub const Error = error{
    InvalidCap,
    WrongKind,
    NoRights,
    InvalidArgument,
    NoMemory,
    NoObjects,
    SlotOccupied,
    SlotEmpty,
    LeaseExpired,
    LeaseExhausted,
    AlreadyMapped,
    NoPageTable,
    NotMapped,
    Aborted,
    WouldBlock,
    ProtocolMismatch,
    InvalidState,
    UnknownMethod,
    UnknownSyscall,
};

pub fn statusOf(e: Error) abi.Status {
    return switch (e) {
        error.InvalidCap => .invalid_cap,
        error.WrongKind => .wrong_kind,
        error.NoRights => .no_rights,
        error.InvalidArgument => .invalid_argument,
        error.NoMemory => .no_memory,
        error.NoObjects => .no_objects,
        error.SlotOccupied => .slot_occupied,
        error.SlotEmpty => .slot_empty,
        error.LeaseExpired => .lease_expired,
        error.LeaseExhausted => .lease_exhausted,
        error.AlreadyMapped => .already_mapped,
        error.NoPageTable => .no_page_table,
        error.NotMapped => .not_mapped,
        error.Aborted => .aborted,
        error.WouldBlock => .would_block,
        error.ProtocolMismatch => .protocol_mismatch,
        error.InvalidState => .invalid_state,
        error.UnknownMethod => .unknown_method,
        error.UnknownSyscall => .unknown_syscall,
    };
}

/// Extern and padding-free on purpose: it is copied into kernel memory, and
/// the simulator checks that kernel memory is bit-for-bit deterministic.
pub const Fault = extern struct {
    kind: abi.FaultKind,
    _pad: u32 = 0,
    addr: u64,
    pc: u64,
    raw: u64,
};

pub const Event = union(enum) {
    /// The current thread made a system call; its context holds the arguments
    /// and its pc already points past the call instruction.
    syscall,
    /// The current thread took a fault.
    fault: Fault,
    timer,
    irq: u32,
    ipi,
};

pub const BootConfig = struct {
    platform: *const fdt.Platform,
    /// Physical ranges the kernel must not hand out (kernel image, DTB, …).
    reserved: []const fdt.Range,
    root_elf: []const u8,
    /// The device tree, copied read-only into the root task (may be empty).
    dtb: []const u8 = &.{},
    /// What the loader measured (zero if nothing did); passed on in BootInfo.
    measurement: abi.Measurement = .{},
    now: u64,
    root_budget_ticks: u64,
};

pub const Range = fdt.Range;

pub fn Kernel(comptime A: type) type {
    const P = A.Paging;
    const levels: u8 = P.levels;
    const entries_per_table: usize = P.entries;

    return struct {
        const Self = @This();

        // -------------------------------------------------------------------
        // Object bodies (kernel memory carved from untyped regions)

        pub const Thread = struct {
            ctx: A.Context,
            id: ObjId,
            state: abi.ThreadState,
            prio: u8,
            /// Highest priority this thread may give itself or others.
            mcp: u8,
            /// The hart this thread is queued on or running on.
            hart: u8,
            cspace: Cap,
            vspace: Cap,
            fault_ep: Cap,
            ipc_frame: Cap,
            ipc_vaddr: u64,
            /// The scheduling context the thread runs on now (maybe donated).
            sc: ObjId,
            /// The scheduling context bound to this thread.
            home_sc: ObjId,
            // Queue links (run queue, endpoint queue or signal queue).
            next: ObjId,
            prev: ObjId,
            queue: ObjId,
            // While blocked sending: how it was sent.
            send_badge: u32,
            send_grant: bool,
            send_call: bool,
            /// Protocol ids of the capability used to send, or to receive.
            send_protocol: u16,
            recv_protocol: u16,
            /// A caller waiting for this thread's reply.
            reply_to: ObjId,
            /// The thread this one waits on for a reply.
            reply_from: ObjId,
            /// Pending fault (kind 0 = none).
            fault: Fault,
            /// A signal that also ends this thread's waits to receive.
            bound_signal: ObjId,

            fn faulted(t: *const Thread) bool {
                return @backingInt(t.fault.kind) != 0;
            }
            fn clearFault(t: *Thread) void {
                t.fault = std.mem.zeroes(Fault);
            }
        };

        pub const Untyped = struct {
            base: u64,
            size: u64,
            low: u64,
            high: u64,
            objects_left: u32,
            objects_initial: u32,
            is_device: bool,
        };

        pub const Endpoint = struct {
            head: ObjId,
            tail: ObjId,
            mode: enum(u8) { idle, sending, receiving },
        };

        pub const Signal = struct {
            word: u64,
            head: ObjId,
            tail: ObjId,
            /// The thread whose receives this signal also ends, if any.
            bound: ObjId,
            _pad: u32,
            /// An armed alarm: when it fires (0 = none), the bits it sets,
            /// and its place on that hart's alarm list (sorted by time).
            alarm_at: u64,
            alarm_bits: u64,
            next_alarm: ObjId,
            alarm_hart: u32,
        };

        pub const SchedContext = struct {
            budget: u64,
            period: u64,
            remaining: u64,
            refill_at: u64,
            /// Every tick ever charged to this context (SchedContext.info):
            /// how much time its threads, and servers it was lent to, used.
            consumed: u64,
            hart: u8,
            configured: bool,
            throttled: bool,
            /// Thread this context is bound to (its home).
            owner: ObjId,
            /// Thread running on it now (owner, or a server it was donated to).
            holder: ObjId,
            next_release: ObjId,
        };

        pub const Lease = struct {
            target: Cap,
            rights: u16,
            armed: bool,
            limited: bool,
            uses: u32,
            expires: u64,
        };

        pub const Table = struct {
            ptes: [entries_per_table]u64,
            /// Object mapped or linked at each slot (0 = none or kernel).
            shadow: [entries_per_table]ObjId,
        };

        pub const IrqState = struct {
            obj: ObjId = 0,
            gen: u32 = 0,
            signal: Cap = .{},
            masked: bool = true,
        };

        pub const Hart = struct {
            online: bool = false,
            current: ObjId = 0,
            started_at: u64 = 0,
            run_head: [256]ObjId = @splat(0),
            run_tail: [256]ObjId = @splat(0),
            bitmap: [4]u64 = @splat(0),
            release_head: ObjId = 0,
            /// Signals with alarms armed on this hart, soonest first.
            alarm_head: ObjId = 0,
            timer_deadline: u64 = std.math.maxInt(u64),
            /// The running thread used up a full-bandwidth budget: it goes
            /// to the back of its queue at the next reschedule.
            rotate: bool = false,
            /// A thread this kernel entry made runnable on this hart, held
            /// out of the run queue: the entry's reschedule runs it at once
            /// if nothing as urgent is queued (an IPC handoff then never
            /// touches the queue), else queues it as if it always had been.
            /// Zero between kernel entries.
            direct: ObjId = 0,
        };

        pub const Stats = struct {
            syscalls: u64 = 0,
            ipc_transfers: u64 = 0,
            context_switches: u64 = 0,
            faults: u64 = 0,
            irqs: u64 = 0,
        };

        table: []Entry = &.{},
        free_head: ObjId = 0,
        free_count: u32 = 0,
        harts: [max_harts]Hart = @splat(.{}),
        hart_count: u32 = 1,
        now: u64 = 0,
        timebase_hz: u64 = 0,
        irqs: [max_irqs]IrqState = @splat(.{}),
        irq_count: u32 = 0,
        /// Lines below this are the kernel's own (a GIC's software and per-CPU interrupts).
        irq_first: u32 = 1,
        irq_control: ObjId = 0,
        sched_control: ObjId = 0,
        debug_console: ObjId = 0,
        stats: Stats = .{},
        exit_code: ?u16 = null,
        log_buf: [256]u8 = undefined,
        /// Pending reschedules on other harts, for arch to deliver as IPIs.
        kick_mask: u32 = 0,
        handling_hart: u32 = 0,

        /// Set once the root task has asked to power off.
        pub fn exitRequested(k: *const Self) ?u16 {
            return k.exit_code;
        }

        // -------------------------------------------------------------------
        // Object table

        fn entry(k: *Self, id: ObjId) *Entry {
            return &k.table[id];
        }

        fn at(comptime T: type, pa: u64) *T {
            return @ptrFromInt(A.physToVirt(pa));
        }

        fn body(k: *Self, comptime T: type, id: ObjId) *T {
            return at(T, k.table[id].addr);
        }

        pub fn thread(k: *Self, id: ObjId) *Thread {
            return k.body(Thread, id);
        }

        /// The entry a capability names, if the capability is still valid.
        fn validate(k: *Self, c: Cap) ?*Entry {
            if (c.object == 0 or c.object >= k.table.len) return null;
            const e = &k.table[c.object];
            if (e.gen != c.gen or e.kind == .free) return null;
            return e;
        }

        fn validateKind(k: *Self, c: Cap, kind: abi.Kind) ?*Entry {
            const e = k.validate(c) orelse return null;
            return if (e.kind == kind) e else null;
        }

        fn alive(k: *Self, id: ObjId, kind: abi.Kind) bool {
            return id != 0 and id < k.table.len and k.table[id].kind == kind;
        }

        fn capTo(k: *Self, id: ObjId, rights: abi.Rights) Cap {
            return .{ .object = id, .gen = k.table[id].gen, .rights = rights.bits() };
        }

        fn allocEntry(k: *Self) ?ObjId {
            const id = k.free_head;
            if (id == 0) return null;
            k.free_head = k.table[id].link;
            k.free_count -= 1;
            return id;
        }

        fn freeEntry(k: *Self, id: ObjId) void {
            const e = &k.table[id];
            e.gen += 1;
            e.kind = .free;
            e.parent = 0;
            e.first_child = 0;
            e.next_sibling = 0;
            e.addr = 0;
            e.flags = 0;
            // An entry whose generations are used up is retired, never handed
            // out again: one more would come round to old capabilities' values.
            if (e.gen == max_gen) {
                e.link = 0;
                return;
            }
            e.link = k.free_head;
            k.free_head = id;
            k.free_count += 1;
        }

        fn newEntry(k: *Self, kind: abi.Kind, size_bits: u8, addr: u64, parent: ObjId) ObjId {
            const id = k.allocEntry().?; // budgets guarantee an entry exists
            const e = &k.table[id];
            e.kind = kind;
            e.size_bits = size_bits;
            e.addr = addr;
            e.flags = 0;
            e.link = 0;
            e.first_child = 0;
            e.parent = parent;
            if (parent != 0) {
                e.next_sibling = k.table[parent].first_child;
                k.table[parent].first_child = id;
            } else e.next_sibling = 0;
            return id;
        }

        // -------------------------------------------------------------------
        // Logging

        pub fn log(k: *Self, comptime event: []const u8, fields: anytype) void {
            const line = klog.format(&k.log_buf, event, fields) catch {
                A.debugWrite(klog.prefix ++ " log_truncated event=" ++ event ++ "\n");
                return;
            };
            A.debugWrite(line);
            A.debugWrite("\n");
        }

        // -------------------------------------------------------------------
        // Boot

        const max_free = 32;

        /// Build the initial system: object table, untyped regions covering
        /// all free memory, kernel singletons, and the root task.
        pub fn boot(k: *Self, cfg: BootConfig) !void {
            const plat = cfg.platform;
            k.now = cfg.now;
            k.timebase_hz = plat.timebase_hz;
            k.hart_count = @intCast(@min(max_harts, @max(1, plat.harts_len)));
            const lines = plat.deviceIrqs();
            k.irq_first = lines.first;
            k.irq_count = @min(lines.end, max_irqs);

            var free: [max_free]Range = undefined;
            var nfree: usize = 0;
            for (plat.memoryRanges()) |m| {
                if (nfree == max_free) break;
                free[nfree] = m;
                nfree += 1;
            }
            for (plat.reservedRanges()) |r| subtractRange(&free, &nfree, r);
            for (cfg.reserved) |r| subtractRange(&free, &nfree, r);
            var free_bytes: u64 = 0;
            for (free[0..nfree]) |*f| {
                const b = std.mem.alignForward(u64, f.base, page_size);
                const e = std.mem.alignBackward(u64, f.end(), page_size);
                f.* = if (e > b) .{ .base = b, .size = e - b } else .{ .base = b, .size = 0 };
                free_bytes += f.size;
            }

            const boot_reserve: u64 = 64 + k.irq_count;
            var device_objects: u64 = 0;
            for (plat.deviceRanges()) |d| device_objects += deviceBudget(d);
            const n_entries = free_bytes / bytes_per_object + boot_reserve +
                device_objects + abi.max_boot_untyped;
            const table_bytes = std.mem.alignForward(u64, n_entries * @sizeOf(Entry), page_size);
            const table_pa = bootAlloc(&free, nfree, table_bytes) orelse return error.OutOfMemory;
            // Root untyped bodies (they have no parent region to live in).
            const bodies_bytes = std.mem.alignForward(u64, abi.max_boot_untyped * 64, page_size);
            var bodies_pa = bootAlloc(&free, nfree, bodies_bytes) orelse return error.OutOfMemory;
            const bodies_end = bodies_pa + bodies_bytes;

            const tptr: [*]Entry = @ptrFromInt(A.physToVirt(table_pa));
            k.table = tptr[0..@intCast(n_entries)];
            @memset(std.mem.sliceAsBytes(k.table), 0);
            // Entry 0 is the null object and is never allocated.
            k.free_head = 0;
            k.free_count = 0;
            var i: usize = k.table.len - 1;
            while (i > 0) : (i -= 1) {
                k.table[i].link = k.free_head;
                k.free_head = @intCast(i);
                k.free_count += 1;
            }

            k.irq_control = k.newEntry(.irq_control, 0, 0, 0);
            k.sched_control = k.newEntry(.sched_control, 0, 0, 0);
            k.debug_console = k.newEntry(.debug_console, 0, 0, 0);

            // Untyped regions: free RAM first, then device memory.
            var untyped: [abi.max_boot_untyped]ObjId = undefined;
            var nut: usize = 0;
            for (free[0..nfree]) |f| {
                if (f.size < page_size or nut == abi.max_boot_untyped) continue;
                untyped[nut] = k.makeRootUntyped(&bodies_pa, bodies_end, f, false, @intCast(f.size / bytes_per_object));
                nut += 1;
            }
            const ram_untyped = nut;
            dev: for (plat.deviceRanges()) |d| {
                if (nut == abi.max_boot_untyped) break;
                for (plat.memoryRanges()) |m| if (d.base < m.end() and m.base < d.end()) continue :dev;
                const b = std.mem.alignBackward(u64, d.base, page_size);
                const e = std.mem.alignForward(u64, d.end(), page_size);
                const pages = (e - b) / page_size;
                untyped[nut] = k.makeRootUntyped(&bodies_pa, bodies_end, .{ .base = b, .size = e - b }, true, @intCast(@min(pages, deviceBudget(d))));
                nut += 1;
            }
            if (ram_untyped == 0) return error.OutOfMemory;

            // The root task is built from the largest RAM region.
            var big: usize = 0;
            for (untyped[0..ram_untyped], 0..) |u, j| {
                if (k.body(Untyped, u).size > k.body(Untyped, untyped[big]).size) big = j;
            }
            try k.buildRoot(cfg, untyped[big], untyped[0..nut]);
            k.log("boot_memory", .{
                .free_bytes = free_bytes,
                .untyped = nut,
                .device_untyped = nut - ram_untyped,
                .object_table = k.table.len,
                .objects_free = k.free_count,
            });
        }

        /// How many objects (frames, mostly) a device range may be cut into:
        /// a device's registers need few; a PCI window or configuration
        /// space serves many devices.
        fn deviceBudget(d: Range) u64 {
            return if (d.size >= 0x1000_0000) 1024 else 64;
        }

        fn makeRootUntyped(k: *Self, bodies_pa: *u64, bodies_end: u64, r: Range, device: bool, budget: u32) ObjId {
            std.debug.assert(bodies_pa.* + 64 <= bodies_end);
            const id = k.newEntry(.untyped, 0, bodies_pa.*, 0);
            bodies_pa.* += 64;
            k.body(Untyped, id).* = .{
                .base = r.base,
                .size = r.size,
                .low = r.base,
                .high = r.base + r.size,
                .objects_left = budget,
                .objects_initial = budget,
                .is_device = device,
            };
            return id;
        }

        fn subtractRange(free: *[max_free]Range, n: *usize, r: Range) void {
            var i: usize = 0;
            while (i < n.*) {
                const f = free[i];
                if (r.size == 0 or r.end() <= f.base or r.base >= f.end()) {
                    i += 1;
                    continue;
                }
                const left: Range = .{ .base = f.base, .size = if (r.base > f.base) r.base - f.base else 0 };
                const right: Range = .{ .base = r.end(), .size = if (f.end() > r.end()) f.end() - r.end() else 0 };
                free[i] = left;
                if (right.size > 0 and n.* < max_free) {
                    free[n.*] = right;
                    n.* += 1;
                }
                i += 1;
            }
        }

        fn bootAlloc(free: *[max_free]Range, n: usize, size: u64) ?u64 {
            for (free[0..n]) |*f| if (f.size >= size) {
                const pa = f.base;
                f.base += size;
                f.size -= size;
                return pa;
            };
            return null;
        }

        fn buildRoot(k: *Self, cfg: BootConfig, ut: ObjId, all_untyped: []const ObjId) !void {
            const L = abi.RootLayout;
            const cnode = try k.retypeInternal(ut, .cnode, abi.root_cnode_bits);
            const vspace = try k.retypeInternal(ut, .page_table, levels - 1);
            const tid = try k.retypeInternal(ut, .thread, 0);
            const sc = try k.retypeInternal(ut, .sched_context, 0);
            const bi_frame = try k.retypeInternal(ut, .frame, 12);
            const ipc_frame = try k.retypeInternal(ut, .frame, 12);

            const ro: abi.Rights = .{ .read = true };
            const rw: abi.Rights = .{ .read = true, .write = true };
            try k.mapRootPage(ut, vspace, bi_frame, L.boot_info, ro);
            try k.mapRootPage(ut, vspace, ipc_frame, L.ipc_buffer, rw);
            for (0..L.stack_pages) |p| {
                const f = try k.retypeInternal(ut, .frame, 12);
                try k.mapRootPage(ut, vspace, f, L.stack_top - (p + 1) * page_size, rw);
            }

            // A read-only copy of the device tree, so the root task can find devices.
            const dtb_pages = @min(std.math.divCeil(usize, cfg.dtb.len, page_size) catch 0, L.max_dtb_pages);
            const dtb_len = @min(cfg.dtb.len, dtb_pages * page_size);
            for (0..dtb_pages) |p| {
                const f = try k.retypeInternal(ut, .frame, 12);
                const dst: [*]u8 = @ptrFromInt(A.physToVirt(k.table[f].addr));
                const n = @min(page_size, dtb_len - p * page_size);
                @memcpy(dst[0..n], cfg.dtb[p * page_size ..][0..n]);
                // Whole but shorter than its header says (free space left
                // out): the copy's header says how long it is.
                if (p == 0 and dtb_len == cfg.dtb.len and dtb_len >= 8 and std.mem.readInt(u32, dst[4..8], .big) > dtb_len)
                    std.mem.writeInt(u32, dst[4..8], @intCast(dtb_len), .big);
                try k.mapRootPage(ut, vspace, f, L.dtb + p * page_size, ro);
            }

            const img = try elf.Image.parse(cfg.root_elf, A.elf_machine);
            var segs = img.segments();
            while (try segs.next()) |seg| {
                const start = std.mem.alignBackward(u64, seg.vaddr, page_size);
                const end = std.mem.alignForward(u64, seg.vaddr + seg.mem_size, page_size);
                var va = start;
                while (va < end) : (va += page_size) {
                    const f = try k.retypeInternal(ut, .frame, 12);
                    const dst: [*]u8 = @ptrFromInt(A.physToVirt(k.table[f].addr));
                    // Copy the part of the segment's file data inside this page.
                    const page_lo = @max(va, seg.vaddr);
                    const page_hi = @min(va + page_size, seg.vaddr + seg.data.len);
                    if (page_hi > page_lo) {
                        const src_off: usize = @intCast(page_lo - seg.vaddr);
                        const dst_off: usize = @intCast(page_lo - va);
                        const len: usize = @intCast(page_hi - page_lo);
                        @memcpy(dst[dst_off..][0..len], seg.data[src_off..][0..len]);
                    }
                    const rights: abi.Rights = .{ .read = seg.read, .write = seg.write, .execute = seg.execute };
                    try k.mapRootPage(ut, vspace, f, va, rights);
                }
            }

            // Capability space.
            const slots = k.cnodeSlots(cnode);
            const all = abi.Rights.all;
            slots[abi.RootSlot.cnode] = k.capTo(cnode, all);
            slots[abi.RootSlot.vspace] = k.capTo(vspace, all);
            slots[abi.RootSlot.thread] = k.capTo(tid, all);
            slots[abi.RootSlot.sched_context] = k.capTo(sc, all);
            slots[abi.RootSlot.irq_control] = k.capTo(k.irq_control, all);
            slots[abi.RootSlot.sched_control] = k.capTo(k.sched_control, all);
            slots[abi.RootSlot.debug_console] = k.capTo(k.debug_console, all);
            slots[abi.RootSlot.boot_info_frame] = k.capTo(bi_frame, ro);
            slots[abi.RootSlot.ipc_buffer_frame] = k.capTo(ipc_frame, rw);

            const bi = at(abi.BootInfo, k.table[bi_frame].addr);
            bi.* = .{
                .measurement = cfg.measurement,
                .timebase_hz = k.timebase_hz,
                .boot_time = cfg.now,
                .hart_count = k.hart_count,
                .untyped_count = @intCast(all_untyped.len),
                .first_free_slot = abi.RootSlot.first_untyped + @as(u32, @intCast(all_untyped.len)),
                .root_cnode_slots = 1 << abi.root_cnode_bits,
                .user_top = P.user_top,
                .page_size = page_size,
                .dtb_addr = if (dtb_len > 0) L.dtb else 0,
                .dtb_size = dtb_len,
                .untyped = undefined,
            };
            for (all_untyped, 0..) |u, j| {
                slots[abi.RootSlot.first_untyped + j] = k.capTo(u, all);
                const b = k.body(Untyped, u);
                bi.untyped[j] = .{ .base = b.base, .size = b.size, .objects = b.objects_left, .is_device = @intFromBool(b.is_device) };
            }

            const t = k.thread(tid);
            t.ctx = A.Context.init(img.entry, L.stack_top, L.boot_info);
            t.cspace = k.capTo(cnode, all);
            t.vspace = k.capTo(vspace, all);
            t.ipc_frame = k.capTo(ipc_frame, rw);
            t.ipc_vaddr = L.ipc_buffer;
            t.prio = 255;
            t.mcp = 255;
            const s = k.body(SchedContext, sc);
            s.* = .{
                .budget = cfg.root_budget_ticks,
                .period = cfg.root_budget_ticks,
                .remaining = cfg.root_budget_ticks,
                .refill_at = cfg.now + cfg.root_budget_ticks,
                .consumed = 0,
                .hart = 0,
                .configured = true,
                .throttled = false,
                .owner = tid,
                .holder = tid,
                .next_release = 0,
            };
            t.sc = sc;
            t.home_sc = sc;
            k.makeRunnable(t);
            k.log("root_task", .{ .thread = tid, .entry = klog.hex(img.entry), .untyped = all_untyped.len });
        }

        /// Map a 4 KiB frame into the root task, creating page tables as needed.
        fn mapRootPage(k: *Self, ut: ObjId, root: ObjId, frame: ObjId, va: u64, rights: abi.Rights) !void {
            var lvl: u8 = levels - 1;
            var tbl = root;
            while (lvl > 0) : (lvl -= 1) {
                const t = k.body(Table, tbl);
                const idx = P.index(va, lvl);
                if (t.shadow[idx] == 0) {
                    const child = try k.retypeInternal(ut, .page_table, lvl - 1);
                    k.linkTable(tbl, idx, child);
                }
                tbl = t.shadow[idx];
            }
            try k.installFrame(tbl, P.index(va, 0), frame, rights);
        }

        fn retypeInternal(k: *Self, ut: ObjId, kind: abi.Kind, size_bits: u8) !ObjId {
            return k.retype(ut, kind, size_bits) catch return error.OutOfMemory;
        }

        // -------------------------------------------------------------------
        // Untyped memory

        const Layout = struct { size: u64, alignment: u64, top: bool };

        fn layoutOf(kind: abi.Kind, size_bits: u8) Error!Layout {
            return switch (kind) {
                .untyped => if (size_bits < 12 or size_bits > 47) error.InvalidArgument else .{ .size = @as(u64, 1) << @intCast(size_bits), .alignment = page_size, .top = false },
                .cnode => blk: {
                    if (size_bits < 1 or size_bits > 16) return error.InvalidArgument;
                    const size = @as(u64, @sizeOf(Cap)) << @intCast(size_bits);
                    break :blk if (size < page_size) .{ .size = size, .alignment = 64, .top = true } else .{ .size = size, .alignment = page_size, .top = false };
                },
                .thread => .{ .size = std.mem.alignForward(u64, @sizeOf(Thread), 64), .alignment = 64, .top = true },
                .frame => switch (size_bits) {
                    12, 21, 30 => .{ .size = @as(u64, 1) << @intCast(size_bits), .alignment = @as(u64, 1) << @intCast(size_bits), .top = false },
                    else => error.InvalidArgument,
                },
                .page_table => if (size_bits >= levels) error.InvalidArgument else .{ .size = std.mem.alignForward(u64, @sizeOf(Table), page_size), .alignment = page_size, .top = false },
                .endpoint => small(Endpoint),
                .signal => small(Signal),
                .sched_context => small(SchedContext),
                .lease => small(Lease),
                else => error.InvalidArgument,
            };
        }

        fn small(comptime T: type) Layout {
            return .{ .size = std.mem.alignForward(u64, @sizeOf(T), 64), .alignment = 64, .top = true };
        }

        /// Create one object from an untyped region. Returns its id.
        fn retype(k: *Self, ut: ObjId, kind: abi.Kind, size_bits: u8) Error!ObjId {
            const u = k.body(Untyped, ut);
            const lay = try layoutOf(kind, size_bits);
            if (u.is_device and kind != .frame) return error.WrongKind;
            // Compare in u64: a large child region's budget does not fit in u32,
            // but such a region can never fit in our budget either.
            const child_budget64: u64 = if (kind == .untyped) lay.size / bytes_per_object else 0;
            if (@as(u64, u.objects_left) < 1 + child_budget64) return error.NoObjects;
            const child_budget: u32 = @intCast(child_budget64);

            // Untyped children need a body too (from the top of this region).
            const body_bytes: u64 = if (kind == .untyped) 64 else 0;
            var low = u.low;
            var high = u.high;
            var addr: u64 = undefined;
            if (lay.top) {
                if (high < lay.size) return error.NoMemory;
                addr = std.mem.alignBackward(u64, high - lay.size, lay.alignment);
                if (addr < low) return error.NoMemory;
                high = addr;
            } else {
                addr = std.mem.alignForward(u64, low, lay.alignment);
                if (addr + lay.size > high or addr + lay.size < addr) return error.NoMemory;
                low = addr + lay.size;
            }
            var body_pa: u64 = 0;
            if (body_bytes > 0) {
                body_pa = std.mem.alignBackward(u64, high - body_bytes, 64);
                if (body_pa < low) return error.NoMemory;
                high = body_pa;
            }
            u.low = low;
            u.high = high;
            u.objects_left -= 1 + child_budget;

            if (!u.is_device) @memset(@as([*]u8, @ptrFromInt(A.physToVirt(addr)))[0..@intCast(lay.size)], 0);

            const id = k.newEntry(kind, size_bits, if (kind == .untyped) body_pa else addr, ut);
            switch (kind) {
                .untyped => k.body(Untyped, id).* = .{
                    .base = addr,
                    .size = lay.size,
                    .low = addr,
                    .high = addr + lay.size,
                    .objects_left = child_budget,
                    .objects_initial = child_budget,
                    .is_device = false,
                },
                .frame => if (u.is_device) {
                    k.table[id].flags = flag_device;
                },
                .page_table => if (size_bits == levels - 1) A.initRootTable(&k.body(Table, id).ptes),
                .thread => {
                    const t = k.thread(id);
                    t.id = id;
                    t.state = .inactive;
                    t.ctx = A.Context.init(0, 0, 0);
                },
                else => {},
            }
            return id;
        }

        /// Destroy every object created from `ut` (recursively) and free its memory.
        fn resetUntyped(k: *Self, ut: ObjId) void {
            while (k.table[ut].first_child != 0) {
                var n = k.table[ut].first_child;
                while (k.table[n].first_child != 0) n = k.table[n].first_child;
                const p = k.table[n].parent;
                k.table[p].first_child = k.table[n].next_sibling;
                k.destroy(n);
            }
            const u = k.body(Untyped, ut);
            u.low = u.base;
            u.high = u.base + u.size;
            u.objects_left = u.objects_initial;
        }

        /// Tear down one object: undo every relationship other live objects
        /// have with it, then free its table entry (bumping the generation).
        fn destroy(k: *Self, id: ObjId) void {
            const e = &k.table[id];
            switch (e.kind) {
                .thread => k.destroyThread(k.thread(id)),
                .endpoint => k.abortEndpoint(id),
                .signal => {
                    k.abortQueue(&k.body(Signal, id).head, &k.body(Signal, id).tail);
                    k.unbindSignal(id);
                    k.removeAlarm(id);
                },
                .sched_context => k.destroySchedContext(id),
                .frame => k.unmapFrame(id),
                .page_table => k.destroyTable(id),
                .irq => {
                    const line: u32 = @intCast(e.addr);
                    A.irqMask(line);
                    k.irqs[line] = .{};
                },
                else => {},
            }
            k.freeEntry(id);
        }

        // -------------------------------------------------------------------
        // CNodes

        fn cnodeSlots(k: *Self, id: ObjId) []Cap {
            const e = k.table[id];
            const p: [*]Cap = @ptrFromInt(A.physToVirt(e.addr));
            return p[0 .. @as(usize, 1) << @intCast(e.size_bits)];
        }

        fn slotIn(k: *Self, cnode_cap: Cap, index: u64) Error!*Cap {
            const e = k.validateKind(cnode_cap, .cnode) orelse return error.InvalidCap;
            _ = e;
            const slots = k.cnodeSlots(cnode_cap.object);
            if (index >= slots.len) return error.InvalidArgument;
            return &slots[@intCast(index)];
        }

        /// The slot `cptr` names in thread `t`'s capability space.
        fn slot(k: *Self, t: *Thread, cptr: u64) Error!*Cap {
            if (cptr == 0) return error.InvalidCap;
            return k.slotIn(t.cspace, cptr) catch |err| switch (err) {
                error.InvalidArgument => error.InvalidCap,
                else => err,
            };
        }

        const Resolved = struct { cap: Cap, kind: abi.Kind };

        /// Look up `cptr` in `t`'s CSpace and follow armed leases to their
        /// target, intersecting rights and enforcing expiry and use limits.
        fn resolve(k: *Self, t: *Thread, cptr: u64) Error!Resolved {
            return k.resolveCap((try k.slot(t, cptr)).*);
        }

        /// Follow leases from a stored capability. Capabilities the kernel
        /// keeps on behalf of a thread (fault endpoint, IRQ signal) are stored
        /// unresolved and resolved here on every use, so revoking a lease
        /// cuts them off too.
        fn resolveCap(k: *Self, c0: Cap) Error!Resolved {
            var c = c0;
            var rights = c.r();
            var depth: usize = 0;
            while (true) {
                const e = k.validate(c) orelse return error.InvalidCap;
                if (e.kind != .lease) return .{ .cap = .{ .object = c.object, .gen = c.gen, .rights = rights.intersect(c.r()).bits(), .protocol = c.protocol, .badge = c.badge }, .kind = e.kind };
                const l = k.body(Lease, c.object);
                if (!l.armed) return .{ .cap = c, .kind = .lease };
                if (depth == max_lease_depth) return error.InvalidCap;
                depth += 1;
                if (l.expires != 0 and k.now >= l.expires) return error.LeaseExpired;
                if (l.limited) {
                    if (l.uses == 0) return error.LeaseExhausted;
                    l.uses -= 1;
                }
                rights = rights.intersect(abi.Rights.fromBits(l.rights));
                c = l.target;
            }
        }

        fn resolveKind(k: *Self, t: *Thread, cptr: u64, kind: abi.Kind, required: abi.Rights) Error!Cap {
            const res = try k.resolve(t, cptr);
            if (res.kind != kind) return error.WrongKind;
            if (!res.cap.r().contains(required)) return error.NoRights;
            return res.cap;
        }

        /// Invalidate all capabilities to an object, cancelling anything
        /// queued on it, and return a fresh capability.
        fn revokeObject(k: *Self, id: ObjId) void {
            const e = &k.table[id];
            switch (e.kind) {
                .endpoint => k.abortEndpoint(id),
                .signal => {
                    k.abortQueue(&k.body(Signal, id).head, &k.body(Signal, id).tail);
                    k.unbindSignal(id);
                    k.removeAlarm(id);
                },
                .frame => k.unmapFrame(id),
                else => {},
            }
            // The caller made sure a generation is left (see revokable).
            e.gen += 1;
        }

        /// Whether revoking leaves a generation for freeing the entry later.
        fn revokable(k: *Self, id: ObjId) bool {
            return k.table[id].gen < max_gen - 1;
        }

        // -------------------------------------------------------------------
        // Page tables

        fn linkTable(k: *Self, parent: ObjId, idx: usize, child: ObjId) void {
            const pt = k.body(Table, parent);
            pt.ptes[idx] = P.makeTable(k.table[child].addr);
            pt.shadow[idx] = child;
            k.table[child].link = parent;
            k.table[child].flags = @intCast(idx);
            if (k.rootAbove(parent)) |root| A.flushTlb(root);
        }

        fn installFrame(k: *Self, tbl: ObjId, idx: usize, frame: ObjId, rights: abi.Rights) Error!void {
            const pt = k.body(Table, tbl);
            if (pt.shadow[idx] != 0 or P.isValid(pt.ptes[idx])) return error.AlreadyMapped;
            const fe = &k.table[frame];
            if (fe.link != 0) return error.AlreadyMapped;
            pt.ptes[idx] = P.makeLeaf(.{
                .pa = fe.addr,
                .level = k.table[tbl].size_bits,
                .read = rights.read,
                .write = rights.write,
                .execute = rights.execute,
                .device = fe.flags & flag_device != 0,
            });
            pt.shadow[idx] = frame;
            fe.link = tbl;
            fe.flags = (fe.flags & flag_device) | @as(u16, @intCast(idx));
            if (k.rootAbove(tbl)) |root| A.flushTlb(root);
        }

        fn unmapFrame(k: *Self, frame: ObjId) void {
            const fe = &k.table[frame];
            if (fe.link == 0) return;
            const pt = k.body(Table, fe.link);
            const root = k.rootAbove(fe.link);
            const idx = fe.flags & slot_mask;
            pt.ptes[idx] = 0;
            pt.shadow[idx] = 0;
            fe.link = 0;
            fe.flags &= flag_device;
            if (root) |r| A.flushTlb(r);
        }

        fn destroyTable(k: *Self, id: ObjId) void {
            const root = k.rootAbove(id);
            const pt = k.body(Table, id);
            const is_leaf_level = k.table[id].size_bits == 0;
            for (&pt.shadow, 0..) |*s, i| {
                if (s.* == 0) continue;
                const child = &k.table[s.*];
                if (is_leaf_level or child.kind == .frame) {
                    child.link = 0;
                    child.flags &= flag_device;
                } else {
                    child.link = 0;
                    child.flags = 0;
                }
                pt.ptes[i] = 0;
                s.* = 0;
            }
            const parent = k.table[id].link;
            if (parent != 0) {
                const ppt = k.body(Table, parent);
                const idx = k.table[id].flags;
                ppt.ptes[idx] = 0;
                ppt.shadow[idx] = 0;
            }
            // Threads using this address space stop at their next kernel entry;
            // the arch layer makes sure no hart still translates through it.
            for (k.harts[0..k.hart_count], 0..) |h, hi| {
                if (h.current != 0 and k.thread(h.current).vspace.object == id) k.kick(@intCast(hi));
            }
            if (k.table[id].size_bits == levels - 1) A.retireRoot(k.table[id].addr);
            if (root) |r| A.flushTlb(r);
        }

        /// The physical address of the root table `tbl` hangs under (itself if
        /// it is one), or null if it is not attached to a root: then no hart
        /// can translate through it and a change needs no TLB flush.
        fn rootAbove(k: *Self, tbl: ObjId) ?u64 {
            var t = tbl;
            var steps: u8 = 0;
            while (k.table[t].size_bits != levels - 1) : (steps += 1) {
                if (k.table[t].link == 0 or steps >= levels) return null;
                t = k.table[t].link;
            }
            return k.table[t].addr;
        }

        /// Walk to the table at `level` for `va` below root `root`.
        fn walkTo(k: *Self, root: ObjId, va: u64, level: u8) Error!ObjId {
            var tbl = root;
            var lvl: u8 = levels - 1;
            while (lvl > level) : (lvl -= 1) {
                const child = k.body(Table, tbl).shadow[P.index(va, lvl)];
                if (child == 0 or k.table[child].kind != .page_table) return error.NoPageTable;
                tbl = child;
            }
            return tbl;
        }

        /// Physical address of a thread's root page table, if still valid.
        pub fn vspaceRoot(k: *Self, t: *Thread) ?u64 {
            const e = k.validateKind(t.vspace, .page_table) orelse return null;
            if (e.size_bits != levels - 1) return null;
            return e.addr;
        }

        // -------------------------------------------------------------------
        // Scheduling

        fn hartOf(k: *Self, t: *Thread) u8 {
            if (k.alive(t.sc, .sched_context)) return k.body(SchedContext, t.sc).hart;
            return t.hart;
        }

        fn canRun(k: *Self, t: *Thread) bool {
            if (!k.alive(t.sc, .sched_context)) return false;
            const sc = k.body(SchedContext, t.sc);
            return sc.configured and !sc.throttled and sc.remaining > 0;
        }

        /// Make a thread runnable: queue it on its hart, or mark it stalled
        /// if it has no budget to run on.
        fn makeRunnable(k: *Self, t: *Thread) void {
            if (!k.canRun(t)) {
                t.state = .stalled;
                return;
            }
            k.enqueueTail(t);
        }

        /// `enqueue(t, false)`, except that a thread for the hart handling
        /// this entry is held aside instead (see `Hart.direct`).
        fn enqueueTail(k: *Self, t: *Thread) void {
            const hi = k.hartOf(t);
            const h = &k.harts[hi];
            if (hi == k.handling_hart and h.direct == 0) {
                t.hart = hi;
                t.state = .ready;
                t.queue = 0;
                t.next = 0;
                t.prev = 0;
                h.direct = t.id;
                return;
            }
            k.enqueue(t, false);
        }

        /// Queue the held-aside thread (see `Hart.direct`), so the queue's
        /// order is the one it would have had.
        fn flushDirect(k: *Self, h: *Hart) void {
            if (h.direct == 0) return;
            const d = k.thread(h.direct);
            h.direct = 0;
            k.enqueue(d, false);
        }

        fn enqueue(k: *Self, t: *Thread, at_head: bool) void {
            const hi = k.hartOf(t);
            const h = &k.harts[hi];
            if (h.direct == t.id) h.direct = 0 else k.flushDirect(h);
            t.hart = hi;
            t.state = .ready;
            t.queue = 0;
            const p = t.prio;
            if (h.run_head[p] == 0) {
                h.run_head[p] = t.id;
                h.run_tail[p] = t.id;
                t.next = 0;
                t.prev = 0;
            } else if (at_head) {
                t.prev = 0;
                t.next = h.run_head[p];
                k.thread(h.run_head[p]).prev = t.id;
                h.run_head[p] = t.id;
            } else {
                t.next = 0;
                t.prev = h.run_tail[p];
                k.thread(h.run_tail[p]).next = t.id;
                h.run_tail[p] = t.id;
            }
            h.bitmap[p / 64] |= @as(u64, 1) << @intCast(p % 64);
            // Another hart may need to switch to this thread.
            if (h.online and (h.current == 0 or k.thread(h.current).prio < p)) k.kick(hi);
        }

        fn dequeue(k: *Self, t: *Thread) void {
            const h = &k.harts[t.hart];
            if (h.direct == t.id) {
                h.direct = 0;
                return;
            }
            const p = t.prio;
            if (t.prev != 0) k.thread(t.prev).next = t.next else h.run_head[p] = t.next;
            if (t.next != 0) k.thread(t.next).prev = t.prev else h.run_tail[p] = t.prev;
            t.next = 0;
            t.prev = 0;
            if (h.run_head[p] == 0) h.bitmap[p / 64] &= ~(@as(u64, 1) << @intCast(p % 64));
        }

        fn highestReady(h: *const Hart) ?u8 {
            var w: usize = 4;
            while (w > 0) {
                w -= 1;
                if (h.bitmap[w] != 0) return @intCast(w * 64 + 63 - @clz(h.bitmap[w]));
            }
            return null;
        }

        fn kick(k: *Self, hart: u8) void {
            if (hart != k.handling_hart) k.kick_mask |= @as(u32, 1) << @intCast(hart);
        }

        /// Remove a thread from whatever it is in, leaving it inactive.
        fn detach(k: *Self, t: *Thread) void {
            switch (t.state) {
                .ready => k.dequeue(t),
                .running => {
                    k.harts[t.hart].current = 0;
                    k.kick(t.hart);
                },
                .blocked_send, .blocked_recv => {
                    if (k.alive(t.queue, .endpoint)) {
                        const ep = k.body(Endpoint, t.queue);
                        k.unlink(&ep.head, &ep.tail, t);
                        if (ep.head == 0) ep.mode = .idle;
                    }
                },
                .blocked_signal => if (k.alive(t.queue, .signal)) {
                    const s = k.body(Signal, t.queue);
                    k.unlink(&s.head, &s.tail, t);
                },
                .blocked_reply => {
                    if (k.alive(t.reply_from, .thread)) {
                        const server = k.thread(t.reply_from);
                        if (server.reply_to == t.id) server.reply_to = 0;
                    }
                    t.reply_from = 0;
                    // Take back a context this caller lent along its call.
                    k.reclaimLent(t);
                },
                .stalled, .inactive => {},
            }
            t.queue = 0;
            t.state = .inactive;
        }

        /// If `t`'s scheduling context is held by another thread (lent along
        /// a call), take it from that thread, which stalls if it was running
        /// on it. Afterwards the context's holder is `t` again.
        fn reclaimLent(k: *Self, t: *Thread) void {
            if (!k.alive(t.sc, .sched_context)) return;
            const sc = k.body(SchedContext, t.sc);
            if (sc.holder == t.id or !k.alive(sc.holder, .thread)) {
                sc.holder = t.id;
                return;
            }
            const holder = k.thread(sc.holder);
            if (holder.sc == t.sc) {
                holder.sc = 0;
                if (holder.state == .ready or holder.state == .running) {
                    k.detach(holder);
                    holder.state = .stalled;
                }
            }
            sc.holder = t.id;
        }

        fn destroyThread(k: *Self, t: *Thread) void {
            // A caller waiting for our reply is told we are gone, and gets
            // back the scheduling context it lent us.
            if (k.alive(t.reply_to, .thread)) {
                const caller = k.thread(t.reply_to);
                if (caller.state == .blocked_reply and caller.reply_from == t.id) {
                    if (t.sc != 0 and t.sc != t.home_sc) k.returnSchedContext(t, caller);
                    caller.reply_from = 0;
                    k.wake(caller, .aborted);
                }
            }
            t.reply_to = 0;
            k.detach(t);
            if (k.alive(t.bound_signal, .signal)) k.unbindSignal(t.bound_signal);
            if (k.alive(t.home_sc, .sched_context)) {
                const sc = k.body(SchedContext, t.home_sc);
                sc.owner = 0;
                if (sc.holder == t.id) sc.holder = 0;
            }
            t.sc = 0;
            t.home_sc = 0;
        }

        fn destroySchedContext(k: *Self, id: ObjId) void {
            const sc = k.body(SchedContext, id);
            k.removeRelease(id);
            if (k.alive(sc.holder, .thread)) {
                const t = k.thread(sc.holder);
                if (t.sc == id) {
                    t.sc = 0;
                    if (t.state == .ready or t.state == .running) {
                        k.detach(t);
                        t.state = .stalled;
                    }
                }
            }
            if (k.alive(sc.owner, .thread)) {
                const o = k.thread(sc.owner);
                if (o.home_sc == id) o.home_sc = 0;
                if (o.sc == id) o.sc = 0;
            }
        }

        fn removeRelease(k: *Self, id: ObjId) void {
            const sc = k.body(SchedContext, id);
            const h = &k.harts[sc.hart];
            var prev: ObjId = 0;
            var cur = h.release_head;
            while (cur != 0) {
                const c = k.body(SchedContext, cur);
                if (cur == id) {
                    if (prev == 0) h.release_head = c.next_release else k.body(SchedContext, prev).next_release = c.next_release;
                    c.next_release = 0;
                    return;
                }
                prev = cur;
                cur = c.next_release;
            }
        }

        fn removeAlarm(k: *Self, id: ObjId) void {
            const s = k.body(Signal, id);
            if (s.alarm_at == 0) return;
            const h = &k.harts[s.alarm_hart];
            var prev: ObjId = 0;
            var cur = h.alarm_head;
            while (cur != 0) : (cur = k.body(Signal, cur).next_alarm) {
                if (cur == id) {
                    if (prev == 0) h.alarm_head = s.next_alarm else k.body(Signal, prev).next_alarm = s.next_alarm;
                    break;
                }
                prev = cur;
            }
            s.next_alarm = 0;
            s.alarm_at = 0;
        }

        /// Arm signal `id` to fire `bits` at `at`, on hart `hi`'s list.
        fn insertAlarm(k: *Self, id: ObjId, hi: u32, when: u64, bits: u64) void {
            const s = k.body(Signal, id);
            s.alarm_at = when;
            s.alarm_bits = bits;
            s.alarm_hart = hi;
            const h = &k.harts[hi];
            var prev: ObjId = 0;
            var cur = h.alarm_head;
            while (cur != 0 and k.body(Signal, cur).alarm_at <= when) {
                prev = cur;
                cur = k.body(Signal, cur).next_alarm;
            }
            s.next_alarm = cur;
            if (prev == 0) h.alarm_head = id else k.body(Signal, prev).next_alarm = id;
        }

        fn insertRelease(k: *Self, id: ObjId) void {
            const sc = k.body(SchedContext, id);
            const h = &k.harts[sc.hart];
            var prev: ObjId = 0;
            var cur = h.release_head;
            while (cur != 0 and k.body(SchedContext, cur).refill_at <= sc.refill_at) {
                prev = cur;
                cur = k.body(SchedContext, cur).next_release;
            }
            sc.next_release = cur;
            if (prev == 0) h.release_head = id else k.body(SchedContext, prev).next_release = id;
            // That hart may need to reprogram its timer.
            k.kick(sc.hart);
        }

        /// Charge the running thread for time used since it was last charged,
        /// and refill scheduling contexts whose period has come round.
        fn account(k: *Self, hi: u32) void {
            const h = &k.harts[hi];
            if (h.current != 0) {
                const t = k.thread(h.current);
                if (k.alive(t.sc, .sched_context)) {
                    const sc = k.body(SchedContext, t.sc);
                    const used = k.now -| h.started_at;
                    sc.remaining -|= used;
                    sc.consumed +%= used;
                    // Deal with exhaustion now, whatever the thread does in
                    // this entry: it may block or lend the context away, and
                    // then nobody would notice the budget ran out.
                    if (sc.remaining == 0 and !sc.throttled) {
                        if (sc.budget >= sc.period) {
                            k.refill(sc);
                            h.rotate = true;
                        } else {
                            sc.throttled = true;
                            k.insertRelease(t.sc);
                        }
                    }
                }
            }
            h.started_at = k.now;
            while (h.release_head != 0) {
                const id = h.release_head;
                const sc = k.body(SchedContext, id);
                if (sc.refill_at > k.now) break;
                h.release_head = sc.next_release;
                sc.next_release = 0;
                k.refill(sc);
                if (k.alive(sc.holder, .thread)) {
                    const t = k.thread(sc.holder);
                    if (t.state == .stalled and t.sc == id) k.makeRunnable(t);
                }
            }
            while (h.alarm_head != 0) {
                const id = h.alarm_head;
                const s = k.body(Signal, id);
                if (s.alarm_at > k.now) break;
                h.alarm_head = s.next_alarm;
                s.next_alarm = 0;
                s.alarm_at = 0;
                k.signalDeliver(id, s.alarm_bits);
            }
        }

        fn refill(k: *Self, sc: *SchedContext) void {
            sc.remaining = sc.budget;
            sc.throttled = false;
            sc.refill_at +|= sc.period;
            if (sc.refill_at <= k.now) sc.refill_at = k.now +| sc.period;
        }

        fn reschedule(k: *Self, hi: u32) void {
            const h = &k.harts[hi];
            // A thread held aside: if the current thread keeps running, it
            // waits in the queue as usual; else it may run straight away.
            var candidate: ?*Thread = null;
            if (h.direct != 0) {
                const d = k.thread(h.direct);
                if (h.current != 0 and k.thread(h.current).state == .running) k.flushDirect(h) else {
                    h.direct = 0;
                    candidate = d;
                }
            }
            if (h.current != 0) {
                const cur = k.thread(h.current);
                if (cur.state != .running) {
                    h.current = 0;
                } else if (k.vspaceRoot(cur) == null) {
                    k.log("thread_stopped", .{ .thread = cur.id, .reason = "invalid_vspace" });
                    h.current = 0;
                    cur.state = .inactive;
                } else if (k.canRun(cur) and k.hartOf(cur) != hi) {
                    // Its scheduling context moved to another hart (donation).
                    h.current = 0;
                    k.enqueue(cur, true);
                } else if (!k.canRun(cur)) {
                    // Out of budget (already on the release list) or no context.
                    h.current = 0;
                    cur.state = .stalled;
                } else if (h.rotate) {
                    h.current = 0;
                    k.enqueue(cur, false);
                } else if (highestReady(h)) |p| {
                    if (p > cur.prio) {
                        h.current = 0;
                        k.enqueue(cur, true);
                    }
                }
            }
            h.rotate = false;
            if (candidate) |c| if (h.current == 0) {
                // Strictly more urgent than anything queued: the queue would
                // have put it first too. Otherwise it joins the queue's tail.
                if (if (highestReady(h)) |p| p < c.prio else true) {
                    if (k.vspaceRoot(c) != null) {
                        c.state = .running;
                        h.current = c.id;
                        h.started_at = k.now;
                        k.stats.context_switches += 1;
                    } else {
                        k.log("thread_stopped", .{ .thread = c.id, .reason = "invalid_vspace" });
                        c.state = .inactive;
                    }
                } else k.enqueue(c, false);
            } else k.enqueue(c, false);
            while (h.current == 0) {
                const p = highestReady(h) orelse break;
                const t = k.thread(h.run_head[p]);
                k.dequeue(t);
                if (k.vspaceRoot(t) == null) {
                    k.log("thread_stopped", .{ .thread = t.id, .reason = "invalid_vspace" });
                    t.state = .inactive;
                    continue;
                }
                t.state = .running;
                h.current = t.id;
                h.started_at = k.now;
                k.stats.context_switches += 1;
            }
        }

        fn programTimer(k: *Self, hi: u32) void {
            const h = &k.harts[hi];
            var deadline: u64 = std.math.maxInt(u64);
            if (h.current != 0) {
                const t = k.thread(h.current);
                if (k.alive(t.sc, .sched_context)) deadline = k.now +| k.body(SchedContext, t.sc).remaining;
            }
            if (h.release_head != 0) deadline = @min(deadline, k.body(SchedContext, h.release_head).refill_at);
            if (h.alarm_head != 0) deadline = @min(deadline, k.body(Signal, h.alarm_head).alarm_at);
            // Only move the timer earlier. A timer that fires early costs one
            // spurious event (handled like any other); reprogramming on every
            // kernel entry would cost a firmware call each time.
            if (deadline < h.timer_deadline) {
                h.timer_deadline = deadline;
                A.setTimer(hi, deadline);
            }
        }

        // -------------------------------------------------------------------
        // Entry point

        pub fn currentThread(k: *Self, hi: u32) ?*Thread {
            const id = k.harts[hi].current;
            return if (id == 0) null else k.thread(id);
        }

        pub fn hartOnline(k: *Self, hi: u32, now: u64) void {
            k.handling_hart = hi;
            k.harts[hi].online = true;
            k.now = now;
            k.harts[hi].started_at = now;
            k.reschedule(hi);
            k.programTimer(hi);
        }

        /// Handle one event on hart `hi` at time `now` (timer ticks).
        pub fn handle(k: *Self, hi: u32, now: u64, ev: Event) void {
            k.handling_hart = hi;
            k.now = @max(k.now, now);
            k.account(hi);
            const h = &k.harts[hi];
            switch (ev) {
                .syscall => if (h.current != 0) {
                    k.stats.syscalls += 1;
                    k.syscall(k.thread(h.current));
                },
                .fault => |f| if (h.current != 0) {
                    k.stats.faults += 1;
                    k.handleFault(k.thread(h.current), f);
                },
                .timer => {
                    // Clear the pending interrupt; programTimer sets the next one.
                    A.setTimer(hi, std.math.maxInt(u64));
                    h.timer_deadline = std.math.maxInt(u64);
                },
                .irq => |line| {
                    k.stats.irqs += 1;
                    k.handleIrq(line);
                },
                .ipi => {},
            }
            k.reschedule(hi);
            k.programTimer(hi);
        }

        /// Harts that need an IPI after the last `handle` call; clears the set.
        pub fn takeKicks(k: *Self) u32 {
            const m = k.kick_mask;
            k.kick_mask = 0;
            return m;
        }

        // -------------------------------------------------------------------
        // System calls

        fn arg(t: *Thread, comptime r: Reg) u64 {
            return t.ctx.get(r);
        }

        fn setResult(t: *Thread, status: abi.Status, outs: []const u64) void {
            t.ctx.set(.a0, @backingInt(status));
            const regs = [_]Reg{ .a2, .a3, .a4, .a5, .a6 };
            for (outs, 0..) |v, i| t.ctx.set(regs[i], v);
        }

        fn wake(k: *Self, t: *Thread, status: abi.Status) void {
            setResult(t, status, &.{});
            k.makeRunnable(t);
        }

        fn syscall(k: *Self, t: *Thread) void {
            const id = t.id;
            const gen = k.table[id].gen;
            const sys: abi.Syscall = @fromBackingInt(@intCast(arg(t, .a7)));
            const result: Error!void = switch (sys) {
                .call => k.sendOp(t, true),
                .send => k.sendOp(t, false),
                .recv => k.recvOp(t),
                .reply_recv => k.replyRecv(t),
                .signal => k.signalOp(t),
                .wait => k.waitOp(t, true),
                .poll => k.waitOp(t, false),
                .yield => k.yieldOp(t),
                .invoke => k.invoke(t),
                .reply => k.replyOp(t),
                _ => error.UnknownSyscall,
            };
            result catch |e| {
                // The thread may have destroyed itself (e.g. reset its own untyped).
                if (k.table[id].gen == gen and k.table[id].kind == .thread) setResult(t, statusOf(e), &.{});
            };
        }

        fn yieldOp(k: *Self, t: *Thread) Error!void {
            setResult(t, .ok, &.{});
            const h = &k.harts[t.hart];
            if (h.current == t.id) h.current = 0;
            k.enqueueTail(t);
        }

        // --- IPC -------------------------------------------------------------

        fn ipcBuffer(k: *Self, t: *Thread) ?*abi.IpcBuffer {
            const e = k.validateKind(t.ipc_frame, .frame) orelse return null;
            return at(abi.IpcBuffer, e.addr);
        }

        /// Copy a message from `src` to `dst`, including capabilities when the
        /// sender may grant. Sets dst's a0 (ok), a1 (tag) and a7 (badge).
        /// The receiver gets a7 = badge | protocol << 32: who sent it (the
        /// badge) and which protocol the sender's capability speaks, so one
        /// endpoint can serve several protocols and tell them apart.
        fn transfer(k: *Self, src: *Thread, dst: *Thread, badge: u32, protocol: u16, grant: bool) void {
            k.stats.ipc_transfers += 1;
            const msg_regs = [_]Reg{ .a2, .a3, .a4, .a5, .a6 };
            var tag: abi.Tag = undefined;
            if (src.faulted()) {
                const f = src.fault;
                tag = .{ .label = @backingInt(f.kind), .length = 3 };
                const words = [_]u64{ f.addr, f.pc, f.raw };
                for (words, 0..) |w, i| dst.ctx.set(msg_regs[i], w);
            } else {
                tag = @bitCast(@as(usize, @intCast(arg(src, .a1))));
                if (tag.length > abi.max_message_words) tag.length = abi.max_message_words;
                const n = @min(tag.length, abi.register_words);
                for (msg_regs[0..n]) |r| dst.ctx.set(r, src.ctx.get(r));
                if (tag.length > abi.register_words) {
                    if (k.ipcBuffer(src)) |sb| if (k.ipcBuffer(dst)) |db| {
                        @memcpy(db.words[abi.register_words..tag.length], sb.words[abi.register_words..tag.length]);
                    } else {
                        tag.length = abi.register_words;
                    } else tag.length = abi.register_words;
                }
                var moved: u3 = 0;
                if (tag.caps > 0 and grant) {
                    if (k.ipcBuffer(src)) |sb| if (k.ipcBuffer(dst)) |db| {
                        for (0..@min(tag.caps, abi.max_message_caps)) |i| {
                            const from = k.slot(src, sb.send_caps[i]) catch break;
                            if (k.validate(from.*) == null) break;
                            const to = k.slot(dst, db.recv_slots[i]) catch break;
                            if (!to.isNull()) break;
                            to.* = from.*;
                            moved += 1;
                        }
                        db.received_caps = moved;
                    };
                }
                tag.caps = moved;
            }
            dst.ctx.set(.a0, @backingInt(abi.Status.ok));
            dst.ctx.set(.a1, @as(usize, @bitCast(tag)));
            dst.ctx.set(.a7, @as(u64, badge) | @as(u64, protocol) << 32);
        }

        fn link(k: *Self, head: *ObjId, tail: *ObjId, t: *Thread) void {
            t.next = 0;
            t.prev = tail.*;
            if (tail.* != 0) k.thread(tail.*).next = t.id else head.* = t.id;
            tail.* = t.id;
        }

        fn unlink(k: *Self, head: *ObjId, tail: *ObjId, t: *Thread) void {
            if (t.prev != 0) k.thread(t.prev).next = t.next else head.* = t.next;
            if (t.next != 0) k.thread(t.next).prev = t.prev else tail.* = t.prev;
            t.next = 0;
            t.prev = 0;
        }

        fn popFront(k: *Self, head: *ObjId, tail: *ObjId) ?*Thread {
            if (head.* == 0) return null;
            const t = k.thread(head.*);
            k.unlink(head, tail, t);
            t.queue = 0;
            return t;
        }

        fn abortEndpoint(k: *Self, id: ObjId) void {
            const ep = k.body(Endpoint, id);
            k.abortQueue(&ep.head, &ep.tail);
            ep.mode = .idle;
        }

        /// Wake everyone queued on an endpoint or signal with `aborted`.
        fn abortQueue(k: *Self, head: *ObjId, tail: *ObjId) void {
            while (k.popFront(head, tail)) |t| {
                t.clearFault();
                k.wake(t, .aborted);
            }
        }

        /// Stop running `t` on its hart (it blocked).
        fn block(k: *Self, t: *Thread, state: abi.ThreadState) void {
            if (t.state == .running) {
                const h = &k.harts[t.hart];
                if (h.current == t.id) h.current = 0;
            } else if (t.state == .ready) k.dequeue(t);
            t.state = state;
        }

        fn sendOp(k: *Self, t: *Thread, is_call: bool) Error!void {
            const c = try k.resolveKind(t, arg(t, .a0), .endpoint, .{ .send = true });
            k.deliverSend(t, c, is_call);
        }

        fn protocolsDiffer(a: u16, b: u16) bool {
            return a != 0 and b != 0 and a != b;
        }

        fn deliverSend(k: *Self, t: *Thread, c: Cap, is_call: bool) void {
            const ep = k.body(Endpoint, c.object);
            const grant = c.r().grant;
            if (ep.mode == .receiving and protocolsDiffer(c.protocol, k.thread(ep.head).recv_protocol)) {
                // The receiver speaks another protocol: refuse the sender.
                t.clearFault();
                setResult(t, .protocol_mismatch, &.{});
                return;
            }
            if (ep.mode == .receiving) {
                const recv = k.popFront(&ep.head, &ep.tail).?;
                if (ep.head == 0) ep.mode = .idle;
                k.transfer(t, recv, c.badge, c.protocol, grant);
                if (is_call) {
                    k.startReply(t, recv);
                } else {
                    t.clearFault();
                    setResult(t, .ok, &.{});
                }
                if (recv.state != .running) k.makeRunnable(recv);
                return;
            }
            t.send_badge = c.badge;
            t.send_grant = grant;
            t.send_call = is_call;
            t.send_protocol = c.protocol;
            k.block(t, .blocked_send);
            t.queue = c.object;
            ep.mode = .sending;
            k.link(&ep.head, &ep.tail, t);
        }

        /// `caller` now waits for `server`'s reply; lend the caller's
        /// scheduling context if the server has none of its own.
        fn startReply(k: *Self, caller: *Thread, server: *Thread) void {
            if (k.alive(server.reply_to, .thread)) {
                // The server never replied to its previous caller.
                const old = k.thread(server.reply_to);
                if (old.state == .blocked_reply and old.reply_from == server.id) {
                    if (server.sc != 0 and server.sc == old.sc and server.sc != server.home_sc) k.returnSchedContext(server, old);
                    old.reply_from = 0;
                    k.wake(old, .aborted);
                }
            }
            if (caller.state != .blocked_reply) k.block(caller, .blocked_reply);
            caller.reply_from = server.id;
            server.reply_to = caller.id;
            if (!k.alive(server.home_sc, .sched_context) and k.alive(caller.sc, .sched_context)) {
                const sc = k.body(SchedContext, caller.sc);
                server.sc = caller.sc;
                sc.holder = server.id;
            }
        }

        fn returnSchedContext(k: *Self, server: *Thread, caller: *Thread) void {
            const id = server.sc;
            if (!k.alive(id, .sched_context)) return;
            server.sc = 0;
            k.body(SchedContext, id).holder = caller.id;
            caller.sc = id;
            if (server.state == .running or server.state == .ready) {
                k.detach(server);
                server.state = .stalled;
            }
        }

        fn recvOp(k: *Self, t: *Thread) Error!void {
            const c = try k.resolveKind(t, arg(t, .a0), .endpoint, .{ .recv = true });
            k.deliverRecv(t, c);
        }

        fn deliverRecv(k: *Self, t: *Thread, c: Cap) void {
            // A pending bound signal comes first: interrupts do not wait
            // behind a queue of clients.
            if (k.alive(t.bound_signal, .signal) and k.body(Signal, t.bound_signal).word != 0) {
                k.deliverBound(t, k.body(Signal, t.bound_signal));
                return;
            }
            const ep = k.body(Endpoint, c.object);
            // Queued senders speaking another protocol are refused.
            while (ep.mode == .sending and protocolsDiffer(k.thread(ep.head).send_protocol, c.protocol)) {
                const wrong = k.popFront(&ep.head, &ep.tail).?;
                if (ep.head == 0) ep.mode = .idle;
                wrong.clearFault();
                k.wake(wrong, .protocol_mismatch);
            }
            if (ep.mode == .sending) {
                const sender = k.popFront(&ep.head, &ep.tail).?;
                if (ep.head == 0) ep.mode = .idle;
                k.transfer(sender, t, sender.send_badge, sender.send_protocol, sender.send_grant);
                if (sender.send_call) {
                    sender.state = .inactive; // re-blocked by startReply
                    k.startReply(sender, t);
                } else {
                    sender.clearFault();
                    k.wake(sender, .ok);
                }
                return;
            }
            k.block(t, .blocked_recv);
            t.queue = c.object;
            t.recv_protocol = c.protocol;
            ep.mode = .receiving;
            k.link(&ep.head, &ep.tail, t);
        }

        fn replyRecv(k: *Self, t: *Thread) Error!void {
            const c = try k.resolveKind(t, arg(t, .a0), .endpoint, .{ .recv = true });
            k.replyToCaller(t);
            k.deliverRecv(t, c);
        }

        fn replyOp(k: *Self, t: *Thread) Error!void {
            k.replyToCaller(t);
            setResult(t, .ok, &.{});
        }

        /// Send `t`'s message to the caller waiting on it, if any, and give
        /// back a lent scheduling context. A faulted caller is resumed instead:
        /// label 1 sets its pc to word 0, anything else retries the instruction.
        fn replyToCaller(k: *Self, t: *Thread) void {
            if (!k.alive(t.reply_to, .thread)) {
                t.reply_to = 0;
                return;
            }
            const caller = k.thread(t.reply_to);
            t.reply_to = 0;
            if (caller.state != .blocked_reply or caller.reply_from != t.id) return;
            caller.reply_from = 0;
            if (caller.faulted()) {
                const tag: abi.Tag = @bitCast(@as(usize, @intCast(arg(t, .a1))));
                if (tag.label == 1) caller.ctx.set(.pc, arg(t, .a2));
                caller.clearFault();
            } else {
                k.transfer(t, caller, 0, 0, false);
            }
            if (t.sc != 0 and t.sc == caller.sc and t.sc != t.home_sc) {
                // Give the lent context back.
                t.sc = 0;
                k.body(SchedContext, caller.sc).holder = caller.id;
                if (t.state == .running) {
                    // t keeps running only until it blocks or is rescheduled;
                    // without a context it stalls at the next reschedule.
                }
            }
            k.makeRunnable(caller);
        }

        // --- Signals ---------------------------------------------------------

        fn signalOp(k: *Self, t: *Thread) Error!void {
            const c = try k.resolveKind(t, arg(t, .a0), .signal, .{ .send = true });
            k.signalDeliver(c.object, if (c.badge == 0) 1 else c.badge);
            setResult(t, .ok, &.{});
        }

        fn signalDeliver(k: *Self, id: ObjId, bits: u64) void {
            const s = k.body(Signal, id);
            s.word |= bits;
            if (k.popFront(&s.head, &s.tail)) |w| {
                setResult(w, .ok, &.{s.word});
                s.word = 0;
                k.makeRunnable(w);
            } else if (k.alive(s.bound, .thread) and k.thread(s.bound).state == .blocked_recv) {
                // The bound thread is waiting to receive: end that wait.
                const t = k.thread(s.bound);
                const ep = k.body(Endpoint, t.queue);
                k.unlink(&ep.head, &ep.tail, t);
                if (ep.head == 0) ep.mode = .idle;
                k.deliverBound(t, s);
                k.makeRunnable(t);
            }
        }

        /// End `t`'s receive with its bound signal's bits instead of a message.
        fn deliverBound(k: *Self, t: *Thread, s: *Signal) void {
            _ = k;
            setResult(t, .ok, &.{s.word});
            t.ctx.set(.a1, 0);
            t.ctx.set(.a7, abi.recv_signalled);
            s.word = 0;
        }

        /// Undo the binding between signal `id` and its thread.
        fn unbindSignal(k: *Self, id: ObjId) void {
            const s = k.body(Signal, id);
            if (k.alive(s.bound, .thread) and k.thread(s.bound).bound_signal == id) k.thread(s.bound).bound_signal = 0;
            s.bound = 0;
        }

        fn waitOp(k: *Self, t: *Thread, blocking: bool) Error!void {
            const c = try k.resolveKind(t, arg(t, .a0), .signal, .{ .recv = true });
            const s = k.body(Signal, c.object);
            if (s.word != 0 or !blocking) {
                setResult(t, .ok, &.{s.word});
                s.word = 0;
                return;
            }
            k.block(t, .blocked_signal);
            t.queue = c.object;
            k.link(&s.head, &s.tail, t);
        }

        // --- Faults and interrupts --------------------------------------------

        fn handleFault(k: *Self, t: *Thread, f: Fault) void {
            const handler: ?Resolved = k.resolveCap(t.fault_ep) catch null;
            if (handler) |r| if (r.kind == .endpoint and r.cap.r().send) {
                t.fault = f;
                k.deliverSend(t, r.cap, true);
                return;
            };
            k.log("thread_fault", .{ .thread = t.id, .kind = @tagName(f.kind), .addr = klog.hex(f.addr), .pc = klog.hex(f.pc), .handler = "none" });
            k.detach(t);
            t.fault = f;
        }

        fn handleIrq(k: *Self, line: u32) void {
            if (line >= k.irq_count) return;
            const st = &k.irqs[line];
            A.irqMask(line);
            st.masked = true;
            if (st.obj != 0 and k.table[st.obj].gen == st.gen and k.table[st.obj].kind == .irq) {
                const res: ?Resolved = k.resolveCap(st.signal) catch null;
                if (res) |r| if (r.kind == .signal) {
                    k.signalDeliver(r.cap.object, if (r.cap.badge == 0) 1 else r.cap.badge);
                    return;
                };
            }
            k.log("irq_unhandled", .{ .line = line });
        }

        // -------------------------------------------------------------------
        // Object methods (Syscall.invoke)

        fn invoke(k: *Self, t: *Thread) Error!void {
            const res = try k.resolve(t, arg(t, .a0));
            const method: u32 = @truncate(arg(t, .a1));
            const c = res.cap;
            switch (res.kind) {
                .untyped => try k.invokeUntyped(t, c, method),
                .cnode => try k.invokeCNode(t, c, method),
                .thread => try k.invokeThread(t, c, method),
                .page_table => try k.invokeVSpace(t, c, method),
                .sched_control => try k.invokeSchedControl(t, c, method),
                .sched_context => try k.invokeSchedContext(t, c, method),
                .irq_control => try k.invokeIrqControl(t, c, method),
                .irq => try k.invokeIrq(t, c, method),
                .lease => try k.invokeLease(t, c, method),
                .debug_console => try k.invokeDebug(t, c, method),
                .frame => try k.invokeFrame(t, c, method),
                .signal => try k.invokeSignal(t, c, method),
                else => return error.UnknownMethod,
            }
        }

        fn need(c: Cap, r: abi.Rights) Error!void {
            if (!c.r().contains(r)) return error.NoRights;
        }

        fn invokeUntyped(k: *Self, t: *Thread, c: Cap, method: u32) Error!void {
            const m = std.enums.fromInt(abi.UntypedMethod, method) orelse return error.UnknownMethod;
            switch (m) {
                .retype => {
                    try need(c, .{ .retype = true });
                    const kind = std.enums.fromInt(abi.Kind, @as(u8, @truncate(arg(t, .a2)))) orelse return error.InvalidArgument;
                    const bits = std.math.cast(u8, arg(t, .a3)) orelse return error.InvalidArgument;
                    const dest = try k.slot(t, arg(t, .a4));
                    if (!dest.isNull()) return error.SlotOccupied;
                    const id = try k.retype(c.object, kind, bits);
                    dest.* = k.capTo(id, abi.Rights.all);
                    setResult(t, .ok, &.{id});
                },
                .reset => {
                    try need(c, .{ .retype = true });
                    const id = t.id;
                    const gen = k.table[id].gen;
                    k.resetUntyped(c.object);
                    if (k.table[id].gen == gen) setResult(t, .ok, &.{});
                },
                .info => {
                    const u = k.body(Untyped, c.object);
                    setResult(t, .ok, &.{ u.base, u.size, u.high - u.low, u.objects_left, @intFromBool(u.is_device) });
                },
            }
        }

        fn invokeCNode(k: *Self, t: *Thread, c: Cap, method: u32) Error!void {
            const m = std.enums.fromInt(abi.CNodeMethod, method) orelse return error.UnknownMethod;
            switch (m) {
                .mint => {
                    try need(c, .{ .configure = true });
                    const dest = try k.slotIn(c, arg(t, .a2));
                    const src = (try k.slot(t, arg(t, .a3))).*;
                    if (k.validate(src) == null) return error.InvalidCap;
                    if (!dest.isNull()) return error.SlotOccupied;
                    var n = src;
                    n.rights = src.r().intersect(abi.Rights.fromBits(@truncate(arg(t, .a4)))).bits();
                    const badge: u32 = @truncate(arg(t, .a5));
                    if (badge != 0) {
                        if (src.badge != 0) return error.InvalidArgument;
                        n.badge = badge;
                    }
                    const protocol: u16 = @truncate(arg(t, .a6));
                    if (protocol != 0) {
                        if (src.protocol != 0 and src.protocol != protocol) return error.InvalidArgument;
                        n.protocol = protocol;
                    }
                    dest.* = n;
                    setResult(t, .ok, &.{});
                },
                .delete => {
                    try need(c, .{ .configure = true });
                    const s = try k.slotIn(c, arg(t, .a2));
                    s.* = .{};
                    setResult(t, .ok, &.{});
                },
                .move => {
                    try need(c, .{ .configure = true });
                    const dest = try k.slotIn(c, arg(t, .a2));
                    const src = try k.slotIn(c, arg(t, .a3));
                    if (!dest.isNull()) return error.SlotOccupied;
                    if (src.isNull()) return error.SlotEmpty;
                    dest.* = src.*;
                    src.* = .{};
                    setResult(t, .ok, &.{});
                },
                .revoke => {
                    try need(c, .{ .configure = true });
                    const s = try k.slotIn(c, arg(t, .a2));
                    if (k.validate(s.*) == null) return error.InvalidCap;
                    if (!s.r().revoke) return error.NoRights;
                    // Out of generations (2^32 revokes): refused, rather than
                    // let a stale capability's generation come round again.
                    if (!k.revokable(s.object)) return error.InvalidState;
                    const kind = k.table[s.object].kind;
                    if (kind == .untyped or kind == .irq_control or kind == .sched_control or kind == .debug_console) return error.WrongKind;
                    k.revokeObject(s.object);
                    s.gen = k.table[s.object].gen;
                    setResult(t, .ok, &.{});
                },
                .identify => {
                    try need(c, .{ .read = true });
                    const s = try k.slotIn(c, arg(t, .a2));
                    const e = k.validate(s.*) orelse return error.InvalidCap;
                    var behind = e.kind;
                    if (e.kind == .lease) {
                        const l = k.body(Lease, s.object);
                        if (l.armed) if (k.validate(l.target)) |te| {
                            behind = te.kind;
                        };
                    }
                    setResult(t, .ok, &.{ @backingInt(e.kind), s.rights, s.badge, @backingInt(behind), s.object });
                },
                .lease_info => {
                    try need(c, .{ .read = true });
                    const s = try k.slotIn(c, arg(t, .a2));
                    _ = k.validateKind(s.*, .lease) orelse return error.WrongKind;
                    const l = k.body(Lease, s.object);
                    setResult(t, .ok, &.{ if (l.limited) l.uses else std.math.maxInt(u64), l.expires, @intFromBool(l.armed) });
                },
            }
        }

        fn invokeThread(k: *Self, t: *Thread, c: Cap, method: u32) Error!void {
            const m = std.enums.fromInt(abi.ThreadMethod, method) orelse return error.UnknownMethod;
            const target = k.thread(c.object);
            if (m != .info) try need(c, .{ .configure = true });
            switch (m) {
                .configure => {
                    const cs = (try k.slot(t, arg(t, .a2))).*;
                    _ = k.validateKind(cs, .cnode) orelse return error.WrongKind;
                    const vs = (try k.slot(t, arg(t, .a3))).*;
                    const ve = k.validateKind(vs, .page_table) orelse return error.WrongKind;
                    if (ve.size_bits != levels - 1) return error.InvalidArgument;
                    var fe: Cap = .{};
                    if (arg(t, .a4) != 0) {
                        const r = try k.resolve(t, arg(t, .a4));
                        if (r.kind != .endpoint) return error.WrongKind;
                        fe = (try k.slot(t, arg(t, .a4))).*;
                    }
                    target.cspace = cs;
                    target.vspace = vs;
                    target.fault_ep = fe;
                    setResult(t, .ok, &.{});
                },
                .write_registers => {
                    if (target.state == .running and target.id != t.id) return error.InvalidState;
                    target.ctx.set(.pc, arg(t, .a2));
                    target.ctx.set(.sp, arg(t, .a3));
                    target.ctx.set(.a0, arg(t, .a4));
                    target.ctx.set(.a1, arg(t, .a5));
                    if (target.id != t.id) setResult(t, .ok, &.{});
                },
                .resume_thread => {
                    if (target.state == .inactive) {
                        target.clearFault();
                        k.makeRunnable(target);
                    }
                    setResult(t, .ok, &.{});
                },
                .suspend_thread => {
                    setResult(t, .ok, &.{});
                    if (target.state == .blocked_reply or target.state == .blocked_send or
                        target.state == .blocked_recv or target.state == .blocked_signal)
                        setResult(target, .aborted, &.{});
                    k.detach(target);
                },
                .set_priority => {
                    const p = std.math.cast(u8, arg(t, .a2)) orelse return error.InvalidArgument;
                    if (p > t.mcp) return error.NoRights;
                    if (target.state == .ready) {
                        k.dequeue(target);
                        target.prio = p;
                        k.enqueue(target, false);
                    } else target.prio = p;
                    setResult(t, .ok, &.{});
                },
                .bind_sched => {
                    const cp = arg(t, .a2);
                    if (cp == 0) {
                        const old = target.home_sc;
                        if (k.alive(old, .sched_context)) {
                            const sc = k.body(SchedContext, old);
                            sc.owner = 0;
                            // If it is lent out, take it back first.
                            if (target.sc == old) k.reclaimLent(target);
                            if (target.sc == old) {
                                target.sc = 0;
                                sc.holder = 0;
                                if (target.state == .ready or target.state == .running) {
                                    k.detach(target);
                                    target.state = .stalled;
                                }
                            }
                        }
                        target.home_sc = 0;
                        setResult(t, .ok, &.{});
                        return;
                    }
                    const sc_cap = try k.resolveKind(t, cp, .sched_context, .{});
                    const sc = k.body(SchedContext, sc_cap.object);
                    if (sc.owner != 0 and k.alive(sc.owner, .thread)) return error.InvalidState;
                    if (target.home_sc != 0 and k.alive(target.home_sc, .sched_context)) return error.InvalidState;
                    sc.owner = target.id;
                    target.home_sc = sc_cap.object;
                    if (target.sc == 0) {
                        target.sc = sc_cap.object;
                        sc.holder = target.id;
                        if (target.state == .stalled) k.makeRunnable(target);
                    }
                    setResult(t, .ok, &.{});
                },
                .bind_signal => {
                    const cp = arg(t, .a2);
                    if (cp == 0) {
                        if (k.alive(target.bound_signal, .signal)) k.unbindSignal(target.bound_signal);
                        setResult(t, .ok, &.{});
                        return;
                    }
                    const sc = try k.resolveKind(t, cp, .signal, .{ .recv = true });
                    const s = k.body(Signal, sc.object);
                    if (k.alive(s.bound, .thread) and s.bound != target.id) return error.InvalidState;
                    if (k.alive(target.bound_signal, .signal)) k.unbindSignal(target.bound_signal);
                    s.bound = target.id;
                    target.bound_signal = sc.object;
                    setResult(t, .ok, &.{});
                },
                .set_mcp => {
                    const p = std.math.cast(u8, arg(t, .a2)) orelse return error.InvalidArgument;
                    if (p > t.mcp) return error.NoRights;
                    target.mcp = p;
                    setResult(t, .ok, &.{});
                },
                .set_ipc_buffer => {
                    const f = (try k.slot(t, arg(t, .a2))).*;
                    const fe = k.validateKind(f, .frame) orelse return error.WrongKind;
                    if (fe.size_bits != 12 or (fe.flags & flag_device) != 0) return error.InvalidArgument;
                    if (arg(t, .a3) % page_size != 0) return error.InvalidArgument;
                    target.ipc_frame = f;
                    target.ipc_vaddr = arg(t, .a3);
                    setResult(t, .ok, &.{});
                },
                .info => {
                    setResult(t, .ok, &.{ @backingInt(target.state), target.prio, target.ctx.get(.pc), k.hartOf(target) });
                },
            }
        }

        fn invokeVSpace(k: *Self, t: *Thread, c: Cap, method: u32) Error!void {
            const m = std.enums.fromInt(abi.VSpaceMethod, method) orelse return error.UnknownMethod;
            if (k.table[c.object].size_bits != levels - 1) return error.WrongKind;
            try need(c, .{ .configure = true });
            const va = arg(t, .a3);
            switch (m) {
                .map_frame => {
                    const fc = try k.resolveKind(t, arg(t, .a2), .frame, .{});
                    const want = abi.Rights.fromBits(@truncate(arg(t, .a4)));
                    const rights = want.intersect(fc.r()).intersect(.{ .read = true, .write = true, .execute = true });
                    if (!rights.read and !rights.execute) return error.NoRights;
                    if (rights.write and !rights.read) return error.InvalidArgument;
                    const fe = k.table[fc.object];
                    const level: u8 = switch (fe.size_bits) {
                        12 => 0,
                        21 => 1,
                        30 => 2,
                        else => return error.InvalidArgument,
                    };
                    if (level >= levels - 1 or va >= P.user_top or va % (@as(u64, 1) << @intCast(fe.size_bits)) != 0) return error.InvalidArgument;
                    const tbl = try k.walkTo(c.object, va, level);
                    try k.installFrame(tbl, P.index(va, level), fc.object, rights);
                    setResult(t, .ok, &.{});
                },
                .map_table => {
                    const pc = try k.resolveKind(t, arg(t, .a2), .page_table, .{});
                    const pe = &k.table[pc.object];
                    const level = pe.size_bits;
                    if (level >= levels - 1 or va >= P.user_top) return error.InvalidArgument;
                    if (pe.link != 0) return error.AlreadyMapped;
                    const parent = try k.walkTo(c.object, va, level + 1);
                    const idx = P.index(va, level + 1);
                    if (k.body(Table, parent).shadow[idx] != 0) return error.AlreadyMapped;
                    k.linkTable(parent, idx, pc.object);
                    setResult(t, .ok, &.{});
                },
                .unmap => {
                    const v = arg(t, .a2);
                    if (v >= P.user_top) return error.InvalidArgument;
                    var tbl = c.object;
                    var lvl: u8 = levels - 1;
                    while (true) : (lvl -= 1) {
                        const idx = P.index(v, lvl);
                        const child = k.body(Table, tbl).shadow[idx];
                        if (child == 0) return error.NotMapped;
                        if (k.table[child].kind == .frame) {
                            k.unmapFrame(child);
                            break;
                        }
                        if (lvl == 0) return error.NotMapped;
                        tbl = child;
                    }
                    setResult(t, .ok, &.{});
                },
            }
        }

        fn invokeSchedContext(k: *Self, t: *Thread, c: Cap, method: u32) Error!void {
            const m = std.enums.fromInt(abi.SchedContextMethod, method) orelse return error.UnknownMethod;
            try need(c, .{ .read = true });
            const sc = k.body(SchedContext, c.object);
            switch (m) {
                .info => setResult(t, .ok, &.{ sc.budget, sc.period, sc.consumed, sc.hart, @intFromBool(sc.throttled) }),
            }
        }

        fn invokeSchedControl(k: *Self, t: *Thread, c: Cap, method: u32) Error!void {
            _ = std.enums.fromInt(abi.SchedControlMethod, method) orelse return error.UnknownMethod;
            try need(c, .{ .configure = true });
            const scc = try k.resolveKind(t, arg(t, .a2), .sched_context, .{});
            const budget = arg(t, .a3);
            const period = arg(t, .a4);
            const hart = std.math.cast(u8, arg(t, .a5)) orelse return error.InvalidArgument;
            if (budget == 0 or period == 0 or budget > period or period > max_period or hart >= k.hart_count) return error.InvalidArgument;
            const sc = k.body(SchedContext, scc.object);
            k.removeRelease(scc.object);
            // A thread on this context moves with it.
            var holder: ?*Thread = null;
            if (k.alive(sc.holder, .thread) and k.thread(sc.holder).sc == scc.object) {
                const h = k.thread(sc.holder);
                if (h.state == .ready or h.state == .running) {
                    k.detach(h);
                    h.state = .stalled;
                }
                holder = h;
            }
            sc.budget = budget;
            sc.period = period;
            sc.remaining = budget;
            sc.refill_at = k.now +| period;
            sc.hart = hart;
            sc.configured = true;
            sc.throttled = false;
            setResult(t, .ok, &.{});
            if (holder) |h| if (h.state == .stalled) k.makeRunnable(h);
        }

        fn invokeIrqControl(k: *Self, t: *Thread, c: Cap, method: u32) Error!void {
            _ = std.enums.fromInt(abi.IrqControlMethod, method) orelse return error.UnknownMethod;
            try need(c, .{ .configure = true });
            const line = arg(t, .a2);
            if (line < k.irq_first or line >= k.irq_count) return error.InvalidArgument;
            const dest = try k.slot(t, arg(t, .a3));
            if (!dest.isNull()) return error.SlotOccupied;
            const st = &k.irqs[@intCast(line)];
            if (st.obj != 0 and k.table[st.obj].gen == st.gen and k.table[st.obj].kind == .irq) return error.InvalidState;
            const id = k.allocEntry() orelse return error.NoObjects;
            const e = &k.table[id];
            e.kind = .irq;
            e.addr = line;
            e.parent = 0;
            e.first_child = 0;
            e.next_sibling = 0;
            st.* = .{ .obj = id, .gen = e.gen };
            dest.* = k.capTo(id, abi.Rights.all);
            setResult(t, .ok, &.{});
        }

        fn invokeSignal(k: *Self, t: *Thread, c: Cap, method: u32) Error!void {
            const m = std.enums.fromInt(abi.SignalMethod, method) orelse return error.UnknownMethod;
            try need(c, .{ .send = true });
            switch (m) {
                .alarm => {
                    const ticks = arg(t, .a2);
                    k.removeAlarm(c.object);
                    if (ticks != 0) k.insertAlarm(c.object, k.handling_hart, k.now +| ticks, if (c.badge == 0) 1 else c.badge);
                    setResult(t, .ok, &.{});
                },
            }
        }

        fn invokeIrq(k: *Self, t: *Thread, c: Cap, method: u32) Error!void {
            const m = std.enums.fromInt(abi.IrqMethod, method) orelse return error.UnknownMethod;
            try need(c, .{ .configure = true });
            const line: u32 = @intCast(k.table[c.object].addr);
            const st = &k.irqs[line];
            switch (m) {
                .set_signal => {
                    _ = try k.resolveKind(t, arg(t, .a2), .signal, .{ .send = true });
                    st.signal = (try k.slot(t, arg(t, .a2))).*;
                    st.masked = false;
                    A.irqUnmask(line);
                },
                .ack => {
                    st.masked = false;
                    A.irqUnmask(line);
                },
            }
            setResult(t, .ok, &.{});
        }

        fn invokeLease(k: *Self, t: *Thread, c: Cap, method: u32) Error!void {
            _ = std.enums.fromInt(abi.LeaseMethod, method) orelse return error.UnknownMethod;
            try need(c, .{ .configure = true });
            const l = k.body(Lease, c.object);
            const target = (try k.slot(t, arg(t, .a2))).*;
            if (k.validate(target) == null) return error.InvalidCap;
            if (target.object == c.object) return error.InvalidArgument;
            const duration = arg(t, .a4);
            const uses = arg(t, .a5);
            l.* = .{
                .target = target,
                .rights = target.r().intersect(abi.Rights.fromBits(@truncate(arg(t, .a3)))).bits(),
                .armed = true,
                .limited = uses != 0,
                .uses = std.math.cast(u32, uses) orelse std.math.maxInt(u32),
                .expires = if (duration == 0) 0 else k.now +| duration,
            };
            setResult(t, .ok, &.{});
        }

        fn invokeFrame(k: *Self, t: *Thread, c: Cap, method: u32) Error!void {
            _ = std.enums.fromInt(abi.FrameMethod, method) orelse return error.UnknownMethod;
            try need(c, .{ .read = true });
            const e = k.table[c.object];
            setResult(t, .ok, &.{ e.addr, @as(u64, 1) << @intCast(e.size_bits), @intFromBool(e.flags & flag_device != 0), @intFromBool(e.link != 0) });
        }

        fn invokeDebug(k: *Self, t: *Thread, c: Cap, method: u32) Error!void {
            const m = std.enums.fromInt(abi.DebugMethod, method) orelse return error.UnknownMethod;
            switch (m) {
                .write => {
                    try need(c, .{ .write = true });
                    // a1 carries the method, so the byte count rides in a2 and
                    // up to 32 bytes follow in a3..a6; longer writes come from
                    // the IPC buffer. One call, one uninterrupted write.
                    const n = arg(t, .a2);
                    if (n > abi.max_debug_write) return error.InvalidArgument;
                    if (n > 32) {
                        const ib = k.ipcBuffer(t) orelse return error.InvalidArgument;
                        const bytes: *const [abi.max_debug_write]u8 = @ptrCast(&ib.words);
                        A.debugWrite(bytes[0..@intCast(n)]);
                    } else {
                        var buf: [32]u8 = undefined;
                        const regs = [_]Reg{ .a3, .a4, .a5, .a6 };
                        for (regs, 0..) |r, i| std.mem.writeInt(u64, buf[i * 8 ..][0..8], t.ctx.get(r), .little);
                        A.debugWrite(buf[0..@intCast(n)]);
                    }
                    setResult(t, .ok, &.{});
                },
                .exit => {
                    try need(c, .{ .configure = true });
                    k.log("halt", .{ .reason = "root_exit", .code = arg(t, .a2), .syscalls = k.stats.syscalls, .ipc = k.stats.ipc_transfers, .switches = k.stats.context_switches });
                    k.exit_code = @truncate(arg(t, .a2));
                    setResult(t, .ok, &.{});
                    k.detach(t);
                },
                .time => setResult(t, .ok, &.{ k.now, k.timebase_hz }),
            }
        }

        /// True when no hart has anything to run and no timer is armed: the
        /// system can only move again if an interrupt arrives.
        pub fn stuck(k: *Self) bool {
            for (k.harts[0..k.hart_count]) |h| {
                if (h.online and (h.current != 0 or h.timer_deadline != std.math.maxInt(u64))) return false;
            }
            return true;
        }

        /// One record per live thread, for diagnosing a stuck system.
        pub fn logThreads(k: *Self) void {
            for (k.table, 0..) |e, i| {
                if (e.kind != .thread) continue;
                const t = k.thread(@intCast(i));
                k.log("thread", .{
                    .id = t.id,
                    .state = @tagName(t.state),
                    .prio = t.prio,
                    .hart = t.hart,
                    .sc = t.sc,
                    .home_sc = t.home_sc,
                    .queue = t.queue,
                    .reply_to = t.reply_to,
                    .reply_from = t.reply_from,
                    .pc = klog.hex(t.ctx.get(.pc)),
                });
                if (k.alive(t.sc, .sched_context)) {
                    const sc = k.body(SchedContext, t.sc);
                    k.log("sched_context", .{ .id = t.sc, .remaining = sc.remaining, .budget = sc.budget, .throttled = sc.throttled, .holder = sc.holder, .refill_at = sc.refill_at, .now = k.now });
                }
            }
        }

        // -------------------------------------------------------------------
        // Invariants (checked by the simulator after every step, and by
        // debug builds on demand). Returns a description of the first
        // violation found.

        pub fn checkInvariants(k: *Self) ?[]const u8 {
            var free: u32 = 0;
            var cur = k.free_head;
            while (cur != 0) : (cur = k.table[cur].link) {
                if (k.table[cur].kind != .free) return "free list holds a live entry";
                if (k.table[cur].gen == max_gen) return "free list holds a retired entry";
                free += 1;
                if (free > k.table.len) return "free list cycles";
            }
            if (free != k.free_count) return "free count mismatch";
            for (k.table) |e| {
                if (e.kind == .irq and (e.addr < k.irq_first or e.addr >= k.irq_count)) return "an Irq object holds one of the kernel's own lines";
            }

            for (k.harts[0..k.hart_count]) |h| if (h.direct != 0) return "a held-aside thread outlived its kernel entry";
            var running: [max_harts]u32 = @splat(0);
            for (k.table, 0..) |e, i| {
                const id: ObjId = @intCast(i);
                switch (e.kind) {
                    .thread => {
                        const t = k.thread(id);
                        if (t.id != id) return "thread id mismatch";
                        switch (t.state) {
                            .running => {
                                if (k.harts[t.hart].current != id) return "running thread is not current";
                                running[t.hart] += 1;
                            },
                            .ready => if (!k.inRunQueue(t)) return "ready thread not in its run queue",
                            .blocked_send, .blocked_recv => {
                                if (!k.alive(t.queue, .endpoint)) return "blocked thread on dead endpoint";
                                const ep = k.body(Endpoint, t.queue);
                                const want: @TypeOf(ep.mode) = if (t.state == .blocked_send) .sending else .receiving;
                                if (ep.mode != want) return "endpoint mode disagrees with queued thread";
                            },
                            .blocked_signal => if (!k.alive(t.queue, .signal)) return "blocked thread on dead signal",
                            .blocked_reply => {
                                if (!k.alive(t.reply_from, .thread)) return "reply wait on dead thread";
                                if (k.thread(t.reply_from).reply_to != id) return "reply link not symmetric";
                            },
                            .inactive, .stalled => {},
                        }
                        if (t.bound_signal != 0) {
                            if (!k.alive(t.bound_signal, .signal) or k.body(Signal, t.bound_signal).bound != id) return "signal binding not symmetric";
                            if (t.state == .blocked_recv and k.body(Signal, t.bound_signal).word != 0) return "receiver waits while its bound signal is pending";
                        }
                        // A caller lends its context while it waits for a reply,
                        // so only threads that can run must hold their own.
                        if ((t.state == .running or t.state == .ready) and k.alive(t.sc, .sched_context)) {
                            if (k.body(SchedContext, t.sc).holder != id) return "runnable thread's context held by another";
                        }
                    },
                    .signal => {
                        const sg = k.body(Signal, id);
                        if (sg.bound != 0 and (!k.alive(sg.bound, .thread) or k.thread(sg.bound).bound_signal != id)) return "signal binding not symmetric";
                        if (sg.alarm_at != 0 and !k.onAlarmList(id)) return "armed alarm not on its hart's list";
                        if (sg.alarm_at != 0 and sg.alarm_at <= k.now and k.harts[sg.alarm_hart].online and k.handling_hart == sg.alarm_hart) return "alarm overdue on its own hart";
                    },
                    .sched_context => {
                        const sc = k.body(SchedContext, id);
                        if (sc.remaining > sc.budget) return "budget overrun";
                        if (sc.consumed > k.now) return "context charged more time than has passed";
                        // An exhausted context must be waiting for a refill.
                        if (sc.configured and sc.remaining == 0 and !sc.throttled) return "exhausted context not throttled";
                        if (sc.throttled and !k.onReleaseList(id)) return "throttled context not on its release list";
                    },
                    .untyped => {
                        const u = k.body(Untyped, id);
                        if (u.low > u.high or u.low < u.base or u.high > u.base + u.size) return "untyped watermarks out of range";
                    },
                    .frame => if (e.link != 0) {
                        if (!k.alive(e.link, .page_table)) return "frame mapped in dead table";
                        if (k.body(Table, e.link).shadow[e.flags & slot_mask] != id) return "frame mapping record disagrees with table";
                    },
                    .page_table => {
                        const pt = k.body(Table, id);
                        for (pt.shadow, 0..) |s, si| if (s != 0) {
                            const ce = k.table[s];
                            if (ce.kind != .frame and ce.kind != .page_table) return "table shadow names a non-mapping";
                            if (ce.link != id or (ce.flags & slot_mask) != si) return "table shadow disagrees with child";
                        };
                    },
                    .endpoint => {
                        const ep = k.body(Endpoint, id);
                        if ((ep.head == 0) != (ep.mode == .idle)) return "endpoint mode disagrees with queue";
                        var n = ep.head;
                        var count: usize = 0;
                        while (n != 0) : (n = k.thread(n).next) {
                            if (k.thread(n).queue != id) return "endpoint queue member points elsewhere";
                            count += 1;
                            if (count > k.table.len) return "endpoint queue cycles";
                        }
                    },
                    else => {},
                }
            }
            for (k.harts[0..k.hart_count], 0..) |h, hi| {
                if (h.current != 0 and running[hi] != 1) return "hart current is not a running thread";
                for (0..256) |p| {
                    const set = h.bitmap[p / 64] & (@as(u64, 1) << @intCast(p % 64)) != 0;
                    if (set != (h.run_head[p] != 0)) return "run bitmap disagrees with queues";
                }
            }
            return null;
        }

        fn onAlarmList(k: *Self, id: ObjId) bool {
            const s = k.body(Signal, id);
            if (s.alarm_hart >= k.harts.len) return false;
            var n = k.harts[s.alarm_hart].alarm_head;
            var count: usize = 0;
            var last: u64 = 0;
            while (n != 0) : (n = k.body(Signal, n).next_alarm) {
                if (!k.alive(n, .signal)) return false;
                const when = k.body(Signal, n).alarm_at;
                if (when == 0 or when < last) return false;
                last = when;
                if (n == id) return true;
                count += 1;
                if (count > k.table.len) return false;
            }
            return false;
        }

        fn onReleaseList(k: *Self, id: ObjId) bool {
            const sc = k.body(SchedContext, id);
            var n = k.harts[sc.hart].release_head;
            var count: usize = 0;
            while (n != 0) : (n = k.body(SchedContext, n).next_release) {
                if (n == id) return true;
                count += 1;
                if (count > k.table.len) return false;
            }
            return false;
        }

        fn inRunQueue(k: *Self, t: *Thread) bool {
            var n = k.harts[t.hart].run_head[t.prio];
            var count: usize = 0;
            while (n != 0) : (n = k.thread(n).next) {
                if (n == t.id) return true;
                count += 1;
                if (count > k.table.len) return false;
            }
            return false;
        }
    };
}
