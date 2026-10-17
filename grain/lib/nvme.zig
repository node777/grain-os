//! NVMe: 4 KiB blocks on namespace 1, one command at a time.
//!
//! The controller's registers are BAR 0. Queues are single pages: an admin
//! queue pair, used to identify the controller and namespace and to make one
//! I/O queue pair, and that pair for reads, writes and flushes. Each command
//! moves one block through one data page (a single PRP entry). Completions
//! are noticed by their phase bit flipping, waiting on the interrupt (as a
//! signal) between looks, or spinning when there is no signal. The same
//! interface as virtio-blk, so Tablecloth runs on either.
const std = @import("std");
const grain = @import("grain.zig");

pub const block_size = 4096;
/// Entries per queue: a page of 64-byte submissions holds 64.
const depth = 64;

pub const Page = struct { va: usize, pa: u64 };

pub const Error = error{ Timeout, DeviceError, OutOfRange, Unsupported };

const Reg = struct {
    const cap = 0x00;
    const cc = 0x14;
    const csts = 0x1c;
    const aqa = 0x24;
    const asq = 0x28;
    const acq = 0x30;
};

const Op = struct {
    // admin
    const create_sq: u8 = 0x01;
    const create_cq: u8 = 0x05;
    const identify: u8 = 0x06;
    // I/O
    const flush: u8 = 0x00;
    const write: u8 = 0x01;
    const read: u8 = 0x02;
};

const Command = extern struct {
    opcode: u8,
    flags: u8 = 0,
    cid: u16,
    nsid: u32 = 0,
    _rsvd: u64 = 0,
    mptr: u64 = 0,
    prp1: u64 = 0,
    prp2: u64 = 0,
    cdw10: u32 = 0,
    cdw11: u32 = 0,
    cdw12: u32 = 0,
    cdw13: u32 = 0,
    cdw14: u32 = 0,
    cdw15: u32 = 0,
};

const Completion = extern struct {
    dw0: u32,
    dw1: u32,
    sq_head: u16,
    sq_id: u16,
    cid: u16,
    status: u16,
};

comptime {
    std.debug.assert(@sizeOf(Command) == 64);
    std.debug.assert(@sizeOf(Completion) == 16);
}

const Queue = struct {
    id: u16,
    sq: Page,
    cq: Page,
    tail: u16 = 0,
    head: u16 = 0,
    phase: u1 = 1,
};

