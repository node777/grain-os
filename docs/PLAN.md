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
- ~~`ask` decided by a live owner prompt instead of manifest policy.~~ Done
  (the `consent` domain asks at the console); the desktop prompt remains.
- `observe` as a subscription to typed events, not a snapshot.
- Descriptors carry no required rights yet; plans don't report a diff of
  service state.
- Envoy reachable over a local socket or the network, not only a virtio console.
- Why `-icount sleep=on` stalls two-hart boots under QEMU 8.2 is not pinned
  down; real-time runs use free-running TCG instead.
- Code renames to the owner's proposed names (GLOSSARY.md), now that
  Phase 4 is done: this needs the owner's go-ahead on the mapping.

## Phase 5: storage, Ledger, generations, identity ✅
Owner decisions (2026-10-16): the disk is unlocked by the owner's
passphrase; new components take the owner's names in code (Tablecloth,
Mantra, Kumara, Aurora); an identity's name is three words from a bank of
four-letter words (more formats may come); new generations are pushed
through Envoy.

Built:
- Messages of up to 64 words (the IPC buffer), `idl.Text`/`idl.Bytes` up to
  504 bytes; per-domain stacks (`stack_kib`).
- **Tablecloth**, the content store: two superblock slots and an
  append-only log (a commit is one superblock write), public and sealed
  objects (XChaCha20-Poly1305, owner-bound keyed names, Argon2id-wrapped
  master key), Mantra names and tips, generation state. A crash simulator
  cuts the power at every device operation of an upgrade-and-rollback
  scenario. virtio-blk driver; the `tablecloth` domain, unlocked on the
  console; `grain-disk`.
- **Kumara**: an Ed25519 identity made on a disk's first boot and sealed in
  the store, named by three words from a 1024-word bank; signatures bind
  who asked.
- **Ledger**: a signed, sealed, append-only chain; every agent action goes
  there.
- **Aurora** and generations: content-chunked system images, trial boots
  with automatic fallback, `switch_to`/`rollback`, Envoy `upload` with
  deduplication.
- Supporting changes: `DomainInfo.clients`, lifecycle `ready` (Steward
  never blocks on a domain), `await_ready`, optional devices skip their
  domain's clients cleanly, compact images (31 MB to 8 MB), console input,
  an idle heartbeat for QEMU `-icount`.
- Exit, met: upgrade and rollback survive a power cut at every device
  operation in the simulator, and at a trial boot and mid-confirm in QEMU;
  a generation that never comes up is given up; the identity persists
  across reboots, the upgrade and the rollback.

### Cleanup after Phase 5 (done)
- One endpoint per domain, serving several protocols; the receiver learns
  each sender's protocol. Console input is its own service (`input.v1`).
- Tablecloth reclaims space: a circular log, links, retired names,
  `forget` and `reclaim` (agent-driven, and by itself at boot when low).
- Changing the passphrase (`grain-disk passwd`).
- `zig build run` boots through Aurora: each build becomes the current
  generation of the persistent development disk.

