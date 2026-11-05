# The capability model: a brief for external review

This is what a reviewer of Caravan's capability model needs: what the model
is, what it claims, where each claim is enforced in the code, what checks
it, what is assumed, and the questions we most want answered. It is written
to be checked, not to persuade; where something is weak, it says so.

Code: the kernel core is `caravan/src/core/kernel.zig` (portable, one
file, about 2,600 lines), the system-call contract `caravan/abi/abi.zig`.
Everything below the core (trap entry, page-table format, interrupt
controller) is in `caravan/src/arch/`, and the policy above it in
`grain/steward/main.zig`.

## 1. What is trusted

- **The kernel core and the arch layer.** One global lock serialises every
  kernel entry on every hart; each system call is atomic with respect to
  every other (§2.5 of ARCHITECTURE.md).
- **The root task, Steward.** It receives every initial capability and
  builds the system from the manifest. Its manifest checks run at compile
  time. A bug in Steward is a bug in the TCB.
- **Drivers with DMA-capable devices**, until the IOMMU is used (there is
  no RISC-V IOMMU model in QEMU 8.2; the design is in ARCHITECTURE §3.6).
- **Aurora**, for what measured boot proves (ARCHITECTURE §3.8).
- **Not** trusted: every other domain, every device's register contents
  (parsers are fuzzed against them), the network, the disk's contents
  (sealed or hashed), and the AI agent (it holds leases the owner granted).

## 2. The model

**Objects** live in a table allocated at boot (`Entry`, 32 bytes each:
kind, generation, address, size, links). An object's memory comes from an
untyped region; objects never move.

**Capabilities** are 16 bytes: `object` (table index), `gen`, `rights`,
`protocol`, `badge`. A capability is valid while its `gen` equals the
entry's generation and the entry is live (`validate`). There is no
derivation tree.

**Rights** (`abi.Rights`): read, write, execute, grant, send, recv, revoke,
configure, retype. Each method's documentation in `abi.zig` names the
rights it needs; the core checks them with `need` / `resolveKind` before
doing anything.

**Deriving.** `CNode.mint(dest, src, mask, badge, protocol)` copies a
capability with `rights ∩ mask` (rights only shrink). A badge and a
protocol id can each be set once (a capability that has one cannot be
re-badged, or re-stamped with another protocol). `move` and `delete`
need `configure` on the CNode. Capabilities move between CSpaces only
through IPC on an endpoint capability with `grant` (into empty slots the
receiver named), or by Steward minting into a domain's CNode.

**Revocation** (ARCHITECTURE §2.3). `CNode.revoke(slot)` needs the
`revoke` right on that slot's capability; it bumps the object's
generation: every other capability to it, anywhere, is invalid at once,
and the revoking slot gets the new generation. Threads queued on a revoked
endpoint or signal wake with `aborted`; a revoked frame is unmapped.
Untyped regions, the IRQ and scheduling controls and the debug console
cannot be revoked this way.

**Generations are finite** (32 bits). An entry whose last generation is
reached when its object is destroyed is retired: never handed out again.
A revoke that would leave no generation for that is refused
(`invalid_state`). So a stale capability's generation never comes round
again; the cost is one table entry per 2^32 lifetimes.

**Leases** are the selective revocation. `Lease.arm(target, mask,
duration, uses)` makes a lease forward to a capability; a capability to
the lease acts as the target with `rights ∩ mask` until the duration
passes, the uses run out, or the lease is revoked (its generation bumped).
Resolution (`resolveCap`) follows at most 4 leases, intersecting rights at
each step and checking expiry and uses at each. Capabilities the kernel
keeps for a thread (fault endpoint, bound IRQ signal) are stored
unresolved and resolved on every use, so a lease cut off cuts them off too.

**Memory.** `Untyped.retype` (needs `retype`) creates one object from a
region; device regions make frames only, and the kernel never zeroes or
reads them. `Untyped.reset` destroys every object made from the region,
undoing each one's relationships (dequeues and aborts threads, returns
lent scheduling contexts, unmaps frames and tables, stops harts running a
destroyed thread or address space). Deleting a capability never frees an
object; lifetime is the region's.

