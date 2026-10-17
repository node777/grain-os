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
    /// Envoy only: the agent's leased services (granted, then asked for).
    pub const first_agent: u32 = 48;
    /// The first slot the domain may use for its own objects.
    pub const first_free: u32 = 64;
};

pub const cnode_bits = 8;

/// Fixed user addresses in every domain.
pub const Layout = struct {
    pub const program_base: usize = 0x10000;
    /// Device registers: each device has a `device_span` of address space
    /// from here (a virtio page, or a PCI function's BARs).
    pub const devices: usize = 0x7000_0000;
    pub const device_span: usize = 32 << 20;
    pub const info: usize = 0x7ff0_0000;
    pub const ipc_buffer: usize = 0x7ff1_0000;
    /// The stack grows down from here; its size is the manifest's `stack_kib`.
    pub const stack_top: usize = 0x7fff_0000;
    /// Domains may map their own memory from here up to `devices`.
    pub const heap: usize = 0x4000_0000;
};

/// Calls on the lifecycle endpoint (tag label).
pub const Lifecycle = enum(u32) {
    /// w0 = exit code. The domain is torn down; the call never returns.
    exit = 1,
    /// Envoy only: w0 = index of an askable agent service. Steward approves
    /// within the manifest's policy (once per service) and replies label 0
    /// with w0 = the slot of the new lease, or label 1 with w0 = a reason.
    ask = 2,
    /// w0 = 0: the domain is up and asks whether the whole boot is; Steward
    /// replies label 0 with w0 = 1 if every domain it was asked to start is
    /// running (or skipped), else 0. w0 = 1: the domain has acted on that
    /// (the store: confirmed the generation on trial) and is settled; a test
    /// system does not halt before every domain marked `await_ready` is.
    ready = 3,
};

pub const AskRefusal = enum(u32) {
    not_askable = 1,
    already_granted = 2,
    not_envoy = 3,
    failed = 4,
};

/// The badge services see when the agent calls them through Envoy.
pub const agent_badge: usize = 0xA6E7;

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
    /// The protocol's id (hash of its IDL descriptor).
    protocol_id: u64 = 0,
};

pub const AgentCap = extern struct {
    name: Name,
    protocol: Name,
    /// Where the lease lives in Envoy's CSpace (0 until granted).
    slot: u32,
    uses: u32,
    duration_ms: u32,
    flags: u32,
    protocol_id: u64,

    pub const granted: u32 = 1;
    pub const askable: u32 = 2;
};

pub const max_agent_caps = 16;

/// Who calls this domain's services: the badge a server sees, and whose it
/// is (a domain name, or "agent" for calls through Envoy).
pub const Client = extern struct {
    name: Name,
    badge: u64,
};

pub const max_clients = 16;

/// A PCI function's memory BAR, mapped in this domain.
pub const Bar = extern struct {
    /// Which BAR register (0..5).
    index: u32,
    _pad: u32 = 0,
    va: u64,
    size: u64,
    phys: u64,
};

pub const Bus = enum(u32) { virtio = 0, pci = 1 };

pub const Device = extern struct {
    name: Name,
    bus: Bus,
    virtio_id: u32,
    irq_line: u32,
    /// virtio: the MMIO frame (0 for PCI, whose BARs are only mapped).
    frame_slot: u32,
    irq_slot: u32,
    /// PCI: the function's identity and class (class, subclass, interface).
    vendor: u16 = 0,
    device_id: u16 = 0,
    class: u32 = 0,
    bar_count: u32 = 0,
    /// Where the registers are mapped: the virtio page, or the first BAR.
    mmio: u64,
    /// The device's physical address (for logs).
    phys: u64,
    bars: [3]Bar = std.mem.zeroes([3]Bar),

    /// The mapped BAR with register index `index`.
    pub fn bar(d: *const Device, index: u32) ?*const Bar {
        for (d.bars[0..d.bar_count]) |*b| if (b.index == index) return b;
        return null;
    }
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
    /// Envoy only: the agent's services.
    agent_count: u32,
    client_count: u32 = 0,
    agent: [max_agent_caps]AgentCap,
    clients: [max_clients]Client,

    /// The name of the domain (or "agent") behind a badge, if it is a client.
    pub fn clientName(info: *const DomainInfo, badge: usize) ?[]const u8 {
        for (info.clients[0..info.client_count]) |*c| if (c.badge == badge) return nameOf(&c.name);
        return null;
    }
};

comptime {
    std.debug.assert(@sizeOf(DomainInfo) <= 4096);
}
