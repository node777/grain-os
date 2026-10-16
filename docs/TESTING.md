# Testing and driving Grain

The aim: every layer can be built, booted, checked and driven **from a
terminal, by a human or an AI, with a pass or fail answer in seconds.**

## Toolchain

| Tool | Version | Why |
|---|---|---|
| Zig | 0.17.0 (pinned) | Compiler, build system, cross-compiler, host test runner |
| QEMU | 8.2+ (`qemu-system-riscv64`, later `-x86_64`, `-aarch64`) | The machine. 9.2+ is needed later for the RISC-V IOMMU and newer AIA models. |
| OpenSBI | the one bundled with QEMU (`-bios default`) | M-mode firmware on RISC-V |
| gdb-multiarch | any | Source-level kernel debugging over QEMU's GDB stub |
| Python 3 | 3.10+ | Test harness and, later, the Envoy driver |

`tools/setup.sh` installs all of these on Debian/Ubuntu.

## The loop today (Phase 0)

```sh
zig build test        # host unit tests for caravan/src/core (portable code)
zig build qemu-test   # boot in QEMU, run in-kernel self-tests, check records
zig build run         # boot interactively (Ctrl-A X quits QEMU)
zig build debug       # boot halted with a GDB stub on :1234
python3 tools/harness.py --json zig-out/bin/caravan   # records as JSON lines
```

How a QEMU test reports:

1. The kernel writes **structured records** (`@caravan <event> k=v ...`) to the
   SBI console. Firmware chatter never starts with `@caravan`.
2. It shuts down through the QEMU virt **test finisher** device, which sets
   QEMU's exit status: 0 for pass, the failure count otherwise. (SBI reset
   can't do this: OpenSBI reports every shutdown reason as success.)
3. `tools/harness.py` runs QEMU with a timeout, prints the records, checks
   `--expect` patterns, and exits non-zero on failure, timeout or silence.
4. `-icount shift=0,sleep=off` makes virtual time follow instruction count,
   so runs are **deterministic**. Two runs give byte-identical console
   output. Idle `wfi` skips virtual time forward, so timer tests take
   milliseconds.

Debugging:

```sh
zig build debug &                                   # QEMU waits for GDB
gdb-multiarch zig-out/bin/caravan -ex 'target remote :1234' -ex 'break kmain' -ex c
```

Use `-d int,guest_errors,unimp` (pass it with `--qemu-arg`) to have QEMU log
every trap. `-d in_asm` gives an instruction trace.

## How testing grows with each phase

| Phase | What gets tested | How |
|---|---|---|
| 0 Boot | traps, timer, console, exit codes | in-kernel self-tests and the harness ✅ |
| 1 Core objects | capability tables, untyped retype, generations, page tables | **host unit tests** on `core/`, plus property tests (random operation sequences, invariants checked after each) |
| 2 IPC and scheduling | call/reply, signals, MCS budgets | **`zig build sim`**: the deterministic simulator runs the real `core.step` on seeded event streams; a failure prints the seed, and `zig build sim -Dseed=N` replays it |
| 2+ | the same on real (emulated) hardware | QEMU tests with user domains that run scripted IPC workloads and report records; `-smp 4` for multi-hart |
| 3 Userspace and drivers | virtio-console, blk, net | QEMU with virtio devices; block images built by `zig build`; networking through QEMU user-mode net with port forwards |
| 4 Envoy | the AI interface end to end | the harness grows into a **driver**: it opens the Envoy virtio-console port as a socket (`-chardev socket`) and speaks the protocol (`discover`, `plan`, `apply`). Tests are scripts of Envoy calls with expected typed results. This is also how I interactively operate the OS while building it. |
| 5 Graphics | compositor, UI | virtio-gpu; QMP `screendump` writes PNGs the agent can look at; input injected through QMP |
| 6 Snapshots and replay | whole-system determinism | QEMU `-icount rr=record/replay` for bit-exact machine replay; Grain's own Ledger replay compared against it |
| 7 Ports | aarch64, x86_64 | the same test suite on `qemu-system-aarch64 -M virt` and `qemu-system-x86_64 -M q35`, run as a CI matrix |
| 8 Real hardware | boards | flash a VisionFive 2 / Milk-V / RVA23 board; the same records come over a USB-serial line and the same harness reads them. Needs the owner's hardware. |

Other tools, used where they pay off:

- **Spike** (`riscv-isa-sim`): the golden reference RISC-V model, for
  checking architecture code against the spec when QEMU and hardware differ.
- **Renode**: multi-node simulation, for when Grain machines talk to each
  other (the "social" networking layer).
- **TLA+ or a Zig model checker:** for the IPC and revocation protocols
  before they're written. Small models, run in CI.
- **CI:** GitHub Actions runs `zig build test qemu-test` (later `sim` with a
  time budget and the port matrix) on every push.