**CPU time.** A thread runs only on a scheduling context's budget; a
context is configured through the single `SchedControl` capability
(Steward's). Passive servers run on their callers' contexts (donation).
A context counts every tick charged to it, whoever was running on it;
`SchedContext.info` (with `read`) reads the count, which is how Steward
reports each domain's CPU time to the task manager.

**Interrupts.** `IrqControl.get(line)` makes an Irq object for a device
line; lines the kernel uses itself (a GIC's IPIs and timer, below 32) are
refused. A line raises its bound signal and stays masked until acked.

**Protocol ids.** An endpoint capability may carry a 16-bit protocol id;
when a sender's and a receiver's are both set and differ, the kernel
refuses the message (`protocol_mismatch`). The receiver learns the
sender's protocol and badge with every message.

## 3. Policy above the kernel

- **Steward** gives each domain exactly the capabilities its manifest
  entry names, badged per client and stamped with the protocol, and checks
  at compile time that every `uses` has a matching `provides`.
- **The agent** (Envoy) holds only leases: send and grant, never revoke;
  limited in time or uses where the manifest says. Askable ones only after
  the owner says yes at the console, through the owner domain the manifest
  names (`agent.owner`), which cannot be the agent's own domain; anything
  typed before the question appears is discarded. Every call is audited in
  a hash chain.
- **Kumara** signs for a caller under the caller's domain name as the
  context, so a signature asked for by one domain can never pass as
  another's. Attestations use the context `@attest`, which no domain name
  can be (names are `[a-z0-9_]`), and are served through their own
  protocol (`attest.v1`), so holding it grants nothing else.

## 4. Claims, and what checks each

| # | Claim | Enforced in | Checked by |
|---|---|---|---|
| 1 | A capability is usable only while its generation matches. | `validate` | scenario tests; simulator; fuzzing (garbage capabilities in every register) |
| 2 | Rights only shrink when copied or forwarded. | `mint`, `resolveCap` (`intersect`) | scenario tests; simulator |
| 3 | After `revoke` returns, every other capability to the object is invalid, and anything waiting on it has been woken. | `revokeObject` | model checker (`call_reply_revoke`, `lease_revoked`, `revoke_then_reset`: a call issued after a revoke never succeeds); invariants "blocked thread on dead endpoint/signal" |
| 4 | A lease never lets more uses through than it was armed with, never past its expiry, never after revocation. | `resolveCap` | model checker (`lease_uses`: two clients racing; checked against a planted bug); scenario tests; ktest on hardware time |
| 5 | Destroying an object leaves nothing pointing at it: no thread waits on it, runs it, or translates through it. | `resetUntyped`, `destroy*`, `retireRoot` | 32 invariants after every simulator step and every fuzz step; model checker (`server_destroyed`, `endpoint_destroyed`: every call ends); ktest (teardown of a thread running on another hart) |
| 6 | No call can hang because its server died with its endpoint. | `abortEndpoint` | model checker (liveness in every final state) |
| 7 | A stale generation never comes round again. | `freeEntry`, `revokable` | scenario test (an aged entry) |
| 8 | Only device lines are handed out as interrupts. | `invokeIrqControl` | scenario test; invariant "an Irq object holds one of the kernel's own lines" |
| 9 | The kernel survives any system call from any thread, any fault and interrupt, and any boot data. | the whole core | fuzzing (`fuzz/kernel.zig`), simulator (raw system calls with any number and registers) |
| 10 | The kernel's behaviour is deterministic. | the core has no hidden inputs (time is an event) | simulator: every seed twice, kernel memory hashed |

The model checker's scenarios are small (2 to 4 threads, a few calls
each), but each is exhausted: every order of every call. See
docs/TESTING.md for each tool.

## 5. Known limits

- **Effects that outlive an invocation** are not undone when a lease ends:
  a mapping made through a leased frame capability, or a scheduling
  context bound through one. Revoke the object itself to take those back.
- **A lease spends a use when it is resolved**, before the operation's
  own checks; an invocation that then fails (wrong method, bad arguments)
  still costs a use.
- **DMA**: until the IOMMU is in use, a driver for a bus-mastering device
  can reach all memory.
- **Shared hardware**: budgets bound CPU time, but caches and TLBs are
  shared; nothing addresses timing channels.
- **Measured boot** is only as trustworthy as Aurora until hardware
  measures Aurora (ARCHITECTURE §3.8).
- **One kernel lock**: simple to reason about, a bottleneck with many
  harts.

## 6. Questions for reviewers

1. Is generation-based revocation (one counter per object, no derivation
   tree) sound for everything a derivation tree gives seL4? In particular:
   copies the revoker cannot see, capabilities held by the kernel, and
   capabilities in flight in an IPC.
2. Leases resolve on every use and intersect rights at each hop. Can a
   chain of leases (up to 4) ever widen authority, or outlive its target?
3. Should a lease's use be spent only when the operation succeeds? The
   current choice makes failed probes cost a use; is either choice a risk?
4. `Untyped.reset` undoes every relationship of every object in a region.
   Is there a relationship it misses (the invariants list what is
   checked)?
5. Steward holds all authority at boot. Is the split between compile-time
   manifest checks and run-time minting the right one?
6. Kumara binds signatures to the caller's domain name. Is a name a strong
   enough context, given that Steward assigns names from the manifest?
7. The agent holds leases, and asks the owner for more at the console.
   The agent can also write to that console (its `console` grant): could
   it word output to mislead the owner into a yes? Prompts start with
   `[owner]`, which the agent can print too.
   What could an agent do with `send` and `grant` on an endpoint that the
   owner would not expect?
