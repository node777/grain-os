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
in userspace.

> **Status (Phase 2):** everything in this section is implemented and tested
> unless marked *planned*. Where the build differs from the first draft of this
> design, the text says so and why. The ABI is `caravan/abi/abi.zig`, and the
> core is `caravan/src/core/kernel.zig`.

### 2.1 Kernel objects

| Object | Purpose |
|---|---|
| `Untyped` | A range of physical memory that can be retyped into other objects. The only source of kernel memory. Device untypeds (MMIO) can only become frames. |
| `CNode` | A table of 2^n capability slots. A thread's CSpace is one CNode for now (multi-level lookup is *planned*). |
| `Thread` | Saved registers, a CSpace, an address space, an optional fault endpoint and IPC buffer, a priority and a maximum controlled priority. |
| `PageTable` | One Sv39 table at a fixed level (given when created). A top-level table *is* an address space: its methods map frames and link tables. |
| `Frame` | 4 KiB, 2 MiB or 1 GiB of memory (RAM or device). |
| `Endpoint` | Synchronous IPC rendezvous (call/reply, send/recv). |
| `Signal` | An asynchronous notification word (seL4 notifications): OR in bits, wait for any. Interrupts arrive as signals. |
| `SchedContext` | A CPU-time budget and period on one hart (seL4 MCS). Time is a capability. |
| `Lease` | A revocable, limited forwarder to another capability (§2.3). |
| `Irq` | The right to receive one interrupt line as a signal. |
| `IrqControl`, `SchedControl`, `DebugConsole` | Boot singletons: the authority to create Irqs, to give contexts budgets, and (for bring-up) console output and power-off. |
| `Channel` | *Planned:* shared-memory rings plus a signal, for bulk data. |

*Change from the first draft:* there is no `Domain` object. As in seL4, a
thread names its CSpace and address space directly, and threads can share
them. "Domain" stays a manifest-level idea (Phase 3): a group of threads,
spaces and capabilities that Steward creates together.

### 2.2 Capabilities

A capability is 16 bytes, stored only in kernel-owned CNodes:

```
object index : u32   which entry in the object table
generation   : u32   must equal the entry's current generation
rights       : u16   read write execute grant send recv revoke configure retype
protocol     : u16   interface id (carried, not yet checked — planned with Phase 4)
badge        : u32   delivered to the receiver with every message or signal
```

- **Unforgeable:** userspace names capabilities by slot index only.
- **Attenuation:** `CNode.mint` copies a capability with a subset of its
  rights, and can set a badge once. Rights only shrink.
- **Introspection:** `CNode.identify` returns the kind, rights, badge, the
  kind *behind* a lease, and the object id; `CNode.lease_info` returns a
  lease's remaining uses and expiry. Agents can ask any slot what it is.
- **The object table** has one 32-byte entry per object, allocated once at
  boot (about one entry per 4 KiB of RAM, so 0.8% overhead). Generations
  live in the table, not in the object's memory, so they survive memory reuse.

### 2.3 Revocation: generations and leases, no derivation tree

seL4 tracks every derived capability in a derivation tree. Caravan does not.

- **`CNode.revoke(slot)` bumps the object's generation.** Every other
  capability to it, anywhere, becomes invalid at once; the revoking slot gets
  a fresh one. Threads queued on a revoked endpoint or signal are woken with
  `aborted`; a revoked frame is unmapped. **O(1) apart from that cleanup.**
- **Selective revocation uses leases.** `Lease.arm(target, rights,
  duration, uses)` makes a lease forward to a capability. Copies of the lease
  capability act as the target, with at most the lease's rights, until the
  duration passes, the uses run out, or the owner revokes the lease. This is
  the caretaker pattern from KeyKOS and E, in the kernel.
- **Capabilities the kernel keeps for a thread** (fault endpoint, IRQ
  signal) are stored unresolved and resolved through leases on every use, so
  revoking a lease cuts them off too.
- **Known limit:** a lease controls *invocations*. An effect that outlives an
  invocation, such as a mapping made through a leased frame capability or a
  scheduling context bound through one, is not undone when the lease ends.
  To take that back, revoke the underlying object instead.
- **Memory is reclaimed by `Untyped.reset`,** which destroys every object
  made from the region (recursively, iteratively, cost proportional to the
  number of objects) and undoes each one's relationships: dequeues threads,
  aborts waiting callers, returns lent contexts, unmaps frames and tables,
  and stops harts running a destroyed thread or address space.

### 2.4 Memory

- **No kernel heap.** At boot Caravan parses the device tree, places the
  object table and the root untyped headers in free RAM, turns the rest of
  RAM into untyped regions, and makes device untypeds from device-tree MMIO
  ranges (excluding the interrupt controller and timer). After boot, every
  kernel object lives in memory a caller retyped.
- **Untyped regions allocate from both ends:** page-aligned payloads (frames,
  tables, big CNodes, child regions) from the bottom, small bodies (threads,
  endpoints, signals, contexts, leases) from the top, so alignment wastes
  nothing. Each region also has an **object budget** (one object per 4 KiB of
  its size), so nobody can exhaust the global object table with tiny objects.
