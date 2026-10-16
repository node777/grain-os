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

## Phase 3: the manifest and Steward ✅
- The manifest schema (`grain/manifest/schema.zig`) and one validator used
  at compile time (in Steward) and at run time (host tests, `grain-pack`).
  It covers wiring, protocols, priorities, memory, per-hart CPU commitments
  and call cycles.
- The boot image with BLAKE3 program hashes and a closure hash, built by
  `tools/pack` and verified by Steward at boot.
- Steward: domains in private regions, badged service wiring, devices from
  the device tree, the `DomainInfo` contract, a lifecycle endpoint, restart
  on fault with limits, revoking a dead provider's services, and a summary
  and halt for test systems.
- Drivers: virtio-console and virtio-rng on modern virtio-mmio.
- Kernel additions: `Frame.info`, the DTB copied into the root task, and
  power-off needing the `configure` right.
- Exit, met: the system boots from `system/dev.zon` (now `dev.brix`; two drivers, a service
  that crashes and is restarted, two tasks; output checked on the virtio
  console). `system/tests/faults.zon` shows the restart limit and
  revocation. `system/tests/miswired.zon` fails to *compile* with the
  explanation.

### Left over from Phase 3
- A second virtio-console device for Envoy: done in Phase 4.
- Passive services (running on their clients' time) as a manifest option.
- Frame aliases, so shared-memory channels can carry bulk data instead of
  32-byte messages.
- Bit-exact replay with devices attached: under plain `-icount`, host I/O
  timing (the rng backend) changes instruction counts between runs. What
  happens is identical every run, but exact counts need QEMU record/replay.
- Plus the items still open from Phases 1–2 (fastpath, ASIDs, multi-level
  CSpaces, …). Protocol ids checked by the kernel: done in Phase 4.

## Phase 4: typed interfaces, Registry, Envoy, Brix ✅
Built:
- Zig as the IDL (`grain/lib/idl.zig`, `grain/proto/`): typed calls, server
  dispatch, wire encoding, canonical JSON descriptors with effects and undo
  methods, and protocol ids. `CNode.mint` stamps a protocol id; the kernel
  refuses mismatched senders (`protocol_mismatch`).
- Services: the Registry (descriptors by id, served in chunks) and a
  key-value store whose writes can be undone.
- The manifest's `agent` section; device `instance` and `optional`. Steward
  creates the agent's leases once per boot (badged, protocol-stamped,
  use- and time-limited) and answers `ask` within the manifest's policy.
- Envoy on its own virtio console: `hello`, `discover`, `describe`, `call`,
  `plan`, `apply` (all-or-nothing, with rollback), `undo`, `ask`, `observe`
  (a BLAKE3-chained audit log), `bye`.
- Host side: `tools/envoy.py` (client library, grainsh, an MCP bridge that
  makes every held method an MCP tool); the harness drives agent scripts.
- Kernel and harness fixes the agent run exposed: targeted TLB shootdowns,
  whole-line debug writes, any boot hart. See TESTING.md.
- Exit, met: `tools/agent_session.py` (in `zig build qemu-test`) discovers
  and calls services it was leased, is refused once a use-limited lease is
  exhausted and once a timed lease expires, and verifies the audit chain.

- **Brix** (owner decision, 2026-10-16): the manifest language. Templates,
  units, named blocks; evaluation directed by the schema type; errors with
  line, column and a fix; the build evaluates `system/*.brix` to the ZON
  Steward embeds. The converted manifests were checked field by field
  against the ZON files they replace before those were removed.

### Left over from Phase 4
- `ask` decided by a live owner prompt instead of manifest policy (with Seal).
- `observe` as a subscription to typed events, not a snapshot.
- Descriptors carry no required rights yet; plans don't report a diff of
  service state.
- Envoy reachable over a local socket or the network, not only a virtio console.
- Why `-icount sleep=on` stalls two-hart boots under QEMU 8.2 is not pinned
  down; real-time runs use free-running TCG instead.
- Code renames to the owner's proposed names (GLOSSARY.md), now that
  Phase 4 is done: this needs the owner's go-ahead on the mapping.

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
- **Milestone:** build through Phase 2 before the next review (done); then
  Phase 3 (done).
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
