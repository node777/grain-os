//! The Caravan system-call ABI, shared by the kernel and every user program.
//!
//! This file is the contract. Anything a user program can ask the kernel is
//! named here: system calls, object kinds, rights, methods and error codes.
//! Names are stable identifiers meant to be read by people and agents alike.
//!
//! Register convention (RISC-V):
//!
//!   in:  a7 = Syscall, a0 = capability slot (CPtr), a1 = Tag, a2..a6 = message words 0..4
//!   out: a0 = Status, a1 = Tag, a2..a6 = message words 0..4, a7 = badge (receive operations;
//!        bits 32..47 hold the protocol id of the sender's capability, 0 if none; bit 63
//!        set means no message: the thread's bound signal fired, its bits in word 0)
//!
//! Messages longer than five words continue in the thread's IPC buffer
//! (`IpcBuffer.words[5..]`). Capabilities travel through the IPC buffer too.
const std = @import("std");

/// A slot index in the calling thread's capability space (its root CNode).
pub const CPtr = u32;
pub const null_cptr: CPtr = 0;

pub const Syscall = enum(usize) {
    /// Send a message and wait for the reply (endpoint).
    call = 1,
    /// Send a message; block until a receiver takes it (endpoint).
    send = 2,
    /// Wait for a message (endpoint).
    recv = 3,
    /// Reply to the last caller, then wait for the next message (endpoint).
    reply_recv = 4,
    /// OR the capability's badge into a signal word (signal).
    signal = 5,
    /// Wait until a signal word is non-zero, then take and clear it (signal).
    wait = 6,
    /// Like wait, but never blocks; returns 0 bits if none are pending.
    poll = 7,
    /// Give up the rest of this turn at the current priority.
    yield = 8,
    /// Call a method on a kernel object: a1 = method, a2..a6 = arguments.
    invoke = 9,
    /// Reply to the last caller without waiting for another message.
    reply = 10,
    _,
};

pub const Status = enum(usize) {
    ok = 0,
    /// The slot is empty, out of range, or names a destroyed or revoked object.
    invalid_cap = 1,
    /// The capability names an object of the wrong kind for this operation.
    wrong_kind = 2,
    /// The capability lacks a right this operation needs.
    no_rights = 3,
    invalid_argument = 4,
    /// The untyped region has too little free memory.
    no_memory = 5,
    /// The untyped region has used its whole object budget.
    no_objects = 6,
    slot_occupied = 7,
    slot_empty = 8,
    /// The lease this capability goes through has expired.
    lease_expired = 9,
    /// The lease this capability goes through has no uses left.
    lease_exhausted = 10,
    /// A mapping already exists at that address.
    already_mapped = 11,
    /// An intermediate page table is missing for that address.
    no_page_table = 12,
    not_mapped = 13,
    /// The peer was destroyed or the operation was cancelled.
    aborted = 14,
    /// A non-blocking operation found nothing to do.
    would_block = 15,
    /// The endpoint speaks a different protocol than the capability expects.
    protocol_mismatch = 16,
    /// The object is in a state that does not allow this operation.
    invalid_state = 17,
    unknown_method = 18,
    unknown_syscall = 19,
    _,
};

/// Message descriptor, passed in a1.
pub const Tag = packed struct(usize) {
    /// Free-form message label (e.g. a method number in a user protocol).
    label: u32 = 0,
    /// Number of message words (0..max_message_words).
    length: u7 = 0,
    /// Number of capabilities transferred through the IPC buffer (0..max_message_caps).
    caps: u3 = 0,
    _reserved: u22 = 0,
};

pub const register_words = 5;
/// In a7 after a receive: the thread's bound signal fired (no message).
pub const recv_signalled: u64 = 1 << 63;
/// The most bytes one `DebugMethod.write` takes (the IPC buffer's words).
pub const max_debug_write = max_message_words * 8;
pub const max_message_words = 64;
pub const max_message_caps = 4;

