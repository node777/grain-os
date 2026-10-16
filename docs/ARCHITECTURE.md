# Grain OS architecture (draft 0)

> **Status:** proposal. Names other than *Grain* and *Caravan* are working
> titles.
>
> **Owner decisions (2026-10-16):** Grain is a **personal-device** OS first.
> *Social* means every instance has a shareable cryptographic identity, used
> to move data, host applications and connect with other people's instances
> (inspired by Urbit). There is **no compatibility layer**: no Linux guest, no
> POSIX. Everything is native, and hardware is reached through native drivers.

## 1. What Grain is

Grain is a capability operating system built around three claims:

1. **The system is a value.** A Grain system is fully described by a
   declarative *manifest*. Building the manifest gives a content-addressed,
   reproducible image (as in NixOS). What runs is exactly what was declared,
   and every change is a transaction you can roll back.
2. **Authority is explicit and owned.** Nothing can act unless it holds a
   capability. All authority starts with the owner and is delegated in
   narrow, revocable slices to programs, people and AI agents (as in seL4 and
   object-capability systems).
3. **The kernel is a deterministic state machine.** All nondeterminism
   (interrupts, time, entropy, device input) enters through one recorded
   door. The same history gives the same state, on hardware or in a simulator
   (as in TigerBeetle's deterministic simulation testing).

### The five qualities, as engineering constraints

| Quality | What it means in the design |
|---|---|
| **Intimate** | Local-first. The owner's data lives on the owner's device, encrypted with keys the owner holds. The OS keeps a rich, private context about its owner (files, history, preferences) and shares none of it without a capability grant. |
| **Social** | Every Grain instance has its own cryptographic identity (a *Seal*) that its owner can share. Instances address each other by identity, not by IP. Sharing is handing someone a capability, not editing ACLs. Capabilities cross instances as signed *sturdy references* with local *petnames*. Apps are hosted on the owner's own instance, and friends reach them there. |
| **Secure** | No ambient authority. A minimal kernel (target under 10k lines of Zig). Drivers and services are unprivileged and isolated by the MMU and, later, the IOMMU. Measured boot of a content-addressed image. Static allocation in the kernel. |
| **Clear** | Every interface is typed and self-describing. Every authority-changing event goes into an append-only, hash-chained *Ledger*. Every change has a plan you can preview, then an apply, then an undo. The kernel's own output is structured records. |
| **Loyal** | The OS serves its owner only. No hidden authority for vendors. Updates are content-addressed and applied only with the owner's approval. Agents act only through leases the owner granted, and the owner can see everything they did. |

## 2. Caravan, the microkernel

Caravan does five things and nothing else: **capabilities, memory,
execution, IPC, and the event door.** Everything else, drivers included, runs
in userspace domains.

### 2.1 Kernel objects

| Object | Purpose |
|---|---|
| `Untyped` | A range of physical memory that can be retyped into other objects. The only source of kernel memory. |
| `CNode` | A table of capability slots. A domain's CSpace is a tree of CNodes. |
| `Domain` | The unit of isolation: a CSpace, an address space and one or more threads. (seL4 keeps these separate; Grain groups them so the manifest stays readable. Threads can still be separate objects.) |
| `Thread` | Register state plus a binding to a scheduling context. |
| `AddressSpace` / `PageTable` / `Frame` | Sv39/Sv48 paging. Mapping a frame needs a capability to both the frame and the page table. |
| `Endpoint` | Synchronous call/reply IPC rendezvous. |
| `Signal` | An asynchronous notification word (seL4 notifications): OR in bits, wait for any. Interrupts arrive as signals. |
| `Channel` | A shared-memory ring pair (submission and completion, as in io_uring) plus a signal, for bulk and streaming data. The kernel only sets it up and wakes waiters; data never goes through the kernel. |
| `SchedContext` | A CPU-time budget and period (seL4 MCS). Time is a capability. |
| `Irq` | The right to receive a specific interrupt line as a signal. |
| `Lease` | A revocable forwarder to another capability (§2.3). |

### 2.2 Capabilities

A capability is 16 bytes:

```
object index : u32   which kernel object (index into a typed object table)
generation   : u32   must equal the object's current generation
rights       : u16   read / write / grant / call / map / retype / ...
protocol     : u16   interface-schema id the holder expects (endpoints)
badge        : u32   holder-chosen identifier delivered with each message
```

- **Unforgeable** because capabilities live only in kernel-owned CNodes.
  Userspace names them by slot index.
- **Attenuation:** `mint` makes a copy with fewer rights, a badge, or a
  protocol binding. Rights can only shrink.
- **Typed endpoints:** an endpoint capability can carry the id of the
  interface schema it speaks (§3.2). The kernel never parses messages, but
  it checks that sender and receiver agree on the protocol id, which costs
  one compare. This catches wiring errors at the boundary, and it lets an
  agent ask a capability *what it is*.

### 2.3 Revocation: generations and leases, no derivation tree

seL4 tracks every derived capability in a derivation tree so they can be
revoked. Caravan does not:

- **Destroying an object bumps its generation.** Every capability to it,
  wherever it is, is now stale and fails on use. Revocation is O(1).
- **Selective revocation uses leases.** To hand out authority you might want
  back, mint a `Lease` object that forwards to the capability, and hand out
  capabilities to the lease. Revoking the lease bumps *its* generation:
  everyone who got authority through it loses it, and nobody else does. This
  is the caretaker pattern from KeyKOS and E, built into the kernel.
- **Leases can carry limits** (an expiry tick and a use count), checked when
  invoked. This is how an AI agent gets authority for "this task, this hour".
- Cost: one generation compare per invocation, plus one extra lookup when a
  lease is used. In exchange, the hardest part of seL4's bookkeeping goes
  away, and so does unbounded revocation latency.

### 2.4 Memory

- **No kernel heap.** At boot, Caravan sizes its fixed tables from the boot
  manifest and turns all remaining RAM into `Untyped` capabilities given to
  the root domain. After that the kernel never allocates. Creating an object
  means retyping untyped memory that the caller supplies, so a domain's
  kernel footprint is charged to that domain.
- **Kernel mapping:** the kernel maps all of physical memory at a fixed
  higher-half offset (Sv39 makes this cheap) and has its own address space
  per hart for per-core data.
- **Userspace pagers:** page faults are delivered as IPC to the faulting
  domain's fault endpoint. The kernel itself does no demand paging, swapping
  or copy-on-write. Those are services.

### 2.5 Execution and scheduling

- **Per-hart kernels, shared nothing on the fast path** (Barrelfish
  multikernel). Each hart has its own run queues and kernel stack. Moving a
  thread between harts, or signalling a remote hart, is an explicit message
  through an IPI. There is no global kernel lock.
- **MCS scheduling:** a thread runs only with a `SchedContext` (budget and
  period). A call to a passive server can lend the caller's SchedContext, so
  servers run on their clients' time and can't be used for denial of
  service.
- **Two scheduling modes, chosen in the manifest:** *priority with budgets*
  (general purpose), and a *static time-partitioned table* (fully
  deterministic, for real-time or replay-critical systems).

### 2.6 IPC

- `call(cap, msg)` / `reply_recv(msg)`: synchronous, register-based
  fastpath. On RISC-V, a0 to a7 carry the capability, a message tag and six
  words. Longer messages use a per-thread IPC buffer page. Up to four
  capabilities can be transferred per message (as in Zircon channels).
- `signal(cap, bits)` / `wait(cap)`: asynchronous.
- `Channel`: setup and wakeups only. Data stays in shared rings.
- Target: under 300 cycles for a register-only call/reply round trip on
  RVA23-class cores.

### 2.7 The event door (determinism)

Everything nondeterministic is turned into an `Event` by architecture code
and passed to one portable function:

```
core.step(state, event) -> effects
event  = irq(line) | timer(tick) | trap(thread, cause) | syscall(thread, args) | ipi(from, msg)
effect = switch_to(thread) | program_timer(t) | send_ipi(hart, msg) | ...
```

- Architecture code (`arch/riscv64`, later `arch/aarch64` and `arch/x86_64`)
  only translates hardware into events and effects into hardware.
- `core/` is plain Zig with no hardware access. The build enforces this:
  it is a separate module that can't import `arch/` (already true in this
  repository). The exact same core runs:
  - on hardware,
  - in **QEMU**,
  - in a **host simulator** (`zig build sim`) that feeds it seeded random
    event streams and checks invariants after every step, the way
    TigerBeetle's VOPR does.