### Left over from Phase 5
- Changing the passphrase on the device; a hardware-held key; measured boot.
- Kumara device keys signed by an owner root key; petnames.
- The Ledger for grants, revocations and generation switches made by
  Steward itself (agent actions and the agent's switches are recorded).

## Phase 6: the personal desktop (done)
- virtio-gpu and virtio-input drivers, a compositor domain, a minimal
  widget toolkit, the structured shell as the first graphical app.
- Testing through QMP screendump images and injected input.
- Exit: boot to a desktop; open the shell; every visible element can be
  inspected as typed data through Envoy.
- Built: Surf (the compositor; apps draw typed brushstrokes, `surf.v1`, and
  the whole screen reads back as data, `scene.v1`), the shell, Grain Mono,
  bound signals in the kernel (one thread serves clients and interrupts),
  capability parameters in the IDL, and the harness's `--display` (QMP).
- Exit, met: the desktop test opens the shell from the dock, runs `whoami`,
  clicks a button, and checks every visible element the agent reads through
  Envoy against screenshots.

## Phase 7: the social layer (done)
- virtio-net, a userspace UDP/IP stack, Courier (identity-addressed,
  Noise-encrypted sessions, LAN discovery, friend relays).
- Sturdy references backed by Leases; hosted apps; Granary exchange.
- Exit: two QEMU Grain instances introduce themselves, one hosts an app
  that the other uses, files move between them, then access is revoked.
- Built: signal alarms in the kernel; Mycelium (virtio-net, link-local
  IPv4, ARP, UDP); Noise XX keyed by the identities (Kumara does the
  Diffie-Hellman); Comlink (the owner's name for Courier): LAN discovery,
  sessions, sturdy references backed by kernel leases, remote calls that
  Envoy shows agents as typed capabilities, object transfer by hash, Ledger
  entries; the guestbook; `tools/pair.py`.
- Exit, met: `tools/comlink_session.py`, two instances on one link.
- Left for later: friend relays, persistent shares, petnames and signed
  introductions, sending only missing chunks.

## Phase 8: reach (done, as far as QEMU reaches)
- Native drivers for personal hardware: NVMe, xHCI with USB HID and storage,
  display, Ethernet; then Wi-Fi.
- RISC-V IOMMU; real-board bring-up (an RVA23 board first); aarch64 and
  x86_64 ports running the same suite on QEMU.
- Built: PCI Express in Steward (ECAM enumeration, BAR placement, INTx
  routing; drivers never touch configuration space); manifest devices named
  by class with alternatives (`virtio = 2, pci = nvme`) and `extra` devices;
  NVMe under Tablecloth; the Intel e1000 under Mycelium; a Bochs linear
  framebuffer and xHCI with USB boot keyboards and tablets under Surf; the
  aarch64 port of Caravan (EL1, GICv2, the generic timer, PSCI; the same
  core, the same kernel suite).
- Exit, met: the storage test on NVMe; the two-instance test with one side
  on e1000; the desktop test on bochs-display with USB input; the kernel
  suite on QEMU virt for Arm (Cortex-A72, 2 and 4 cores).
- Not done, and why: the RISC-V IOMMU (QEMU 8.2 has no model; the design is
  in ARCHITECTURE §3.6); real boards (none at hand); x86_64 (next port: the
  arch interface and the user-side `cpu.zig` are where it goes); USB mass
  storage; Wi-Fi; Aurora reading generations from NVMe; Steward and the
  full system on Arm (they are portable; the Arm system needs PCI interrupt
  routing for GIC specifiers and a pass of the system tests).

## Phase 9: hardening (done, except what needs people or hardware)
- Fuzzing of every kernel entry point; model checks of IPC and revocation;
  measured boot; performance work on RVA23 hardware; an external review of
  the capability model.
- Built: fuzz targets for every kernel entry (system calls with any
  registers, faults, interrupts, time, boot data) and every parser of input
  someone else controls, run by Zig's coverage-guided fuzzer or as seeded
  sweeps in `zig build test` (fuzz/); a model checker that tries every order
  of every call in seven IPC and revocation scenarios on the real core
  (`zig build model`); measured boot from Aurora through the kernel, Steward,
  every domain and the Ledger, with attestations signed by the identity
  (`attest.v1`) and checked by an independent implementation; a direct
  hand-off for IPC and yield (−8% on the round trip, −11% on yield);
  generations that never come round; docs/CAPABILITY_MODEL.md, the brief for
  a reviewer.
- Found and fixed: integer overflows in the device-tree parser (the kernel
  runs it at boot) and the boot-image parser; a device-tree offset past the
  end; BAR sizes from a device that answers a mask with holes (Steward
  would have hit an assertion); the xHCI descriptor walk reading past a
  descriptor; Aurora's overlap check overflowing on a hostile descriptor.
- Not done, and why: the external review itself (it needs reviewers; the
  brief is ready); performance work on RVA23 hardware (none at hand: the
  work was done in instructions retired under QEMU and in a callgrind
  profile of the core); a hardware root for measured boot.

## Next: Grain in a browser (in progress)
- A static site (GitHub Pages) where the system runs in the page, with a
  choice of manifests and machine settings, built and published by CI.
- Built: `grain-emu` (`emu/`, ARCHITECTURE §3.10), an emulated RISC-V
  machine that boots the same images as QEMU: the kernel suite, the dev
  system, storage, Aurora and agent sessions pass on it.
- Built: the WebAssembly build and the terminal page (docs/WEB.md): the
  console, grainsh over Envoy, the system log, the disk kept in browser
  storage, three setups; tested in headless Chromium; the CI workflow that
  builds, tests and publishes it.
- Next: the public Pages repository and its deploy key (the owner's to
  create, docs/WEB.md); virtio-gpu and virtio-input in the emulator (the
  desktop on a canvas).

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
