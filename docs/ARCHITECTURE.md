# Grain OS architecture (draft 0)

> **Status:** proposal. Names other than *Grain* and *Caravan* are working
> titles; [GLOSSARY.md](GLOSSARY.md) maps the owner's proposed names onto
> them (code keeps the current names until the rename after Phase 4).
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
protocol     : u16   interface id: an endpoint delivers only between matching ids
badge        : u32   delivered to the receiver with every message or signal
```

- **Unforgeable:** userspace names capabilities by slot index only.
- **Attenuation:** `CNode.mint` copies a capability with a subset of its
  rights, and can set a badge once and a protocol id once. Rights only shrink.
- **Protocol checks:** an endpoint refuses a message whose sender's protocol
  id differs from the waiting receiver's (both nonzero), with
  `protocol_mismatch`; a queued sender is refused the same way when the
  receiver arrives. Steward stamps the low 16 bits of the IDL hash (§3.2) on
  every endpoint it hands out, so a client built against `kv.v1` cannot
  talk to a server serving `echo.v1`, whatever slot it was given.
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
- **TLB shootdowns are targeted.** A page-table change flushes only harts
  whose *active* root is the root the changed table hangs under; a table not
  yet linked to any root needs no flush at all. That is sound because
  switching roots flushes the hart's TLB (there are no ASIDs yet) and roots
  only change under the kernel lock. *Measured:* this took the dev system's
  boot under two harts from timing out at 60 s (every page Steward copied
  cost a remote fence to a hart that had nothing to flush) to a few seconds.
- **Logical harts.** Hart 0 is whichever hart firmware booted on (SBI may
  pick any); the others follow in device-tree order. Manifests and the core
  see only logical indices, and external interrupts go to hart 0.
- **Idle heartbeat.** When every hart is idle and no timer is armed (all
  threads wait on devices), the arch layer arms a 10 ms timer. Under QEMU
  `-icount` a machine in that state never receives the host's I/O
  completion (a disk flush waited forever); a pending deadline keeps QEMU's
  clock and I/O moving. On hardware it is one interrupt per 10 ms of total
  idleness.
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

The debug console's `write` takes up to 32 bytes in registers, or up to 512
(`abi.max_debug_write`) from the caller's IPC buffer, and writes each call
whole. libgrain formats a record line and writes it in one call, so records
from different harts never interleave — the harness parses lines, and a torn
line is a lost record.

## 3. Grain, the system above the kernel

```
┌──────────────────────────────────────────────────────────────────┐
│ apps · agents (via Envoy) · structured shell · desktop           │
├──────────────────────────────────────────────────────────────────┤
│ Seal (identity) · Courier (identity-addressed network)           │
├──────────────────────────────────────────────────────────────────┤
│ Envoy (agent interface) · Registry (schemas) · Ledger (audit)    │
│ Tablecloth (content store) · Steward (manifest, lifecycle)       │
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

**The manifest** is written in **Brix** (`system/*.brix`, see
[BRIX.md](BRIX.md)) and evaluates to plain data typed by
`grain/manifest/schema.zig`. The build runs `brix` to check it and write that
data as ZON, which grain-pack hashes and Steward embeds. It lists domains, and for each one: its program, kind (`service`
or `task`), priority, hart, CPU budget and period, memory, restart policy,
the services it provides (name and protocol), the services it uses
(`"<domain>.<service>"` and the protocol it expects), its devices (by virtio
id and `instance`, counting devices of that kind in device-tree order; a
device marked `optional` that the machine lacks makes Steward skip the
domain with `domain_skipped` instead of failing it), and whether it gets a
write-only debug console. An optional `agent` section says what an AI agent
may hold (§3.5).

