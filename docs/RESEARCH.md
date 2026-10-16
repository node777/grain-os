# Research notes

What Grain and Caravan take from earlier systems, what they leave behind, and
why. These are the inputs to [ARCHITECTURE.md](ARCHITECTURE.md).

## Microkernels

### seL4: the reference point for security
- **Authority comes only from capabilities.** A thread can affect only the
  objects named by capabilities in its CSpace. The kernel has no ambient
  authority: no UIDs, no global names, no "root".
- **The kernel never allocates.** Userspace hands the kernel *untyped* memory
  and *retypes* it into kernel objects (TCBs, endpoints, page tables, CNodes).
  Kernel memory use is bounded and decided by policy outside the kernel. This
  is also why seL4 can be analysed for worst-case execution time.
- **IPC is synchronous call/reply on endpoints**, with a register-only
  fastpath (a few hundred cycles), plus asynchronous *notifications*
  (signal words) for interrupts and events.
- **MCS (mixed criticality) scheduling contexts** make CPU time a capability:
  a budget and period that can be passed along with a call, so a server runs
  on its client's time. In 2026 the functional-correctness proof for MCS on
  RISC-V was completed (Proofcraft), and seL4 16.0.0 and Microkit 2.3.0
  shipped in July 2026.
- **Microkit** (formerly the seL4 Core Platform) is a *static* system
  description: protection domains, memory regions and channels declared in
  XML and composed at build time into one image. It is very simple to reason
  about.
- **Pain points to improve on:** revocation walks a capability derivation tree
  (the tree is complex, revocation cost is unbounded per operation, and the
  bookkeeping is a big share of the proof); the API is low-level and hard to
  use without a framework (CAmkES, Microkit); dynamic systems are hard to
  build; nothing is typed above the "message registers" level.

### Hubris (Oxide): static, Rust, for firmware
- Every task is known at build time; the kernel has no create or destroy
  calls and no dynamic allocation. The whole system is one image you can
  attest.
- Drivers are unprivileged tasks. Tasks that crash restart under a supervisor.
- Lesson: **static composition removes whole classes of bugs** and makes a
  system easy to inspect. Grain uses a static core and adds dynamic behaviour
  on top as an explicit, capability-controlled layer.

### Zircon (Fuchsia)
- **Handles with rights** on kernel objects (VMOs, channels, ports). Channels
  carry bytes *and handles*, which makes passing a capability ordinary.
- **FIDL**: one IDL for every system interface, with generated bindings.
  Every service is typed and discoverable. This matters for an AI-operated OS.
- Weakness: a large kernel (hundreds of syscalls) and a large trusted base.

### Barrelfish (multikernel)
- Treats a many-core machine as a distributed system: a kernel per core,
  sharing no state, coordinating by messages. This scales without global
  locks and fits heterogeneous cores (RISC-V systems often mix core types).

### Object-capability lineage (KeyKOS, EROS, E, Capsicum, CHERI)
- **Caretaker / membrane pattern:** grant a *forwarder* instead of the real
  capability; revoking means cutting the forwarder. This gives *selective*,
  O(1) revocation without a derivation tree.
- **Petnames** and **sturdy references** (E, OCapN/CapTP): capabilities that
  cross machines and people, with human-meaningful local names. This is the
  route to a *social* OS without global identity or ACL systems.
- **CHERI** gives hardware capabilities (bounded, unforgeable pointers). A
  RISC-V CHERI extension is being standardised. Caravan's capability model
  should be able to use it later without changing user-visible semantics.

