//! The contract between Steward and every domain it starts.
//!
//! A domain's capability space and address space have a fixed layout, and a
//! read-only `DomainInfo` page says what the manifest gave this domain:
//! its name, the services it uses and provides (by name, with their
//! protocols and slots), and its devices. Programs look things up by name;
//! nothing is wired by convention alone.
const std = @import("std");

/// Slots in a domain's CSpace (a CNode of 2^cnode_bits slots).
pub const Slot = struct {
    pub const cnode: u32 = 1;
    pub const vspace: u32 = 2;
    pub const thread: u32 = 3;
    /// An untyped region of manifest `memory_kib` the domain may allocate from.
    pub const memory: u32 = 4;
    /// Steward's lifecycle endpoint (send only; badge = this domain).
    pub const steward: u32 = 5;
    /// A write-only debug console, if the manifest grants one.
    pub const debug_console: u32 = 6;
    pub const ipc_buffer_frame: u32 = 7;
    pub const first_use: u32 = 16;
    pub const first_provide: u32 = 24;
    /// Each device takes two slots: its MMIO frame, then its Irq.
    pub const first_device: u32 = 32;
    /// The first slot the domain may use for its own objects.
    pub const first_free: u32 = 48;
};

pub const cnode_bits = 8;

/// Fixed user addresses in every domain.
pub const Layout = struct {
    pub const program_base: usize = 0x10000;
    /// Device MMIO pages, one 4 KiB page per device.
    pub const devices: usize = 0x7000_0000;
    pub const info: usize = 0x7ff0_0000;
    pub const ipc_buffer: usize = 0x7ff1_0000;
    pub const stack_top: usize = 0x7fff_0000;
    pub const stack_pages = 8;
    /// Domains may map their own memory from here up to `devices`.
    pub const heap: usize = 0x4000_0000;
};

/// Calls on the lifecycle endpoint (tag label).
pub const Lifecycle = enum(u32) {
    /// w0 = exit code. The domain is torn down; the call never returns.
    exit = 1,
};

pub const name_len = 24;
pub const max_services = 8;
pub const max_devices = 4;

pub const Name = [name_len]u8;

pub fn nameOf(n: *const Name) []const u8 {
    return std.mem.sliceTo(n, 0);
}

pub fn setName(n: *Name, s: []const u8) void {
    n.* = @splat(0);
    const len = @min(s.len, name_len - 1);
    @memcpy(n[0..len], s[0..len]);
}

pub const Service = extern struct {
    name: Name,
    protocol: Name,
    slot: u32,
    _pad: u32 = 0,
};

pub const Device = extern struct {
    name: Name,
    virtio_id: u32,
    irq_line: u32,
    frame_slot: u32,
    irq_slot: u32,
    /// Where the MMIO page is mapped in this domain.
    mmio: u64,
    /// The device's physical address (for logs).
    phys: u64,
};

pub const info_magic: u64 = 0x6772_6169_6e5f_646f; // "grain_do"

/// Mapped read-only at `Layout.info`; its address is also passed in a0.
pub const DomainInfo = extern struct {
    magic: u64 = info_magic,
    name: Name,
    program: Name,
    system: Name,
    /// Position of this domain in the manifest.
    index: u32,
    /// 0 on first start; incremented by each restart.
    restart_count: u32,
    timebase_hz: u64,
    memory_bytes: u64,
    hart: u32,
    use_count: u32,
    provide_count: u32,
    device_count: u32,
    /// BLAKE3 of this domain's program, as verified by Steward.
    program_hash: [32]u8,
    /// The closure hash of the whole system image.
    closure: [32]u8,
    uses: [max_services]Service,
    provides: [max_services]Service,
    devices: [max_devices]Device,
};

comptime {
    std.debug.assert(@sizeOf(DomainInfo) <= 4096);
}