- **Page tables carry a shadow array** naming the object mapped or linked at
  each slot (a table is 8 KiB: 4 KiB of PTEs, then the shadow). Frames and
  tables record where they are mapped. Destroying either side finds and
  clears the other. *Limit:* a frame object is mapped in one place; sharing
  memory between address spaces needs frame aliases (*planned*, with channels).
- **Kernel mapping:** the kernel is linked at `0xffffffff80200000`, and all
  physical memory is mapped at `0xffffffc000000000`, both with 1 GiB pages
  built by the boot code. New root tables copy the kernel half.
- **Faults go to userspace:** page faults and exceptions become messages on
  the thread's fault endpoint (kind, address, pc). The handler can map memory
  and reply to retry, or reply with a new pc. With no handler the thread stops,
  and the kernel logs a `thread_fault` record.

### 2.5 Execution and scheduling

- **MCS scheduling contexts:** a thread runs only on a configured context
  (budget ≤ period, on one hart). The running thread is charged at every
  kernel entry, and exhaustion is handled right there, whatever the thread
  goes on to do in that entry. A full-bandwidth context (budget = period)
  refills and its thread goes to the back of its queue; any other context is
  throttled and placed on its hart's release list until the next refill. Refills follow a simple
  periodic rule; seL4's sporadic-server refills are *planned*.
- **Donation:** a call to a passive server (one with no context of its own)
  lends the caller's context. The reply gives it back. Servers run on their
  clients' time.
- **Priorities 0–255** with a per-thread *maximum controlled priority*, so a
  thread can lower itself and later restore itself.
- **Per-hart run queues** with a priority bitmap. A context's hart decides
  where its thread runs.
- **Timer programming is lazy:** the hardware timer only moves earlier. An
  early timer interrupt is a cheap no-op, and it saves a firmware call on
  almost every kernel entry.
- *Change from the first draft:* SMP uses **one kernel lock** (as seL4 does)
  rather than shared-nothing per-hart kernels. Kernel entries are short and
  non-preemptible. Other harts are told to reschedule with IPIs ("kicks").
  The hart holding the lock waits until any kicked hart running user code
  has trapped, so no hart keeps running a thread the kernel took away.
  Destroying an address space makes every hart leave that root table before
  the call returns. A multikernel design stays the long-term direction.
- *Planned:* a static time-partitioned scheduling mode for fully
  deterministic systems.

### 2.6 IPC

- `call`, `send`, `recv`, `reply_recv`, `reply`: a message tag and five
  words travel in registers. Up to 64 words go through the thread's IPC
  buffer page. Up to four capabilities move per message if the sender's
  endpoint capability has the `grant` right.
- The reply relationship is implicit (one outstanding caller per server). A
  server that takes a new call without replying aborts the old caller.
- `signal`, `wait`, `poll` on signals. An `Irq` bound to a signal sets the
  signal's badge bits, and stays masked until `Irq.ack`.
