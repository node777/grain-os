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

## The loop today (Phase 2)

```sh
zig build test        # host: unit tests, kernel scenario tests, a short simulator run
zig build qemu-test   # QEMU riscv64, 2 harts: boot, run the root task's suite, check records
zig build sim         # the deterministic simulator (16 seeds × 50k steps); -Dseed=N replays one
zig build bench -Doptimize=ReleaseFast   # one hart: benchmark and kernel-profile records
zig build run         # boot interactively (Ctrl-A X quits QEMU)
zig build debug       # boot halted with a GDB stub on :1234
python3 tools/harness.py --json zig-out/bin/caravan   # records as JSON lines
```

The four layers, from fastest to most real:

1. **Unit tests** (`zig test` on the host): the device-tree parser against
   captured QEMU DTBs, the ELF reader, the record formatter, Sv39 encoding.
2. **Scenario tests** (`sim/kernel_test.zig`): the real kernel core on a
   simulated machine. A test *acts as* the current user thread by setting its
   registers and calling `handle(.syscall)`, then checks the result and the
   invariants. They cover mint and revoke, passive servers with donation,
   leases, untyped reset, faults, budgets, round robin, capability transfer,
   interrupts, and destroying a server with a caller waiting.
3. **The simulator** (`caravan-sim`): seeded random system calls (valid and
   garbage), faults, interrupts, IPIs and timer events on 2 harts.
   `checkInvariants()` runs after every step. When nothing can run any
   more, the machine reboots within the same seed. Every seed runs twice, and
   the final kernel memory must hash identically. A failure prints the seed
   and step; `--seed N --trace` replays it.
4. **QEMU** (`qemu-test`): the root task runs the suite from user mode on 2
   harts. That covers boot info, capability identity, mint and revoke, thread
   signalling, a passive server, fault handling with retry, leases, CPU
   budgets, untyped reset, a UART interrupt, tearing down an address space
   while it runs on the other hart, and a cross-hart call. Results are
   `@grain test ...` records, and the exit status comes from the test
   finisher.

How a QEMU test reports:

1. The kernel writes `@caravan` records and user programs write `@grain`
   records (`<event> k=v ...`). Firmware chatter never starts with `@`.
2. The root task powers off through its debug-console capability. On QEMU
   the kernel uses the virt **test finisher**, which sets QEMU's exit status:
   0 for pass, the failure count otherwise. (SBI reset can't do this: OpenSBI
   reports every shutdown reason as success.)
3. `tools/harness.py` runs QEMU with a timeout, prints the records (filtered
   with `--filter`, or as JSON with `--json`), checks `--expect` patterns,
   and exits non-zero on failure, timeout or silence.
4. `-icount shift=0,sleep=off` makes virtual time follow instruction count,
   so runs are **deterministic**, SMP included. Idle harts skip virtual time
   forward, so timer tests take milliseconds.

**When the system hangs:** if every hart is idle with no timer armed, the
kernel prints `@caravan stuck`, then one `thread` record (state, priority,
contexts, reply links, pc) and one `sched_context` record per thread. That
is usually enough to see the lost wakeup at once.

**Bugs these layers found while Phases 1–2 were built** (each now has a
regression test):
- simulator: an endpoint left in "sending" mode after its queue was aborted;
- simulator: struct padding from the stack copied into kernel memory, which
  broke bit-for-bit replay;
- review plus scenario tests: lent scheduling contexts not taken back on
  suspend or unbind; u32 overflow in a child untyped's budget; time
  overflow with huge periods;
- QEMU plus the stuck diagnostic: a budget that ran out in the same kernel
  entry as a call to a passive server was never refilled, so the whole
  system deadlocked;
- review: the trap path touched a thread's saved context before taking the
  kernel lock, racing with another hart destroying that thread.

**Benchmarks:** under `-icount`, QEMU's cycle and instret counters count
the instructions of *all* harts, and a hart waiting for the kernel lock
spins through its time slices. So benchmarks run on one hart (`zig build
bench`), and the 2-hart numbers in `qemu-test` are only indicative. With
`-icount`, cycles = instructions = nanoseconds.

Debugging:

```sh
zig build debug &                                   # QEMU waits for GDB
gdb-multiarch zig-out/bin/caravan -ex 'target remote :1234' -ex 'break kmain' -ex c
```

Use `--qemu-arg -d --qemu-arg int,guest_errors` to have QEMU log every
trap. Profiling that worked well here: `-d exec,nochain -D log`, then count
blocks per address and map the hottest to symbols with
`gdb-multiarch -batch -ex 'info symbol 0x…' zig-out/bin/caravan`. Lines
start `Trace <cpu>:`, so you can profile one hart at a time.

## How testing grows with each phase

| Phase | What gets tested | How |
|---|---|---|
| 0 Boot | traps, timer, console, exit codes | harness and test finisher ✅ |
| 1 Core objects | capability tables, untyped retype, generations, page tables | unit and scenario tests on `core/` ✅ |
| 2 IPC and scheduling | call/reply, signals, MCS budgets, SMP | `caravan-sim` with invariants after every step; the root-task suite on 2 QEMU harts ✅ |
| 3 Userspace and drivers | virtio-console, blk, net | QEMU with virtio devices; block images built by `zig build`; networking through QEMU user-mode net with port forwards |
| 4 Envoy | the AI interface end to end | the harness grows into a **driver**: it opens the Envoy virtio-console port as a socket (`-chardev socket`) and speaks the protocol (`discover`, `plan`, `apply`). Tests are scripts of Envoy calls with expected typed results. This is also how I interactively operate the OS while building it. |
| 5 Storage and identity | Granary, Ledger, generations, Seal | virtio-blk images; power-cut injection (kill QEMU at random instructions, reboot, verify) |
| 6 Desktop | compositor, UI | virtio-gpu; QMP `screendump` writes PNGs the agent can look at; input injected through QMP |
| 7 Social | two or more instances | several QEMU instances on a QEMU socket network (`-netdev socket`/`dgram`); tests script introductions, app hosting, transfer and revocation |
| any | whole-system determinism | QEMU `-icount rr=record/replay` for bit-exact machine replay; Grain's own Ledger replay compared against it |
| 8 Ports | aarch64, x86_64 | the same test suite on `qemu-system-aarch64 -M virt` and `qemu-system-x86_64 -M q35`, run as a CI matrix |
| 8 Real hardware | boards | flash a VisionFive 2 / Milk-V / RVA23 board; the same records come over a USB-serial line and the same harness reads them. Needs the owner's hardware. |

Other tools, used where they pay off:

- **Spike** (`riscv-isa-sim`): the golden reference RISC-V model, for
  checking architecture code against the spec when QEMU and hardware differ.
- **Renode**: multi-node simulation with controlled time, if QEMU socket
  networking isn't deterministic enough for the social-layer tests.
- **TLA+ or a Zig model checker:** for the IPC and revocation protocols
  before they're written. Small models, run in CI.
- **CI:** GitHub Actions runs `zig build test qemu-test` (later `sim` with a
  time budget and the port matrix) on every push.