/// A per-thread page shared with the kernel for long messages and capability
/// transfer. It is bound to a thread with `ThreadMethod.set_ipc_buffer`.
pub const IpcBuffer = extern struct {
    /// Message words. Words 0..4 travel in registers; the kernel reads and
    /// writes 5..63 here.
    words: [max_message_words]usize,
    /// Capabilities to send (slots in the sender's CSpace).
    send_caps: [max_message_caps]CPtr,
    /// Empty slots in the receiver's CSpace where received capabilities go.
    recv_slots: [max_message_caps]CPtr,
    /// Filled in on receive: how many capabilities arrived.
    received_caps: u32,
    _pad: u32,
};

pub const ThreadState = enum(u8) {
    inactive = 0,
    running = 1,
    ready = 2,
    /// Runnable, but its scheduling context is out of budget or missing.
    stalled = 3,
    blocked_send = 4,
    blocked_recv = 5,
    blocked_reply = 6,
    blocked_signal = 7,
};

/// Delivered as the label of a fault message on a thread's fault endpoint;
/// words: [0] faulting address, [1] pc, [2] raw cause.
/// Reply with label 0 to retry the instruction, or label 1 to resume at word 0.
pub const FaultKind = enum(u32) {
    fetch_page_fault = 1,
    load_page_fault = 2,
    store_page_fault = 3,
    illegal_instruction = 4,
    breakpoint = 5,
    misaligned = 6,
    access = 7,
    unknown = 8,
};

pub const Kind = enum(u8) {
    free = 0,
    untyped = 1,
    cnode = 2,
    thread = 3,
    frame = 4,
    page_table = 5,
    endpoint = 6,
    signal = 7,
    sched_context = 8,
    lease = 9,
    irq = 10,
    /// The right to create Irq objects for interrupt lines.
    irq_control = 11,
    /// The right to give scheduling contexts their budgets.
    sched_control = 12,
    /// Debug console and power control, for bring-up and tests.
    debug_console = 13,
    _,
};

pub const Rights = packed struct(u16) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    /// Allows capabilities to be sent through this endpoint.
    grant: bool = false,
    /// Send or call on an endpoint; signal a signal.
    send: bool = false,
    /// Receive on an endpoint; wait on a signal.
    recv: bool = false,
    /// Invalidate every other capability to the object (CNode.revoke).
    revoke: bool = false,
    /// Change the object's configuration (thread registers, page mappings, …).
    configure: bool = false,
    /// Create objects from this untyped region, or reset it.
    retype: bool = false,
    _reserved: u7 = 0,

    pub const all: Rights = .{ .read = true, .write = true, .execute = true, .grant = true, .send = true, .recv = true, .revoke = true, .configure = true, .retype = true };
    pub const none: Rights = .{};

    pub fn bits(r: Rights) u16 {
        return @bitCast(r);
    }
    pub fn fromBits(b: u16) Rights {
        return @bitCast(b & all.bits());
    }
    pub fn intersect(a: Rights, b: Rights) Rights {
        return fromBits(a.bits() & b.bits());
    }
    pub fn contains(a: Rights, b: Rights) bool {
        return a.bits() & b.bits() == b.bits();
    }
};

// ---------------------------------------------------------------------------
// Methods (Syscall.invoke): a1 = method number, a2..a6 = arguments.

pub const UntypedMethod = enum(u32) {
    /// (kind, size_bits, dest_slot) -> creates one object; its capability
    /// (all rights) goes into dest_slot of the caller's CSpace.
    /// size_bits: CNode = log2(slots); Untyped = log2(bytes); Frame = 12, 21 or 30.
    retype = 1,
    /// () -> destroys every object made from this region and frees its memory.
    reset = 2,
    /// () -> a2 = base, a3 = size, a4 = bytes free, a5 = objects left, a6 = is_device
    info = 3,
};

