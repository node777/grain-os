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

## Phase 5: storage, Ledger, generations
- virtio-blk driver; Granary (content-addressed, encrypted); Ledger
  (hash-chained).
- Generations and rollback: build a new generation, switch, roll back, all
  through Envoy.
- Exit: upgrade and rollback survive a forced power-off at every step (in the
  simulator and in QEMU).

## Phase 6: networking and the social layer
- virtio-net, a userspace TCP/IP stack, an OCapN/CapTP-style protocol for
  sturdy references across machines, petnames.
- Exit: two QEMU Grain machines share a directory by passing a capability,
  then revoke it.

## Phase 7: reach
- aarch64 and x86_64 ports (same suite on QEMU); a Linux guest VM through the
  RISC-V H extension for hardware and app compatibility; virtio-gpu and a
  minimal compositor; RISC-V IOMMU; real-board bring-up.

## Phase 8: hardening
- Fuzzing of every kernel entry point; model checks of IPC and revocation;
  measured boot; performance work on RVA23 hardware; an external review of
  the capability model.

## Open questions for the owner
1. **First milestone:** how far past Phase 0 to go before the next review.
2. **Primary use case:** personal device, server, embedded or appliance, or
   AI-agent host. This decides how soon dynamism, graphics and the Linux guest
   matter.
3. **"Social":** sharing between the owner's own devices, between people,
   multi-user on one machine, or federation.
4. **Compatibility:** a Linux guest VM, a POSIX layer, or no compatibility.
5. **Assurance:** simulation and testing (planned), or aiming for formal
   verification (needs a different process and much more time).
6. **License.** None is chosen yet; it should be settled before outside
   contributions.