### Zig kernels
- Hobby and teaching kernels exist (zv6, an xv6 port; mooOS; Soma; aeros-v;
  popovicu's time-sharing kernel on OpenSBI; earlier Pluto and Zen). None is a
  capability microkernel with a serious security model. **There is no prior
  art to inherit, so Caravan sets its own conventions.**
- What Zig offers for kernel work: `comptime` (validated configuration, code
  generated from schemas, interfaces resolved at build time with no vtables),
  explicit allocators (it is easy to have *no* allocator), no hidden control
  flow, safety-checked builds (`ReleaseSafe`), first-class cross-compilation
  (one `zig build` for riscv64, aarch64 and x86_64), and `zig test` on the
  host for portable code.
- Zig is still pre-1.0. Grain pins one Zig version (currently **0.17.0**) and
  upgrades deliberately.

## Systems beyond the kernel

### NixOS: the system as a pure function
- The whole system configuration is a declarative expression. Building it
  produces content-addressed outputs in `/nix/store`. A *generation* is a
  pointer to one closure. Upgrade and rollback are atomic pointer swaps.
- Reproducible builds make "what is running" checkable.
- Lessons for Grain: **the system is a value**, built from a declarative
  manifest into a content-addressed closure. Boot measures it. Change is a
  transaction. Rollback always works. Grain takes the ideas without Nix's
  language complexity: the manifest is plain data in Zig Object Notation
  (ZON), checked at compile time.

### Linux: what works at scale
- **io_uring:** shared submission/completion rings remove syscall overhead for
  bulk I/O. Caravan's bulk channels follow the same shape.
- **eBPF:** verified, sandboxed programs extending a privileged component.
  Inspiration for safe policy plug-ins, kept in userspace in Grain.
- **Namespaces and cgroups** are ambient-authority systems added after the
  fact. Capabilities give the same isolation by construction.
- **Device trees and driver coverage:** Linux's driver base can't be matched.
  Grain reaches common hardware with virtio first, then a **Linux guest VM**
  (RISC-V H extension, later VT-x and ARM EL2) that serves as a driver and app
  compatibility domain, the way Qubes and the seL4 VMM do.

### Deterministic simulation testing (TigerBeetle, FoundationDB)
- Run the real code with clock, I/O and scheduling replaced by a seeded
  simulator. Any failure replays from (commit, seed). Thousands of simulated
  hours run per real hour.
- TigerBeetle (written in Zig) also allocates everything statically at
  startup. That suits a kernel exactly.
- Lesson: **design Caravan's core as a pure state machine** so the same code
  runs on hardware and in a host simulator.

### Agent-oriented OS research (2026)
- AgenticOS (intent-scoped capabilities for agents), Agent Operating Systems
  (where agent workloads break process, permission and syscall assumptions),
  AOHP (services exposed to agents as interface-neutral capabilities). These
  agree with Grain's thesis: **agents need narrow, typed, revocable authority
  and a legible system**, not root shells that scrape text.
- MCP (Model Context Protocol) is the de facto way agents call tools. Grain's
  typed interfaces can be projected into MCP tools automatically.

## RISC-V specifics that shape the design
- **SBI** (OpenSBI) abstracts M-mode: console, timer, IPIs, hart start and
  stop, reset. Caravan uses SBI for early boot, so one image boots on any
  SBI-compliant board.
- **Sv39/Sv48/Sv57** paging; ASIDs; the `Svpbmt` and `Svinval` extensions.
  **RVA23** is the profile to target for application-class hardware.
- **AIA** (IMSIC/APLIC) gives message-signalled interrupts per hart, which
  suits per-core kernels. PLIC stays as the fallback.
- The **RISC-V IOMMU** spec is ratified (QEMU has supported a model since
  9.2), which lets userspace drivers be DMA-isolated.
- The **H extension** (hypervisor) supports Linux guest domains.
- **PMP** and **Smepmp** support a verified-boot story and M-mode lock-down.
- Boards worth considering for later real-hardware bring-up: StarFive
  VisionFive 2, Milk-V Jupiter/Megrez, SiFive HiFive Premier, and RVA23
  boards as they ship.

## Sources
- seL4 July 2026 releases: https://sel4.discourse.group/t/july-2026-releases-of-sel4-microkit-camkes-capdl-and-rust-support/1069
- seL4 news (MCS RISC-V proof): https://www.sel4.systems/news/
- Microkit manual 2.3.0: https://docs.sel4.systems/projects/microkit/manual/2.3.0/microkit_user_manual.pdf
- Hubris reference: https://hubris.oxide.computer/reference/
- Hubris and Humility: https://oxide.computer/blog/hubris-and-humility
- From Hubris to Bits: https://cliffle.com/blog/from-hubris-to-bits/
- TigerBeetle VOPR: https://docs.tigerbeetle.com/about/vopr
- Protocol-aware DST (TigerBeetle, 2026): https://tigerbeetle.com/blog/2026-08-20-protocol-aware-dst
- AgenticOS: https://arxiv.org/pdf/2606.21129
- Agent Operating Systems: https://arxiv.org/pdf/2606.01508
- AOHP: https://www.emergentmind.com/papers/2606.23449
- Zig 0.17 build system: https://linuxiac.com/?p=220546
- Zig RISC-V kernels: https://zff.dev/baltevl/zv6 · https://zff.dev/vinymeuh/mooOS · https://codeberg.org/AustinPeps/Soma · https://github.com/Fingel/aeros-v · https://gittrend.io/repo/popovicu/zig-time-sharing-kernel
