# Working on Grain OS

- Toolchain: Zig **0.17.0** exactly (`tools/setup.sh`). The Zig standard library
  API changes between releases; check `/opt/zig/lib/std` rather than memory.
- Before pushing: `zig build test && zig build qemu-test` must both pass.
  For kernel-core changes also run `zig build sim` (about a minute).
- `caravan/abi/abi.zig` is the user/kernel contract. Change it deliberately and
  update both sides (`caravan/src/core/kernel.zig`, `grain/lib/grain.zig`).
- `caravan/src/core/` is portable: no inline asm, no MMIO, no imports outside
  `core/` except `abi`. The build enforces this by compiling it as its own module.
  Hardware effects go through the arch interface documented at the top of kernel.zig.
- Kernel memory copied from the stack must have no padding (use extern structs):
  the simulator hashes kernel memory to prove determinism.
- New kernel behaviour needs: a scenario test in `sim/kernel_test.zig`, an
  invariant in `checkInvariants` if it adds state, and (for user-visible
  behaviour) a test in the root task (`grain/root/main.zig`).
- Machine-readable output goes through `klog` (`@caravan` from the kernel,
  `@grain` from user space): `<event> k=v`, names `[a-z0-9_]`.
- Benchmarks: run `zig build bench -Doptimize=ReleaseFast` (one hart). Under
  QEMU -icount, counters on multi-hart runs include other harts' work.
- Design changes go into `docs/ARCHITECTURE.md` in the same commit as the code.