```brix
domain hello {
    program = hello
    kind = task
    uses console { from = console.console, protocol = console.v1 }
    uses entropy { from = rng.entropy, protocol = entropy.v1 }
}
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

and `brix` and the host tests run it at run time, so every message is
tested. Through `brix`, a message points at the block it names
(`miswired.brix:12:1: domain 'hello' uses ...`).
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
0x7ff0_0000, the manifest's `stack_kib` of stack below 0x7fff_0000), and the `DomainInfo` page, which
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

> **Status (Phase 4):** implemented and tested.

- Interfaces are defined **as Zig declarations** in `grain/proto/` (`console`,
  `entropy`, `echo`, `kv`, `registry`). Each method is
  `idl.Method(.{ .label, .effect, .doc, .undo }, Params, Results)` with
  per-field docs. Field types are integers, bools, enums, `idl.Text(n)`
  (UTF-8; agents see a string) and `idl.Bytes(n)` (binary; agents see hex),
  up to 504 bytes. A message is up to 64 words each way, checked at compile
  time: the first five travel in registers, the rest through the IPC buffers
  (the kernel copies them, §2.6), so a 480-byte chunk is one call.
- `grain/lib/idl.zig` generates, at `comptime`, typed client calls
  (`idl.call(proto.kv.put, ep, .{ .key = 1, .value = 2 })`), server dispatch
  (`idl.serve(proto.kv, ep, impl)`, which calls `impl.put(params, caller)`
  with the caller's badge, and replies with an `ErrorCode` on error), the
  wire encoding, and a **canonical JSON descriptor**: every method, field,
  type, effect, undo method and doc.
- **Effects** say what a call does to the world: `pure` (reads only),
  `mutates` (changes the service's state), `external` (output, devices; it
  can't be taken back). A `mutates` method may name its **undo** method,
  whose parameters are filled by name from the call's results, then its
  arguments (`kv.put` returns `previous, had`; `kv.restore` takes
  `key, previous, had`). Agents plan with this (§3.5).
- A protocol's id is the FNV-1a hash of its descriptor; the kernel checks its
  low 16 bits on endpoints (§2.2). Changing anything an agent could rely on,
  even a doc string, changes the id. `grain/proto/proto.zig` lists every
  protocol and rejects id collisions at compile time, and the manifest check
  rejects a protocol name it doesn't know.
- The **Registry** domain serves `registry.v1`: `count`, `nth`, `lookup(id)`
  and `describe(id, offset)`, which returns the descriptor 480 bytes at a
  time. Any domain can ask what a protocol is and how to call it; Envoy
  fetches descriptors from it rather than carrying its own. This is FIDL's
  idea with Zig as the IDL, and it is what lets an AI operate the system
  without guessing.

### 3.3 Ledger

- An append-only, hash-chained log of authority events: grants, leases,
  revocations, generation switches, agent actions, and (in ledger mode)
  kernel events.
- Owner-readable, tamper-evident, exportable. This is where "clear" and
  "loyal" come from: you can always answer *who did what, with whose
  authority*.

### 3.4 Tablecloth: holding things by their content

> **Status (Phase 5):** built: `grain/lib/tablecloth.zig` (the store, generic
> over a block device), the `tablecloth` domain (drives virtio-blk itself),
> `tools/disk` (`grain-disk`). The name and Mantra are the owner's (see
> GLOSSARY.md); the plan called this Granary.

Ask for the same bytes and you get the same bytes, forever. An object is
named by its hash; **Mantra** names bind words to hashes once and for all
(`system@3`), and *tips* are names that move (the head of a chain).

**On disk** (4 KiB blocks): two superblock slots, then an append-only log of
object bytes packed end to end, then a table (sorted object index and names)
per commit. A commit appends after `log_end`, flushes, writes the *other*
superblock slot (sequence number, checksum, where the table is, the
generation state, the wrapped key), and flushes again. Nothing a committed
superblock points at is ever overwritten, so a power cut leaves the old state
or the new one, and a torn superblock fails its checksum so the other slot
wins.

**Proved in the simulator** (`zig build test`): a disk model whose volatile
cache keeps, loses or tears (at a sector boundary) each unflushed write when
the power goes. A scenario of single-commit steps (passphrase, first
generation, a second generation with a sealed secret, stage, boot attempt,
confirm, rollback, boot attempt, confirm) is cut at *every* device operation
of every step, several ways each, and every recovery must mount, equal the
state before or after that step exactly, read every object intact, and
accept new commits. Removing the flush between the table and the superblock
makes it fail at once.

**Public and sealed.** Public objects (system generations, which Aurora
reads before anyone unlocks) are named by BLAKE3 of their bytes. Sealed
objects are XChaCha20-Poly1305 under the master key and named by a keyed
BLAKE3 of (owner, plaintext); the nonce is that name (SIV), so one owner's
equal plaintexts deduplicate and only equality leaks. Because the owner is
in the name, a sealed object opens only for the domain that stored it: any
other gets `NotFound`, whatever it learned. The master key is wrapped by
Argon2id(passphrase); the cost is fixed when the disk is formatted (16 MiB,
2 passes by default; test disks use 1 MiB, 1 pass).

**The domain.** `tablecloth` mounts its disk (formatting a blank one), asks
the owner for the passphrase on the console (twice, to create one; a wrong
one is refused and asked again), and serves `tablecloth.v1`: `put`, `write`
+ `store` for objects up to 64 KiB, `read` (480 bytes per call, checked
against the hash), `has`, `bind`/`lookup` (each client's names live under its
own name: `kumara` binding `secret` makes `kumara/secret`; secret names are
sealed), `commit`, `info`, and `switch_to` (stage a generation, §3.1).
Clients are known by name from `DomainInfo.clients`, which Steward fills
with every domain using the service (by badge) and the agent; Steward itself
calls unbadged.

**Console input.** `console.read_line` hands out what the owner typed, a line
at a time, and is refused to the agent. *Limit:* any domain the manifest
wires to the console could read input; input should be its own service, once
a domain can serve more than one endpoint.

**Ready.** Once mounted and unlocked, the store asks Steward (lifecycle
`ready`) whether every domain came up, confirms a generation on trial if so,
and reports settled; a test system does not power off before that. Steward
never blocks on a domain (an earlier draft had Steward call the store, and a
store fault would have deadlocked the supervisor).

- *Planned:* reclaiming space (the log only grows), an index that is not
  rewritten whole per commit, changing the passphrase, and directories as
  capabilities.

### 3.5 Envoy: the AI interface

> **Status (Phase 4):** implemented and tested end to end
> (`tools/agent_session.py` in `zig build qemu-test`). Differences from the
> first plan are marked *changed*.

Envoy is how an AI agent (or a script, or a human) operates Grain. An agent
is a **principal** with its own leased capabilities. It is never root.

**Authority comes from the manifest.** The `agent` section names the Envoy
domain, the services it **grants** from boot and the ones that are
**askable**, each with a lease limit (`uses`, `duration_ms`):

```brix
agent {
    envoy = envoy
    grant store { from = store.kv, protocol = kv.v1 }
    grant echo { from = flaky.echo, protocol = echo.v1, duration = 4s }
    askable entropy { from = rng.entropy, protocol = entropy.v1, uses = 2 }
}
```

Steward mints each service endpoint with the agent's badge (`0xA6E7`, so
services can tell the agent apart) and the protocol id, wraps it in a kernel
**lease** (§2.3), and installs it in Envoy's CSpace (slots 48+), listed in
`DomainInfo.agent`. Leases are made once per boot, so restarting Envoy can't
refresh them. Envoy has no other authority over services: the kernel
enforces the limits, and an exhausted or expired lease fails with
`lease_exhausted` / `lease_expired`.

| Verb | Meaning |
|---|---|
| `hello` | System name, closure hash, protocol version, verbs. |
| `discover` | The capabilities I hold or may ask for: name, protocol, methods, lease state (uses left, time left). |
| `describe` | The full typed descriptor of one capability's protocol, fetched from the Registry. |
| `call` | One typed call: JSON arguments in, JSON results out. |
| `plan` | Dry-run a list of calls: each step's effect and undo, whether the whole is **atomic** (every step pure or undoable) and executable with the authority held. Nothing changes. |
| `apply` | Run a plan. If it is atomic, all of it happens or none of it does: on a failure the steps already done are undone in reverse. A non-atomic plan is refused unless `allow_partial` is set. Every step is recorded. |
| `undo` | Reverse one recorded action by calling its undo method. |
| `ask` | Request an askable service. *Changed:* Steward decides on the owner's behalf from the manifest's policy (each askable service once); a live owner prompt is *planned* with Seal. |
| `observe` | The audit log. *Changed:* a snapshot, not a subscription (*planned*). |
| `bye` | End the session. Envoy is a task, so this ends the run. |

- **Audit chain.** Every verb that uses authority appends
  `seq|verb|cap|method|outcome|undo_of` to a BLAKE3 hash chain (starting at
  32 zero bytes) and emits an `envoy_action` record. `observe` returns the
  entries and the head; `tools/envoy.py` re-computes the chain to check it.
  This is the seed of the Ledger (§3.3).
- **Transport.** JSON lines on a second virtio-console device (§3.6). One
  request per line, one response per line, `{"id", "ok", "result"|"error"}`.
  Errors carry a code (`not_granted`, `lease_expired`, `not_atomic`, …) and
  a sentence.
- **Host side** (`tools/envoy.py`): a client library (`Session`); **grainsh**,
  a structured shell on the same verbs (`caps`, `describe store`,
  `call store put key=1 value=2`, `plan …; …`, `undo 5`, `log` with the
  chain verified), so a person and an agent see the same typed data; and an **MCP bridge** that turns each method of each held capability
  into an MCP tool (`store__put`, with a JSON Schema built from the
  descriptor) plus `grain_discover`, `grain_plan`, `grain_apply`,
  `grain_undo`, `grain_ask`, `grain_observe`. Nothing about Grain's services
  is hard-coded on the host: it all comes from `discover` and `describe`.
- `zig build run` boots the system in real time and prints the socket to
  connect grainsh or an MCP client to.

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
- *Changed from the plan:* the Envoy channel is a **second virtio-console
  device** (`instance = 1`, `optional`) rather than a second port of the
  first one. Multiport needs a control queue; two devices are simpler and
  just as isolated. Envoy drives it itself, with no console driver between.
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
  transfer is a Tablecloth object exchange: hashes are verified on arrival, and
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