- **Measured** (QEMU, one hart, ReleaseFast, instructions retired including
  user code): null system call about 690, minimal object method about 740,
  call/reply round trip to a passive server about 2,100. A register-only fastpath that
  skips the general scheduler (like seL4's) is *planned*. The target is
  still a few hundred cycles per round trip on real RVA23 cores.

### 2.7 The event door (determinism)

Architecture code turns hardware into events and calls one portable entry
point:

```
kernel.handle(hart, now, event)        event = syscall | fault | timer | irq(line) | ipi
kernel.currentThread(hart)             what that hart should run next (or idle)
```

- Every effect goes through a small comptime interface (`A` in kernel.zig):
  set a timer, mask an IRQ, flush the TLB, retire a root table, write the
  console. Time is an argument, never read by the core. Power-off is a
  request (`exitRequested`) that arch code carries out.
- `core/` can't import `arch/`, and the build enforces it. The same core runs:
  - **on QEMU riscv64** (and, later, hardware);
  - **in host scenario tests** (`sim/kernel_test.zig`) that act as user
    threads by setting registers and calling `handle`;
  - **in `caravan-sim`**, which feeds the core seeded random events and
    checks `checkInvariants()` (queues, states, reply links, contexts,
    mappings, untyped watermarks, free list) after every step. Any seed
    replays bit-for-bit, and each run is executed twice to prove it.
- QEMU runs use `-icount`, so a whole-system boot, SMP included, gives
  byte-identical output every time.
- *Planned:* ledger mode (record every event in order, for replay and audit).

### 2.8 System calls

Ten calls: `call`, `send`, `recv`, `reply_recv`, `reply`, `signal`,
`wait`, `poll`, `yield`, and `invoke(cap, method, args)` for object methods.
Methods, error codes, thread states and fault kinds are named enums in the
ABI file, so a person or an agent can read the whole contract in one place.

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

### 3.1 Manifest, image, Steward (from NixOS, Hubris and Microkit)

> **Status (Phase 3):** implemented and tested, except generations and the
> spawner, which are marked *planned*.

**The manifest** (`system/*.zon`, typed by `grain/manifest/schema.zig`) is
plain data. It lists domains, and for each one: its program, kind (`service`
or `task`), priority, hart, CPU budget and period, memory, restart policy,
the services it provides (name and protocol), the services it uses
(`"<domain>.<service>"` and the protocol it expects), its devices (by virtio
id), and whether it gets a write-only debug console.

```zig
.{ .name = "hello", .program = "hello", .kind = .task,
   .uses = .{ .{ .name = "console", .from = "console.console", .protocol = "console.v1" },
              .{ .name = "entropy", .from = "rng.entropy", .protocol = "entropy.v1" } } },
```

**One validator, two places.** `schema.validate` checks names, uniqueness,
that every use resolves to a provider, that protocols match, priority
ranges, budget ≤ period, memory sizes, known device ids, that each hart
promises at most 90% of its time, and that no cycle of synchronous calls
exists (which could deadlock). It returns one sentence naming the problem.
Steward runs it **at compile time**, so a miswired system does not build:

```
error: system manifest: domain 'hello' uses 'console.consol', but no domain provides it (write it as "<domain>.<service>")
```

and host tests run it at run time, so every message is tested.
`zig build check-manifest -Dsystem=<file>` runs the compile-time check on
its own.

**The boot image** (`grain/manifest/image.zig`, written by `tools/pack`)
holds the manifest text and every program it names, each with its BLAKE3
hash, plus a **closure hash** over the manifest's hash and every
(name, hash) pair. The closure hash names the whole system, as a NixOS
store path does: the same inputs give the same hash. Steward recomputes
every hash at boot and refuses to start if any differs.

**Steward** is the root task. It:

1. Verifies the image and reports `steward_start closure=… verified=true`.
2. Finds `virtio,mmio` transports in the device tree (the kernel copies the
   DTB into the root task), probes each one's device id, and keeps their
   MMIO frames. It creates an `Irq` the first time a device is assigned.
3. Creates one endpoint per provided service *in its own memory*, so the
   endpoint outlives the provider's restarts.
4. Builds each domain in a **private untyped region** sized from the
   program, stack, tables and the manifest's `memory_kib`. That covers the
   CNode, root page table, program pages (copied through a scratch window),
   stack, IPC buffer, a `DomainInfo` page, a child untyped of `memory_kib`
   for the domain's own use, a scheduling context with the manifest's
   budget, and the thread. Each object is charged to the domain's region.
5. Wires capabilities with badges. A client gets its provider's endpoint
   with send and grant rights, badged with the client's number, so servers
   know who is calling. The provider gets receive rights. Drivers get
   their MMIO frame (mapped at a fixed address) and their `Irq`.
6. Serves the **lifecycle endpoint**. Tasks call it to exit with a code.
   Faults arrive on the same endpoint with a fault badge. A faulting domain
   is torn down by resetting its region, which destroys everything it was
   made of in one call. If its policy is `on_fault` and it is under
   `max_restarts`, it is rebuilt from its image (`DomainInfo.restart_count`
   tells it which run this is). Otherwise it is stopped, and **its
   endpoints are revoked**, so clients waiting on it are woken with
   `aborted` and later calls fail with `invalid_cap` instead of hanging.
7. With `halt_when_tasks_finish`, it prints one `domain_status` record per
   domain and a `summary` once every task has finished, then powers off.

**The domain contract** (`grain/lib/domain.zig`): fixed capability slots
(the domain's own CNode, address space, thread, memory and lifecycle
endpoint, then uses at 16+, provides at 24+, devices at 32+), fixed
addresses (program at 0x10000, devices at 0x7000_0000, `DomainInfo` at
0x7ff0_0000, stack below 0x7fff_0000), and the `DomainInfo` page, which
names everything the domain was given: its uses and provides with
protocols and slots, its devices with MMIO address, IRQ line and slots,
its program hash and the system's closure hash. Programs look things up by
name (`grain.use("console")`, `grain.device("port")`). Nothing is wired by
an unwritten convention.

- *Planned (Phase 5):* **generations.** Keep built closures in the Granary,
  switch between them atomically, and roll back to the last known-good one.
- *Planned:* a **spawner** service with an explicit untyped budget, so
  dynamic programs (apps, agents) are a capability the manifest grants
  rather than an exception to it.

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
  and most cloud VMs on every architecture. *Built:* the modern (1.x)
  virtio-mmio transport and split virtqueues in `grain/lib/virtio.zig`;
  `virtio_console` (one port, with per-client line buffering so concurrent
  writers never tear each other's lines) and `virtio_rng`. Drivers program
  DMA with physical addresses from `Frame.info`. Until the IOMMU is in use,
  a driver with a DMA-capable device is trusted with memory; that is the
  main reason drivers are separate domains with their own regions.
- *Changed from the plan:* the Envoy channel will be a **second
  virtio-console device** rather than a second port of the first one.
  Multiport needs a control queue; two devices are simpler and just as
  isolated.
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