- **Record and replay:** in *ledger mode* the kernel logs every event with its
  ordinal. Replaying the log reproduces the kernel state exactly. Together
  with deterministic userspace scheduling, the whole system can be replayed,
  which is useful for debugging and for audits ("what exactly did the agent
  do?").

### 2.8 Syscall surface (target)

About 12 calls: `call`, `reply_recv`, `send`, `recv`, `signal`, `wait`,
`yield`, and `invoke(cap, op, args)` for object methods (retype, mint, map,
revoke, configure). Each object method is described by a schema, so the
syscall surface is self-describing too.

## 3. Grain, the system above the kernel

```
┌──────────────────────────────────────────────────────────────────┐
│ apps · agents (via Envoy) · structured shell · desktop           │
├──────────────────────────────────────────────────────────────────┤
│ Seal (identity) · Courier (identity-addressed network)           │
├──────────────────────────────────────────────────────────────────┤
│ Envoy (agent interface) · Registry (schemas) · Ledger (audit)    │
│ Granary (content-addressed store) · Steward (manifest, lifecycle)│
├──────────────────────────────────────────────────────────────────┤
│ drivers (virtio-console/blk/net/gpu/input/rng; native later)     │
├──────────────────────────────────────────────────────────────────┤
│ Caravan: caps · memory · threads · IPC · event door              │
├──────────────────────────────────────────────────────────────────┤
│ arch: riscv64 (first) · aarch64 · x86_64   │   firmware: SBI/UEFI│
└──────────────────────────────────────────────────────────────────┘
```

### 3.1 Manifest, Steward, generations (from NixOS)

- The **manifest** (`grain.zon`, Zig Object Notation) declares domains,
  their binaries (by content hash), memory budgets, scheduling contexts, the
  capabilities each one gets, and how they are wired together.
- **The manifest is checked at compile time.** `zig build` imports it and
  checks, at `comptime`, that every wire connects compatible protocols, that
  no domain gets rights it shouldn't, and that memory budgets fit. A badly
  wired system doesn't build.
- **Steward** (the root domain) holds the initial capabilities, starts the
  domains the manifest lists, supervises and restarts them (Hubris-style),
  and does nothing else.
- **Generations:** a built system is a closure in the Granary, named by its
  hash. Boot loads the current generation and measures it. Upgrades build a
  new generation and switch atomically; rollback switches back. Boot always
  offers the last known-good generation.
- **Static core, dynamic edge:** the base system is fully static, like
  Hubris and Microkit. Dynamic behaviour (installing apps, starting agents)
  happens through a *spawner* service that holds an explicit untyped budget,
  so dynamism is itself a capability the manifest grants.

### 3.2 Typed interfaces and the Registry

- Interfaces are defined **as Zig declarations** (structs and enums with doc
  comments) in `grain/proto/`. `comptime` generates client stubs, server
  dispatch, and serialisation, plus a machine-readable descriptor: names,
  types, docs, required rights, and whether a call is pure, idempotent or
  undoable.
- A protocol's id is a hash of its descriptor. That is the id the kernel
  checks on endpoints (§2.2).
- The **Registry** service maps protocol ids to descriptors, so any holder of
  a capability can ask what it does and how to call it. This is FIDL's idea
  with Zig as the IDL, and it is what lets an AI operate the system without
  guessing.

### 3.3 Ledger

- An append-only, hash-chained log of authority events: grants, leases,
  revocations, generation switches, agent actions, and (in ledger mode)
  kernel events.
- Owner-readable, tamper-evident, exportable. This is where "clear" and
  "loyal" come from: you can always answer *who did what, with whose
  authority*.

### 3.4 Granary

- A content-addressed object store (BLAKE3, which is in Zig's standard
  library) for binaries, manifests, generations and user data.
- Encrypted at rest under owner keys. Deduplicated. Snapshots are free.
- Files are named by hash and given petnames in per-owner namespaces. There
  is no global filesystem namespace; a domain sees only the directories it
  holds capabilities for.

### 3.5 Envoy: the AI interface

Envoy is how an AI agent (or a script, or a human) operates Grain. An agent
is a **principal** with its own leased capabilities. It is never root.

| Verb | Meaning |
|---|---|
| `discover` | List the capabilities I hold, with their schemas (via the Registry). |
| `describe` | Full typed descriptor of one capability or object. |
| `plan` | Dry-run a set of calls or a manifest change. Returns the effects, the authority it would use, and a diff. Nothing changes. |
| `apply` | Run a plan as one transaction. All of it happens or none of it does, and it is recorded in the Ledger. |
| `observe` | Subscribe to typed events and Ledger entries within my authority. |
| `undo` | Reverse an undoable transaction, or roll back a generation. |
| `ask` | Request more authority. The request goes to the owner, who can grant a lease with limits. |

- **Transport:** at first, a framed protocol on a virtio-console port (which
  is also how this repository's test harness drives the OS). Later, a local
  socket and the network, with an **MCP bridge** that projects Registry
  descriptors into MCP tools automatically.
- **Structured shell:** the human shell uses the same verbs and works on
  typed records (like Nushell or PowerShell), so what a human sees and what
  an agent sees are the same data.

### 3.6 Drivers and hardware

- Drivers are unprivileged domains holding `Irq`, MMIO `Frame` and DMA
  capabilities. Once the IOMMU is in use, a driver can DMA only into memory
  it was granted.
- **virtio first** (console, block, net, rng, gpu, input). This covers QEMU
  and most cloud VMs on every architecture.
- **Native drivers only** (owner decision: no compatibility layer). For a
  personal device that means, in order: virtio (all of QEMU), then NVMe,
  xHCI USB with HID and mass storage, a framebuffer and GPU display path,
  Ethernet, and later Wi-Fi. Each is an isolated domain, so an untrusted or
  buggy driver can't hurt the rest of the system.
- **Ports:** `arch/` is a small interface (boot entry, trap entry and exit,
  page-table format, timer, IPI, interrupt controller, context switch).
  RISC-V gets first-class optimisation (Sv48, Svpbmt, AIA/IMSIC, Zicbom,
  vector state handled lazily); aarch64 and x86_64 follow the same
  interface.

### 3.7 Seal and Courier: identity and the social layer

Each Grain instance is a personal server as well as a personal computer.

- **Seal (identity).** At first boot the instance creates an Ed25519 *root
  identity key*, which the owner keeps. It signs short-lived *device keys*, so
  keys can rotate and a lost device can be cut off without losing the
  identity. The identity's public key *is* the identity. There is no
  registry, no blockchain and no scarcity.
- **Names.** Every identity has a pronounceable name derived from its key
  hash (like Urbit's `~sampel-palnet`), so people can say and check it. On
  top of that, each owner keeps *petnames* for the identities they know.
  Names are local and can't be hijacked.
- **Introductions and recovery.** People vouch for each other by signing
  introductions (a web of trust, not an authority). Optional *social
  recovery*: the root key can be split into threshold shares held by trusted
  friends' instances.
- **Courier (network).** Messages go *to identities*. Courier keeps the map
  from identity to current network routes (direct, LAN discovery, or relays
  run by friends) and opens end-to-end encrypted sessions (a Noise IK
  handshake over UDP). Changing networks never changes who you are.
- **Capabilities across instances.** A local capability can be exported as a
  *sturdy reference*: signed by the issuing Seal, naming the recipient's
  identity, and backed by a local `Lease`. So remote access can be revoked,
  and has an expiry and use count, exactly like local access. Courier turns
  calls on a sturdy reference into IPC on the issuing instance.
- **Hosted apps.** An app runs on its owner's instance and is shared by
  handing friends a capability to its interface. Their Envoy and shell reach
  it through Courier with the same typed descriptors as local services. Data
  transfer is a Granary object exchange: hashes are verified on arrival, and
  only missing blocks are sent.
- **Loyalty across the network.** Every remote grant and use goes into the
  Ledger. Owners can see who holds what, and revoke it.

## 4. Where Grain departs from its inspirations

| From | Kept | Changed |
|---|---|---|
| seL4 | Capabilities, untyped retype, no kernel heap, call/reply fastpath, MCS | No derivation tree: generations and leases instead; typed endpoints; domains group CSpace and VSpace; a structured, self-describing API. |
| Microkit / Hubris | Static, build-time composition; one attestable image | Manifest checked at `comptime`; a dynamic edge granted as a capability. |
| Zircon | Handles passed in messages; one IDL for everything | Zig itself is the IDL; protocol ids checked by the kernel; a much smaller kernel. |
| NixOS | Declarative system, content addressing, generations, rollback | Applies to the whole OS including the kernel's capability graph; plain data, not a language. |
| Linux | io_uring rings | Rings as a kernel object. No Linux code or ABI. |
| Urbit | Each person runs their own instance; identity is the network address; the OS as a function of its event log; apps hosted on your own node | Self-issued keys instead of scarce blockchain identities; native Zig instead of Nock/Hoon; standard crypto and transports underneath (§3.7). |
| TigerBeetle | Deterministic simulation; static allocation; Zig | Applied to a kernel: one event door, record and replay. |

## 5. Explicit non-goals (for now)

- Compatibility with Linux or POSIX in any form (owner decision). Software
  is written for Grain.
- A formal proof of the kernel. The design aims to make one *possible*
  (small, static, a pure core), and uses simulation, property tests and model
  checking until then.
- Hard real-time certification.
