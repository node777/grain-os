# Working on Grain OS

- Toolchain: Zig **0.17.0** exactly (`tools/setup.sh`). The Zig standard library
  API changes between releases; check `/opt/zig/lib/std` rather than memory.
- Before pushing: `zig build test && zig build qemu-test` must both pass.
- `caravan/src/core/` is portable: no inline asm, no MMIO, no imports outside
  `core/`. The build enforces this by compiling it as its own module for the host.
- Architecture-specific code lives in `caravan/src/arch/<arch>/`.
- Kernel output meant for machines goes through `klog` (`@caravan <event> k=v`).
  Event and field names are `[a-z0-9_]`. Don't print free-form text in the kernel.
- Design changes go into `docs/ARCHITECTURE.md` in the same commit as the code.