pub const CNodeMethod = enum(u32) {
    /// (dest_index, src_cptr, rights_mask, badge, protocol) -> copies the
    /// capability in the caller's src_cptr into slot dest_index of this CNode,
    /// keeping only rights_mask. A badge and a protocol id may each be set
    /// only once (when the source has none); 0 leaves them as they are.
    /// Endpoints refuse a message whose sender's and receiver's protocol ids
    /// are both set and differ (protocol_mismatch, to the sender).
    mint = 1,
    /// (index) -> empties the slot.
    delete = 2,
    /// (index) -> invalidates every capability to the object in that slot
    /// (and to any lease through it), then gives the slot a fresh one.
    revoke = 3,
    /// (index) -> a2 = kind, a3 = rights, a4 = badge, a5 = kind behind a
    /// lease (else the same kind), a6 = object id.
    identify = 4,
    /// (dest_index, src_index) -> moves a capability within this CNode.
    move = 5,
    /// (index) -> a2 = uses left (maxInt if unlimited), a3 = expiry tick (0 = never), a4 = armed
    lease_info = 6,
};

pub const ThreadMethod = enum(u32) {
    /// (cspace_cptr, vspace_cptr, fault_endpoint_cptr or 0)
    configure = 1,
    /// (pc, sp, arg0, arg1)
    write_registers = 2,
    /// () make runnable
    resume_thread = 3,
    /// () stop running
    suspend_thread = 4,
    /// (priority 0..255) at most the caller's maximum controlled priority
    set_priority = 5,
    /// (sched_context_cptr or 0 to unbind)
    bind_sched = 6,
    /// (frame_cptr, user address)
    set_ipc_buffer = 7,
    /// () -> a2 = ThreadState, a3 = priority, a4 = pc, a5 = hart
    info = 8,
    /// (mcp 0..255) the highest priority the thread may set; at most the caller's
    set_mcp = 9,
    /// (signal_cptr or 0 to unbind) while the thread waits to receive on an
    /// endpoint, this signal firing ends the wait too (a7 bit 63, the bits
    /// in word 0), so one thread serves its clients and its interrupts.
    /// A signal binds to one thread at a time.
    bind_signal = 10,
};

/// Methods on a root page table (created with size_bits = top level).
pub const VSpaceMethod = enum(u32) {
    /// (frame_cptr, vaddr, rights) maps a frame into this address space.
    map_frame = 1,
    /// (page_table_cptr, vaddr) links a page table below this root, at the
    /// table's own level (given as size_bits when it was created).
    map_table = 2,
    /// (vaddr) removes the frame mapped at vaddr.
    unmap = 3,
};

pub const FrameMethod = enum(u32) {
    /// () -> a2 = physical address, a3 = size in bytes, a4 = is device memory,
    /// a5 = is mapped. Drivers need the physical address to program DMA.
    info = 1,
};

pub const SchedControlMethod = enum(u32) {
    /// (sched_context_cptr, budget_ticks, period_ticks, hart)
    configure = 1,
};

pub const IrqControlMethod = enum(u32) {
    /// (line, dest_slot) -> an Irq capability for that interrupt line.
    get = 1,
};

pub const IrqMethod = enum(u32) {
    /// (signal_cptr) interrupts on this line set the signal capability's badge.
    set_signal = 1,
    /// () re-enable the line after handling it.
    ack = 2,
};

/// Methods on a lease that has not been armed yet. Once armed, every
/// invocation through a lease capability goes to the lease's target instead;
/// use CNode.lease_info to inspect it and CNode.revoke to end it.
pub const LeaseMethod = enum(u32) {
    /// (target_cptr, rights_mask, duration_ticks or 0, uses or 0) points the
    /// lease at a capability. Capabilities to the lease then act as the target
    /// with at most rights_mask, until the duration passes, the uses run out,
    /// or the lease is revoked.
    arm = 1,
};

/// Methods on a signal.
pub const SignalMethod = enum(u32) {
    /// (ticks, or 0 to cancel) after `ticks` timer ticks the signal fires as
    /// if signalled through this capability (its badge, or 1). One alarm per
    /// signal: arming it again replaces the last. Needs the `send` right.
    alarm = 1,
};

