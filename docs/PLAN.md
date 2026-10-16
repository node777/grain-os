# Grain build plan

Each phase ends with something that boots and a test that proves it.

## Phase 0: foundations ✅ (this commit)
- Research ([RESEARCH.md](RESEARCH.md)) and architecture
  ([ARCHITECTURE.md](ARCHITECTURE.md)).
- Zig 0.17 build: kernel for riscv64, host tests, QEMU run, test and debug
  steps.
- Caravan boots on QEMU virt under OpenSBI, installs the trap vector, handles
  a breakpoint exception and timer interrupts, emits structured records, and
  exits with a status the harness checks. Output is deterministic.

## Phase 1: Caravan core objects
- Device-tree parsing: memory map, timebase, harts, interrupt controller,
  test finisher (replacing the constants in `board.zig`).
- Physical memory → `Untyped` capabilities. Fixed kernel tables sized at boot.
- Capability format, CNodes, generations, `mint`, `retype`, `revoke`; host
  property tests.
- Sv39 kernel mapping (higher half), then user address spaces.
- First user domain: drop to U-mode, a `debug_put` syscall, return through
  the trap path (sscratch stack swap).
- Exit: a user task prints through a capability it was given, and fails
  cleanly when the capability is revoked.

## Phase 2: IPC, scheduling, the event door
- Endpoints (call/reply_recv fastpath), signals, IPC buffers, capability
  transfer.
- Factor everything into `core.step(event) -> effects`; `zig build sim`, the
  seeded deterministic simulator with invariant checks.
- MCS SchedContexts; timer-driven preemption; per-hart kernels with SMP
  bring-up through SBI HSM; IPIs.
- Leases with expiry and use counts.
- Exit: a ping-pong IPC benchmark across harts; the simulator runs 10⁶
  random steps clean; cycle counts reported as records.

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
- **Milestone:** build through Phase 2 before the next review.
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
