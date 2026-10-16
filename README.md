# Grain OS

Grain is a capability operating system written in Zig. It aims to be
deterministic, secure, and easy for an AI to operate. Its microkernel is
**Caravan**.

Grain is designed to be **intimate** (local-first, owner-held keys),
**social** (share by handing over a capability), **secure** (no ambient
authority, a minimal kernel), **clear** (typed, self-describing interfaces;
an audit ledger), and **loyal** (it answers to its owner only).

RISC-V is the primary target; aarch64 and x86_64 follow.

> Status: **Phase 0.** Caravan boots on QEMU `virt` (riscv64), handles traps
> and timer interrupts, and reports structured self-test results.

## Quick start

```sh
tools/setup.sh        # Zig 0.17.0, QEMU, OpenSBI, gdb-multiarch (Debian/Ubuntu)
zig build test        # host unit tests for the portable kernel core
zig build qemu-test   # boot in QEMU and check the in-kernel self-tests
zig build run         # boot interactively (Ctrl-A X to quit)
```

```
@caravan boot kernel=caravan arch=riscv64 hart=0 dtb=0x8fe00000 image_start=0x80200000 image_end=0x80267000
@caravan test name=breakpoint_exception result=pass
@caravan test name=timer_interrupt result=pass
@caravan summary tests=2 failed=0
@caravan halt reason=selftest_complete
```

## Documents

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): the design of Caravan and Grain
- [docs/PLAN.md](docs/PLAN.md): phased roadmap and open questions
- [docs/TESTING.md](docs/TESTING.md): how each layer is built, booted, tested and driven
- [docs/RESEARCH.md](docs/RESEARCH.md): what we took from seL4, Hubris, Zircon, NixOS, Linux, TigerBeetle and others

## Layout

```
build.zig                    build graph (kernel, host tests, QEMU steps)
caravan/src/main.zig         kernel entry and Phase 0 self-tests
caravan/src/core/            portable kernel core (no hardware access; host-testable)
caravan/src/arch/riscv64/    boot, traps, CSRs, SBI, board, linker script
tools/harness.py             boots QEMU, parses @caravan records, sets the exit status
tools/setup.sh               toolchain installer
```
