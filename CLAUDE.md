# Working on Grain OS

- Toolchain: Zig **0.17.0** exactly (`tools/setup.sh`). The Zig standard library
  API changes between releases; check `/opt/zig/lib/std` rather than memory.
- Before pushing: `zig build test && zig build qemu-test` must both pass.
  qemu-test includes a real-time agent session (`tools/agent_session.py`);
  if Envoy's protocol changes, update `tools/envoy.py` and that script too.
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
  behaviour) a test in the root task (`grain/ktest/main.zig`). IPC or
  revocation changes: a scenario in `sim/model.zig` (`zig build model`).
- A parser of input someone else controls (a device, the network, a disk,
  a client) needs a fuzz target in `fuzz/user.zig` (kernel-side ones in
  `fuzz/kernel.zig`); `zig build fuzz --fuzz=100K` for a coverage-guided run.
- `emu/` is the emulated machine (grain-emu): it must keep booting what QEMU
  boots. Instruction or device changes need a test in `emu/hart_test.zig`
  (or the file's own tests) and `zig build emu-test`. The machine itself
  stays host-free (everything outside goes through `Host`), so it can be
  built for WebAssembly (`emu/wasm.zig`). Page changes (`web/`): run
  `zig build web-test` (Node and Playwright).
- Machine-readable output goes through `klog` (`@caravan` from the kernel,
  `@grain` from user space): `<event> k=v`, names `[a-z0-9_]`.
- Benchmarks: run `zig build bench -Doptimize=ReleaseFast` (one hart). Under
  QEMU -icount, counters on multi-hart runs include other harts' work.
- Systems are manifests in `system/`. A new program goes in
  `grain/programs/<name>/main.zig` (with `comptime { grain.exportStart(); }`
  and `pub fn main() !u16`), and its name in `program_names` in build.zig.
  Domain-facing contracts live in `grain/lib/domain.zig`; protocols are one
  file each in `grain/proto/`, listed in `proto.zig`.
- Manifest checks live in `schema.validate`; each new rule needs a test with
  its message in `schema.zig`.
- Storage tests boot several times on one disk (`--boots`, `N:` prefixes,
  `--kill-on` for power cuts); the passphrase is typed with `--console-input`.
  Tablecloth's on-disk format changes need the crash simulator
  (`grain/lib/tablecloth.zig` tests) to keep passing; every commit must stay
  a single superblock write after a flush.
- Manifests are Brix (`system/*.brix`, docs/BRIX.md). A new schema field
  needs no Brix change; check it with `zig-out/bin/brix --print`.
- Design changes go into `docs/ARCHITECTURE.md` in the same commit as the code.
