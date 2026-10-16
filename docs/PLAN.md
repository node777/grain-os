# Grain build plan

Each phase ends with something that boots and a test that proves it.

## Phase 0: foundations ✅
- Research ([RESEARCH.md](RESEARCH.md)) and architecture
  ([ARCHITECTURE.md](ARCHITECTURE.md)).
- Zig 0.17 build; Caravan boots on QEMU virt under OpenSBI; structured
  records; pass/fail exit status; deterministic output.

## Phase 1: Caravan core objects ✅
- Device-tree platform discovery (memory, reserved ranges, harts, timebase,
  PLIC and contexts, UART, test finisher, device MMIO ranges).
- Object table with generations; 16-byte capabilities; CNodes with mint,
  delete, move, revoke, identify.
- Untyped regions with double-ended allocation, object budgets and recursive
  reset; device untypeds.
- Higher-half Sv39 kernel with a physmap; user page tables with shadow
  indices.
- The root task, loaded from an ELF embedded in the kernel, runs in U-mode
  with a boot-info page and an initial CSpace.
- Exit, met: user code prints through its debug-console capability; a
  revoked capability fails with `invalid_cap`.

## Phase 2: IPC, scheduling, the event door ✅
- Endpoints (call, send, recv, reply_recv, reply), IPC buffers, capability
  transfer with `grant`, badges; signals; fault endpoints; IRQs as signals.
- MCS scheduling contexts, preemption by timer, round robin, throttling,
  donation to passive servers, maximum controlled priority.
- Leases with duration and use limits.
- The core is `handle(hart, now, event)` behind a comptime arch interface;
  host scenario tests; `caravan-sim`, the seeded deterministic simulator.
- SMP: secondary harts through SBI HSM; per-hart run queues; a kernel lock;
  synchronous IPI kicks; root-table retirement across harts; synchronous
  remote TLB flushes.
- Exit, met: a cross-hart call benchmark; the simulator ran 10⁶ random steps
  (20 seeds, 2 harts) with every invariant checked after every step;
  benchmark and per-entry profile records (`zig build bench`).

### Left over from Phases 1–2 (carried into Phase 3)
- IPC fastpath (register-only call/reply that skips the general scheduler).
- Checking protocol ids on endpoints (the capability field exists).
- Frame aliases, so memory can be shared between address spaces (needed
  for channels).
- Multi-level CSpaces.
- ASIDs, to avoid flushing the TLB on every address-space switch.
- `fence.i` when executable pages change, for real hardware.
- Sporadic-server refills (seL4-style) instead of simple periodic refills.
- Preemptible `Untyped.reset` for very large regions.
- Ledger mode (event recording for replay and audit).

## Phase 3: the manifest and Steward
- The `grain.zon` manifest format; `comptime` validation of the wiring;
  the build packs kernel, Steward and domains into one image with a BLAKE3
  closure hash.
- Steward: starts domains, wires capabilities, restarts on fault.
- First userspace drivers: virtio-console (with a second port for Envoy),
  virtio-rng.
- Exit: the system boots from a manifest; a miswired manifest fails to
  *compile* with a readable error.

## Phase 4: typed interfaces, Registry, Envoy
- Zig-as-IDL protocol definitions → generated stubs and descriptors; protocol
  ids checked on endpoints.
- Registry service; Envoy protocol (`discover`, `describe`, `plan`, `apply`,
  `observe`, `undo`, `ask`) over virtio-console.
- The harness becomes the Envoy driver; the first interactive session drives
  Grain over Envoy from the host.
- Structured shell over the same protocol.
- Exit: an agent on the host discovers and calls a service it was leased,
  and is refused after the lease expires.

## Phase 5: storage, Ledger, generations, identity
- virtio-blk driver; Granary (content-addressed, encrypted); Ledger
  (hash-chained).
- Generations and rollback: build a new generation, switch, roll back, all
  through Envoy.
- Seal: first-boot identity creation, device keys, pronounceable names,
  petnames.
- Exit: upgrade and rollback survive a forced power-off at every step (in the
  simulator and in QEMU); the identity persists across reboots and rollbacks.

## Phase 6: the personal desktop
- virtio-gpu and virtio-input drivers, a compositor domain, a minimal
  widget toolkit, the structured shell as the first graphical app.
- Testing through QMP screendump images and injected input.
- Exit: boot to a desktop; open the shell; every visible element can be
  inspected as typed data through Envoy.

## Phase 7: the social layer
- virtio-net, a userspace UDP/IP stack, Courier (identity-addressed,
  Noise-encrypted sessions, LAN discovery, friend relays).
- Sturdy references backed by Leases; hosted apps; Granary exchange.
- Exit: two QEMU Grain instances introduce themselves, one hosts an app
  that the other uses, files move between them, then access is revoked.

## Phase 8: reach
- Native drivers for personal hardware: NVMe, xHCI with USB HID and storage,
  display, Ethernet; then Wi-Fi.
- RISC-V IOMMU; real-board bring-up (an RVA23 board first); aarch64 and
  x86_64 ports running the same suite on QEMU.

## Phase 9: hardening
- Fuzzing of every kernel entry point; model checks of IPC and revocation;
  measured boot; performance work on RVA23 hardware; an external review of
  the capability model.

## Owner decisions
- **Milestone:** build through Phase 2 before the next review (done).
- **Primary use case:** a personal device.
- **Social:** every instance has a shareable identity, used to move data,
  host applications and connect with other people's instances (inspired by
  Urbit); sharing between people first.
- **Compatibility:** none. No Linux guest and no POSIX layer.

## Still open
- **Assurance:** simulation and testing (planned), or aiming for formal
  verification (needs a different process and much more time).
- **License:** none is chosen yet; it should be settled before outside
  contributions.
