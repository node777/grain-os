# Glossary: proposed names

The owner proposed a naming scheme on 2026-10-16. This page maps each
proposed name onto the part of Grain it fits. **Decisions so far:** *Caravan*
stays the name of the microkernel and *Steward* keeps its name; the other
names apply to docs now, and the code is renamed after Phase 4. Until then
code, records and file names use the current names (right-hand column).

The "plainly" column is the owner's description, quoted.

| Proposed name | What it does, plainly | In Grain today | Status |
|---|---|---|---|
| **Caravan** | "A group that travels together and arrives together. It starts every other part in the right order, watches each one, and brings back anything that stumbles, all inside limits fixed before it begins." | The microkernel (decided: keep). The starting, watching and restarting described here is what **Steward** does on top of it. | Kept as is |
| **Tally** | "Keeps the books on memory. Every allocation is counted against a declared ceiling, so the system can show you it stayed inside its promise." | Memory accounting: untyped regions with object budgets in Caravan (ARCHITECTURE §2.4), each domain built inside a region sized from its manifest `memory_kib` (§3.1). | Built, unnamed; a Tally report (usage against each ceiling, through Envoy) is a natural next piece |
| **Mantra** | "Names things so a name stays true. Ask for a name and you get exactly the bytes you got last time, forever. That is what makes a build reproducible. Beginner door." | Hash-pinned names: the boot image names every program by BLAKE3 hash and the whole system by its closure hash (§3.1); Granary petnames bound to hashes (§3.4). | Partly built (image); petnames planned (Phase 5) |
| **Comlink** | "Carries sealed messages between machines. It moves bytes without reading them, and what arrives is bit-for-bit what left." | **Courier**, the identity-addressed transport between instances (§3.7). | Planned |
| **Pond** | "A fence around a running program: this much memory, these files, this network. A program works inside exactly the boundary it was handed." | A **domain**: one program with its own region, CPU budget, services and devices, exactly as the manifest says (§3.1). | Built |
| **Amphora** | "A sealed vessel for something crossing a boundary, opened by whoever it was addressed to." | The sealed, addressed envelope Seal and Courier pass between instances (§3.7). Not yet a separate concept in the design; this name gives it one. | Planned |
| **Rishi** | "The shell. The plain-language hand you use to run the tree." | **grainsh**, the structured shell on Envoy's verbs (`tools/envoy.py shell`, §3.5). | Built (host side) |
| **Glow / Rye** | "The language people write, and the bounded systems language it lowers to." | No counterpart: Grain's programs are written in Zig. | From the owner's other project; not adopted |
| **Kumara** | "Identity you own -- a key in your hands, and yours for as long as you hold it." | **Seal**, the owner's identity and device keys (§3.7). | Planned (Phase 5) |
| **Aurora** | "The dawn. The first code that wakes on bare hardware, before an operating system exists." | The boot path: firmware hand-off (OpenSBI today) to Caravan's boot code (`caravan/src/arch/riscv64/`), which sets up paging and starts the root task. | Built for QEMU; real boards in Phase 8 |
| **Surf / Brushstroke** | "The drawing surface, and the strokes made on it." | The compositor and the drawing interface of the personal desktop. | Planned (Phase 6) |
| **Mycelium** | "The quiet network underneath, named for the thread that connects a forest." | The network below Courier: the virtio-net driver and network stack, and the mesh between instances. | Planned |
| **Brix** (beginner door) | "The declaring language. A .brix file says what a system is made of and how the parts fit, and evaluates to plain Kyri a program can read. You declare the shape; the tree checks it holds." | The **manifest language** ([BRIX.md](BRIX.md)): a `.brix` file evaluates to the plain manifest data (written as ZON for Steward), and the manifest validator checks it. | Built (Phase 4); `system/*.brix` |
| **Tablecloth** | "Holds a thing by its content rather than by where you put it. Ask for the same bytes and you get the same bytes, from any room, forever. Beginner door; it runs through several rooms rather than sitting in one, and brushstroke/tablecloth.rye is the nearest single file." | **Granary**, the content-addressed store (§3.4). | Planned (Phase 5) |

Names with no proposed replacement keep theirs: **Grain** (the OS),
**Steward**, **Envoy**, **Registry**, **Ledger**.

## Terms from the owner's other project

The proposal mentions *Kyri*, *the tree*, *rooms*, *beginner door* and
`.rye` files (`brushstroke/tablecloth.rye`). The owner said these come from
another project of theirs, and that design isn't in this repository. Until
it is shared, this repository reads "evaluates to plain Kyri" as
**evaluates to plain data** (for Brix: the manifest structure Steward
reads), and "the tree checks it holds" as **the manifest validator checks
it**. If the owner shares that design, these readings get replaced.