pub const DebugMethod = enum(u32) {
    /// (byte count, then up to 32 bytes packed little-endian in a3..a6).
    /// A count of 33..`max_debug_write` takes the bytes from the start of the
    /// caller's IPC buffer instead. Either way one call is written whole, so
    /// lines from different harts never interleave.
    write = 1,
    /// (code) power off; code 0 means success. Needs the `configure` right,
    /// so a write-only console capability can be handed out safely.
    exit = 2,
    /// () -> a2 = time (ticks), a3 = timebase Hz
    time = 3,
};

// ---------------------------------------------------------------------------
// The root task's initial capability space.

pub const RootSlot = struct {
    pub const cnode: CPtr = 1;
    pub const vspace: CPtr = 2;
    pub const thread: CPtr = 3;
    pub const sched_context: CPtr = 4;
    pub const irq_control: CPtr = 5;
    pub const sched_control: CPtr = 6;
    pub const debug_console: CPtr = 7;
    pub const boot_info_frame: CPtr = 8;
    pub const ipc_buffer_frame: CPtr = 9;
    /// Untyped capabilities start here; BootInfo says how many.
    pub const first_untyped: CPtr = 16;
};

pub const root_cnode_bits = 12;

/// Fixed user addresses the kernel uses when it builds the root task.
pub const RootLayout = struct {
    /// A read-only copy of the device tree (up to `max_dtb_pages` pages).
    pub const dtb: usize = 0x7fe0_0000;
    pub const max_dtb_pages = 64;
    pub const boot_info: usize = 0x7ff0_0000;
    pub const ipc_buffer: usize = 0x7ff1_0000;
    pub const stack_top: usize = 0x7fff_0000;
    pub const stack_pages = 16;
};

pub const max_boot_untyped = 64;

pub const UntypedDesc = extern struct {
    base: u64,
    size: u64,
    objects: u32,
    is_device: u32,
};

/// Read-only page the kernel maps for the root task at `RootLayout.boot_info`.
pub const BootInfo = extern struct {
    magic: u64 = boot_info_magic,
    timebase_hz: u64,
    boot_time: u64,
    hart_count: u32,
    untyped_count: u32,
    /// First empty slot in the root CNode after the untyped capabilities.
    first_free_slot: u32,
    root_cnode_slots: u32,
    user_top: u64,
    page_size: u64,
    /// Where the device-tree copy is mapped, and its size (0 if none).
    dtb_addr: u64,
    dtb_size: u64,
    /// What booted, as the loader measured it (all zero if nothing did).
    measurement: Measurement = .{},
    untyped: [max_boot_untyped]UntypedDesc,
};

/// Measured boot: hashes of what ran before the kernel, chained (see
/// grain/lib/measure.zig). The chain is what attestations sign.
pub const Measurement = extern struct {
    /// extend(extend(0, "loader", loader), "generation", generation).
    chain: [32]u8 = @splat(0),
    /// BLAKE3 of the loader's code (Aurora's text and read-only data).
    loader: [32]u8 = @splat(0),
    /// The generation booted: the hash of its descriptor, which names every
    /// byte of the kernel, Steward, the manifest and the programs.
    generation: [32]u8 = @splat(0),

    pub fn measured(m: *const Measurement) bool {
        for (m.chain) |b| if (b != 0) return true;
        return false;
    }
};

/// The boot protocol's third register (a2 on RISC-V, x2 on Arm): the
/// physical address of this, when the loader measured what it booted.
/// The kernel accepts it only inside RAM and with the magic.
pub const BootMeasurement = extern struct {
    magic: u64 = boot_measurement_magic,
    m: Measurement,
};
pub const boot_measurement_magic: u64 = 0x6772_6d65_6173_7572; // "grmeasur"
pub const boot_info_magic: u64 = 0x6772_6169_6e5f_6269; // "grain_bi"

comptime {
    std.debug.assert(@sizeOf(IpcBuffer) <= 4096);
    std.debug.assert(@sizeOf(BootInfo) <= 4096);
}