pub const Nvme = struct {
    regs: usize,
    stride: usize,
    admin: Queue,
    io: Queue,
    data: Page,
    signal: grain.CPtr,
    irq: grain.CPtr,
    next_cid: u16 = 0,
    /// Device sectors per 4 KiB block.
    per_block: u32 = 8,
    blocks: u64 = 0,

    /// `pages`: admin SQ, admin CQ, I/O SQ, I/O CQ, a data page.
    pub fn init(regs: usize, pages: [5]Page, signal: grain.CPtr, irq: grain.CPtr) Error!Nvme {
        var n: Nvme = .{
            .regs = regs,
            .stride = 0,
            .admin = .{ .id = 0, .sq = pages[0], .cq = pages[1] },
            .io = .{ .id = 1, .sq = pages[2], .cq = pages[3] },
            .data = pages[4],
            .signal = signal,
            .irq = irq,
        };
        for (pages[0..4]) |p| @memset(@as([*]u8, @ptrFromInt(p.va))[0..4096], 0);
        const cap = n.read64(Reg.cap);
        n.stride = @as(usize, 4) << @intCast((cap >> 32) & 0xf);
        if ((cap >> 37) & 1 == 0) return error.Unsupported; // no NVM command set
        // Reset, then describe the admin queues and enable.
        n.write32(Reg.cc, 0);
        try n.waitReady(false);
        n.write32(Reg.aqa, (depth - 1) << 16 | (depth - 1));
        n.write64(Reg.asq, n.admin.sq.pa);
        n.write64(Reg.acq, n.admin.cq.pa);
        // 64-byte submissions (2^6), 16-byte completions (2^4), 4 KiB pages.
        n.write32(Reg.cc, 1 | 6 << 16 | 4 << 20);
        try n.waitReady(true);

        // Namespace 1: its size and sector size.
        _ = try n.run(&n.admin, .{ .opcode = Op.identify, .cid = 0, .nsid = 1, .prp1 = n.data.pa, .cdw10 = 0 });
        const id = n.dataPage();
        const sectors = std.mem.readInt(u64, id[0..8], .little);
        const format = id[26] & 0xf;
        const lbads: u5 = @intCast((std.mem.readInt(u32, id[128 + @as(usize, format) * 4 ..][0..4], .little) >> 16) & 0xff);
        if (lbads < 9 or lbads > 12) return error.Unsupported;
        n.per_block = @as(u32, 1) << (12 - lbads);
        n.blocks = sectors / n.per_block;

        // One I/O queue pair: completions (interrupts on, vector 0), then
        // submissions feeding them.
        _ = try n.run(&n.admin, .{ .opcode = Op.create_cq, .cid = 0, .prp1 = n.io.cq.pa, .cdw10 = (depth - 1) << 16 | 1, .cdw11 = 0b11 });
        _ = try n.run(&n.admin, .{ .opcode = Op.create_sq, .cid = 0, .prp1 = n.io.sq.pa, .cdw10 = (depth - 1) << 16 | 1, .cdw11 = 1 << 16 | 1 });
        return n;
    }

    fn read32(n: *const Nvme, off: usize) u32 {
        return @as(*volatile u32, @ptrFromInt(n.regs + off)).*;
    }
    fn write32(n: *const Nvme, off: usize, v: u32) void {
        @as(*volatile u32, @ptrFromInt(n.regs + off)).* = v;
    }
    fn read64(n: *const Nvme, off: usize) u64 {
        return @as(u64, n.read32(off)) | @as(u64, n.read32(off + 4)) << 32;
    }
    fn write64(n: *const Nvme, off: usize, v: u64) void {
        n.write32(off, @truncate(v));
        n.write32(off + 4, @truncate(v >> 32));
    }

    fn waitReady(n: *const Nvme, ready: bool) Error!void {
        var spins: usize = 0;
        while ((n.read32(Reg.csts) & 1 == 1) != ready) : (spins += 1) {
            if (spins > 10_000_000) return error.Timeout;
            grain.yield();
        }
    }

    fn dataPage(n: *const Nvme) *[block_size]u8 {
        return @ptrFromInt(n.data.va);
    }

    /// Submit one command on `q` and wait for its completion.
    fn run(n: *Nvme, q: *Queue, cmd_in: Command) Error!u32 {
        var cmd = cmd_in;
        cmd.cid = n.next_cid;
        n.next_cid +%= 1;
        const sq: *volatile [depth]Command = @ptrFromInt(q.sq.va);
        sq[q.tail] = cmd;
        q.tail = (q.tail + 1) % depth;
        grain.fence();
        n.write32(0x1000 + (2 * @as(usize, q.id)) * n.stride, q.tail);
        const cq: *volatile [depth]Completion = @ptrFromInt(q.cq.va);
        while (true) {
            grain.fence();
            const e = cq[q.head];
            if (@as(u1, @truncate(e.status)) == q.phase) {
                q.head = (q.head + 1) % depth;
                if (q.head == 0) q.phase ^= 1;
                n.write32(0x1000 + (2 * @as(usize, q.id) + 1) * n.stride, q.head);
                if (e.status >> 1 != 0) return error.DeviceError;
                return e.dw0;
            }
            if (q.id != 0 and n.signal != 0) {
                _ = grain.wait(n.signal);
                _ = grain.invoke(n.irq, grain.abi.IrqMethod.ack, .{});
            } else grain.yield();
        }
    }

    fn transfer(n: *Nvme, op: u8, block: u64) Error!void {
        const lba = block * n.per_block;
        _ = try n.run(&n.io, .{ .opcode = op, .cid = 0, .nsid = 1, .prp1 = n.data.pa, .cdw10 = @truncate(lba), .cdw11 = @truncate(lba >> 32), .cdw12 = n.per_block - 1 });
    }

    pub fn read(n: *Nvme, block: u64, out: *[block_size]u8) Error!void {
        if (block >= n.blocks) return error.OutOfRange;
        try n.transfer(Op.read, block);
        out.* = n.dataPage().*;
    }

    pub fn write(n: *Nvme, block: u64, in: *const [block_size]u8) Error!void {
        if (block >= n.blocks) return error.OutOfRange;
        n.dataPage().* = in.*;
        grain.fence();
        try n.transfer(Op.write, block);
    }

    /// Everything written so far is on stable storage when this returns.
    pub fn flush(n: *Nvme) Error!void {
        _ = try n.run(&n.io, .{ .opcode = Op.flush, .cid = 0, .nsid = 1 });
    }
};
