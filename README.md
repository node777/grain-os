# Grain OS

Grain is a capability operating system written in Zig. It aims to be
deterministic, secure, and easy for an AI to operate. Its microkernel is
**Caravan**.

Grain is designed to be **intimate** (local-first, owner-held keys),
**social** (share by handing over a capability), **secure** (no ambient
authority, a minimal kernel), **clear** (typed, self-describing interfaces;
an audit ledger), and **loyal** (it answers to its owner only).

RISC-V is the primary target; aarch64 and x86_64 follow.

> Status: **Phase 2 complete.** Caravan is a working capability microkernel
> on QEMU `virt` (riscv64, SMP). It has capabilities with O(1) revocation and
> leases, untyped memory, Sv39 address spaces, threads, IPC with capability
> transfer, signals, interrupts as signals, user-mode fault handling, and
> MCS scheduling with donation. The portable core also runs in a
> deterministic simulator that checks every invariant after every step.

## Quick start

```sh
tools/setup.sh        # Zig 0.17.0, QEMU, OpenSBI, gdb-multiarch (Debian/Ubuntu)
zig build test        # host: unit tests, kernel scenario tests, short simulator run
zig build qemu-test   # QEMU, 2 harts: the root task runs the kernel test suite
zig build sim         # deterministic simulator: random events, invariants every step
zig build bench -Doptimize=ReleaseFast   # benchmark and kernel-profile records
zig build run         # boot interactively (Ctrl-A X to quit)
```

```
@caravan boot kernel=caravan arch=riscv64 hart=0 harts=2 timebase_hz=10000000 dtb=0x8fe00000 image=0x80200000
@caravan root_task thread=25 entry=0x10000 untyped=19
@grain test name=call_passive_server result=pass
@grain test name=leases result=pass
@grain test name=foreign_teardown_on_other_hart result=pass
@grain test name=cross_hart_call result=pass
@grain summary tests=13 failed=0
```

## Documents

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): the design of Caravan and Grain
- [docs/PLAN.md](docs/PLAN.md): phased roadmap and open questions
- [docs/TESTING.md](docs/TESTING.md): how each layer is built, booted, tested and driven
- [docs/RESEARCH.md](docs/RESEARCH.md): what we took from seL4, Hubris, Zircon, NixOS, Linux, TigerBeetle and others

## Layout

```
build.zig                    build graph (kernel, root task, host tests, simulator, QEMU steps)
caravan/abi/abi.zig          the system-call contract shared by kernel and user programs
caravan/src/core/            portable kernel core: kernel.zig (state machine), fdt, elf, klog
caravan/src/arch/riscv64/    boot (Sv39, higher half), traps, SBI, PLIC, the arch interface
caravan/src/main.zig         riscv64 glue: harts, kernel lock, traps → kernel.handle
grain/lib/grain.zig          libgrain: system-call stubs, methods, @grain records
grain/root/main.zig          the root task (today: the kernel test suite and benchmarks)
sim/                         simulated machine, scenario tests, caravan-sim
tools/harness.py             boots QEMU, parses records, sets the exit status
tools/setup.sh               toolchain installer
```
