# Testing and driving Grain

The aim: every layer can be built, booted, checked and driven **from a
terminal, by a human or an AI, with a pass or fail answer in seconds.**

## Toolchain

| Tool | Version | Why |
|---|---|---|
| Zig | 0.17.0 (pinned) | Compiler, build system, cross-compiler, host test runner |
| QEMU | 8.2+ (`qemu-system-riscv64`, `-aarch64`; later `-x86_64`) | The machine. 9.2+ is needed later for the RISC-V IOMMU and newer AIA models. |
| OpenSBI | the one bundled with QEMU (`-bios default`) | M-mode firmware on RISC-V |
| gdb-multiarch | any | Source-level kernel debugging over QEMU's GDB stub |
| Python 3 | 3.10+ | Test harness and, later, the Envoy driver |

`tools/setup.sh` installs all of these on Debian/Ubuntu.

## The loop today (Phase 9)

```sh
zig build test        # host: unit tests, kernel scenarios, manifest, image, IDL, Brix, Kumara,
                      # generation format, and Tablecloth with its crash simulator; a short simulator run;
                      # a seeded sweep of every fuzz target; the model checker
zig build qemu-test   # QEMU riscv64, 2 harts: kernel suite (and again on aarch64); the dev system; the dev system on a disk,
                      # booted twice; an agent driving Envoy; the desktop through QMP; two instances
                      # meeting and sharing (tools/pair.py); the faults system;
                      # generations through Aurora with power cuts; a broken generation given up;
                      # a miswired manifest
zig build check-manifest -Dsystem=system/my.brix  # check a manifest (Brix or ZON)
zig-out/bin/brix --print system/my.brix           # what a .brix evaluates to
zig build sim         # the deterministic simulator (16 seeds × 50k steps); -Dseed=N replays one
zig build fuzz        # every fuzz target, a longer seeded sweep (-Dfuzz-sweep=percent, default 1000)
zig build fuzz --fuzz=100K  # Zig's coverage-guided fuzzer on them (crashing inputs: .zig-cache/f/)
zig build model       # the model checker: every order of every IPC and revocation scenario
zig build emu-test    # the kernel suite and the system on grain-emu (emu/), not QEMU
zig build web         # the web page in zig-out/web (serve it; -Doptimize=ReleaseSafe to publish)
zig build web-test    # the page in headless Chromium (Node and Playwright)
zig-out/bin/grain-emu --harts 2 --stats zig-out/bin/caravan-ktest   # the emulator by hand
python3 tools/harness.py --emu zig-out/bin/grain-emu ...            # any harness run, on the emulator
valgrind --tool=callgrind zig-out/bin/caravan-profile   # where the core spends an IPC round trip
zig build bench -Doptimize=ReleaseFast   # one hart: benchmark and kernel-profile records
zig build run         # boot through Aurora in real time with an Envoy socket; each build becomes the
                      # current generation of a disk that persists between runs (zig-out/run-disk.img);
                      # type the disk's passphrase in the terminal (it is not shown); -Ddisplay shows the
                      # desktop in a window; -Dsocket=PATH serves Envoy at a fixed path (a private directory);
                      # the agent's asks appear on the console: answer yes or no
zig-out/bin/grain-disk show zig-out/run-disk.img     # what a disk holds: commits, free space, generations, names
zig-out/bin/grain-disk passwd zig-out/run-disk.img   # change the passphrase (old, then new, on stdin)
python3 tools/envoy.py shell --socket PATH    # grainsh, the structured shell
python3 tools/envoy.py mcp --socket PATH      # MCP server (stdio) for any MCP-capable agent
zig build debug       # boot halted with a GDB stub on 127.0.0.1:1234 (this machine only)
python3 tools/harness.py --json zig-out/bin/caravan   # records as JSON lines
```

The four layers, from fastest to most real:

1. **Unit tests** (`zig test` on the host): the device-tree parser against
   captured QEMU DTBs, the ELF reader, the record formatter, Sv39 encoding,
   the IDL, and Brix (syntax, units, templates, and that each error names
   the right line and column); the shipped `.brix` manifests must evaluate
   and pass the check.
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
3b. **Fuzzing** (`fuzz/kernel.zig`, `fuzz/user.zig`): every way into the
   kernel (system calls with any registers, faults, interrupts on any line,
   time, and boot itself with a damaged root image, device tree and odd
   platform numbers), with the invariants after every kernel entry; and
   every parser that reads what someone else controls: the device tree and
   ELF images, network frames, Noise handshake and transport messages, a
   damaged Tablecloth disk, boot images, generation descriptors, client
   messages for every method of every protocol, Brix manifests, USB
   configuration descriptors, PCI BAR sizes. Each target also checks a
   property where there is one: a damaged Noise message is never accepted
   as authentic, an object read from a damaged disk still matches its hash,
   a decoded message encodes back to itself, placed BARs are aligned and
   inside the window. A target draws its choices from `fuzz/source.zig`:
   Zig's coverage-guided fuzzer under `--fuzz`, a seeded PRNG otherwise
   (`zig build test` sweeps each target; valid samples are damaged the
   way a bad sector or an attacker would, which reaches far deeper than
   random bytes). The kernel targets share the simulator's step generator
   (`sim/driver.zig`). Found and fixed on the way: integer overflows in the
   device-tree parser (cell counts from the tree itself; the kernel runs it
   at boot) and the boot-image parser, a device-tree offset past the end,
   PCI BAR sizes from a device that answers a mask with holes (an
   assertion in placement; Steward would have crashed), and the xHCI
   descriptor walk reading past a descriptor's length (now a pure,
   bounds-checked `parseConfiguration`). A coverage-guided run of 30,000 inputs per
   target (`zig build fuzz --fuzz=30K`, about five minutes) found nothing
   further.
3c. **Model checking** (`caravan-model`, `sim/model.zig`): small
   scenarios of a few threads, one per hart, each running a short script
   of system calls; every order of those calls is tried on the real kernel
   core (each is atomic under the kernel lock), snapshotting the machine at
   each branch and skipping states already seen. In every state: the
   kernel's invariants and the scenario's safety property (a call issued
   after a revoke never succeeds; a lease good for two uses lets at most two
   calls through). In every final state: liveness (every thread finished,
   except servers waiting in a receive and threads that were destroyed).
   Scenarios: call and reply while the endpoint is revoked; a server and its
   endpoint destroyed mid-call; clients queued on an endpoint that is
   destroyed; two clients racing for a lease's uses; a lease revoked while
   used; a revoke then a reset while two clients call (894 states); a bound
   signal and a message to one server. A violation prints the order of
   calls that led to it. Checked against planted bugs: a lease that never
   uses up, and destroyed endpoints that keep their waiters, are both
   caught.

3d. **The emulated machine** (`grain-emu`, ARCHITECTURE §3.10): unit
   tests of its instruction semantics, decoder and devices (in `zig build
   test`, with the kernel suite on 1 and 2 emulated harts); and `zig build
   emu-test`, which boots the dev system, the two-boot storage test, a boot
   through Aurora and a real-time agent session on it through the same
   harness and expectations as on QEMU (`--emu PATH`). The emulator supports
   what those need; `--display` (driven through QEMU's monitor), NVMe and
   Arm are refused. Its desktop devices have unit tests and are driven by
   the web test.

3e. **The web page** (`zig build web-test`, `tools/web_test.mjs`; docs/WEB.md):
   headless Chromium loads the built site from a local server and runs the
   kernel suite, then the dev system on a fresh disk (choosing a
   passphrase in the console, grainsh calls, an ask the owner approves, the
   audit chain verified in the page; the agent panel against a stand-in
   for the Messages API (Playwright answers its requests with scripted
   streams: a tool call that must reach the store through Envoy, then an
   answer); the desktop: the scene read through
   Envoy held against the canvas's pixels, the shell opened by a click on
   the dock, `whoami` typed into it and text pasted onto it; `bye`), then
   reloads and checks the disk survived (the same identity; a wrong
   passphrase refused), exports the disk, forgets it and imports it back,
   and boots with a 1280×800 screen. CI runs it
   on the release build (`.github/workflows/web.yml`).

4. **QEMU, kernel suite** (`caravan-ktest`): the kernel test program runs as
   root task, on 2 harts. That covers boot info, capability identity, mint and revoke, thread
   signalling, a passive server, fault handling with retry, leases, CPU
   budgets, untyped reset, a UART interrupt, tearing down an address space
   while it runs on the other hart, and a cross-hart call. Results are
   `@grain test ...` records, and the exit status comes from the test
   finisher.
4b. **QEMU, kernel suite on Arm** (`caravan-aarch64-ktest`, harness
   `--arch aarch64`): the same program, built for aarch64, on QEMU virt with
   two Cortex-A72 cores. PSCI's power-off carries no status, so the
   `summary failed=0` record decides.

5. **QEMU, whole systems** (`caravan`, `caravan-faults`): Steward boots a
   manifest, and the harness checks the records. For the dev system that
   means: the image verified, both drivers ready, flaky faulted and was
   rebuilt (restart=1), checker's echo answered 42, hello exited 0, Envoy
   was skipped (no agent port attached: its device is `optional`), and
   the summary. It also checks the virtio console's output file: hello's
   greeting, with the entropy bytes the virtio-rng device read from a
   fixed pattern file, and checker's line. The faults system checks the
   restart limit, service revocation and that the client was not left
   hanging.
6. **QEMU, an agent session** (`--agent tools/agent_session.py`): the same
   dev system with a second virtio console exposed as a Unix socket, which
   the harness connects to as the agent. The script drives every Envoy verb
   and reports `@agent check name=… result=pass|fail`: discover (grants,
   askable, lease limits), describe (from the Registry), a typed call (the
   service sees the agent's badge), the MCP bridge's tools, plan changes
   nothing, apply is all-or-nothing, undo, a non-atomic plan is refused,
   ask then exhaust a use-limited lease (the harness answers the owner's
   question with yes, `--owner-approve`), an ask the owner refuses
   (`--owner-refuse`) stays refused, refusal once a timed lease expires,
   grainsh on the same session, and the audit hash chain recomputed on the
   host. Then `bye`, Envoy exits 0, and the summary must be clean. This run
   uses real time (`--realtime`), so leases expire by the clock; it is the
   one QEMU run that is not deterministic.
7. **QEMU, storage and identity:** the dev system on a fresh disk, booted
   twice (`--boots 2`). Boot 1 finds a blank store, takes a new passphrase
   (typed on the console by the harness) and makes the identity; boot 2
   refuses a wrong passphrase, unlocks with the right one, and the identity
   comes back by the same name.
7b. **QEMU, storage on NVMe** (`--disk-bus nvme`): the same two boots on
   an NVMe drive. Steward finds it on the PCI bus, places its BAR and
   routes its interrupt; Tablecloth drives it natively; the identity made
   on boot 1 comes back on boot 2.
8. **QEMU, generations through Aurora** (eight boots on one disk). Aurora
   measures what it boots; on the first boot the agent asks for an
   attestation (`attest.v1`) with a fresh nonce and checks it with an
   independent implementation (`tools/envoy.py`: BLAKE3 in Python, Ed25519
   from `cryptography`): the chain is the one its parts make, the identity
   signed it with that nonce, and it names the current generation. Then an agent
   uploads and switches to the next generation; the power is cut right
   after Aurora records the trial boot; the trial comes up and is confirmed;
   the agent rolls back; the power is cut mid-confirm; the rollback
   completes; the agent forgets the generation it left and reclaims its
   space; the next boot comes up whole. The identity is the same in every
   boot that runs. A second run
   stages a generation that can never come up and checks Aurora gives it up
   after three tries and boots the last good one.
9. **QEMU, the desktop** (`--display`): the dev system with a screen,
   keyboard and tablet. `tools/desktop_session.py` finds the shell's
   launcher in the scene the agent reads through Envoy, clicks it, types
   `whoami`, finds the identity among the shell's answers, clicks the
   shell's `clear` button, and puts the window away from the dock; at each
   step it holds the scene against a screenshot (every filled element shows
   its colour where the scene says it is topmost; every line of text has
   ink).
9b. **QEMU, the desktop on PC hardware** (`--display=native`): the same
   session with a Bochs linear framebuffer on PCI and a USB keyboard and
   tablet behind an xHCI controller (Surf logs `surf_usb devices=2`).
10. **QEMU, two instances** (`tools/pair.py`, real time): two systems with
    their own disks, entropy and identities, their network devices joined
    by a pair of Unix datagram sockets. `tools/comlink_session.py`: they
    introduce themselves; A lends B its guestbook on a three-use lease; B's
    agent calls it as `guestbook@<A>`; the fourth call is refused by the
    kernel; a file moves by its hash; a second share is revoked and B's next
    call is refused. A's network device is virtio-net, B's an Intel e1000 on
    PCI, so both drivers carry the same conversation.
11. **Manifest compile failure:** `zig build check-manifest
   -Dsystem=system/tests/miswired.brix` must fail, and its stderr must name
   the missing service (brix reports it with the line of the block).

Devices in QEMU (added by the harness): `--virtio-console` attaches a
virtio console as a Unix socket the harness serves (QEMU waits for it, so no
output is lost): its output goes to a temporary file (`--show-console`
prints it, `--expect-console TEXT` checks it) and `--console-input LINE`
types a line (the disk passphrase). `--disk IMG` attaches a virtio-blk disk,
a fresh copy unless `--disk-inplace`. `--display` attaches a screen
(virtio-gpu, 1024x768), a keyboard and a tablet, and a QMP socket
(`--display=native`: bochs-display, and `usb-kbd` and `usb-tablet` on a
`qemu-xhci` controller); an agent
script whose `run` takes a third parameter gets a `Screen`: `shot()`
(a screendump, with `pixel(img, x, y)`), `type(text)`, `key(...)`,
`click(x, y)`, and `wait(record)` to follow the system's records.

**Several boots, and power cuts.** `--boots N` boots N times on the same
disk. `--expect`, `--expect-console`, `--console-input`, `--agent` and
`--kill-on` take an `N:` prefix to apply to one boot only. `--kill-on
"N:record"` kills QEMU the moment boot N prints that record: a power cut at
an exact point, after which the next boot must recover. `--agent-env K=V`
passes settings (such as the generation to upload) to agent scripts.

**Disks** (`zig-out/bin/grain-disk`): `format` (with `--kdf-kib/--kdf-t`
for a cheap test disk, and `--install`/`--stage` to add generations),
`add`, `pack` (a generation as files for an agent to upload) and `show`. `--virtio-rng=FILE` attaches
a virtio entropy device reading FILE. `--envoy-socket` (implied by
`--agent` and `--interactive`) adds a second virtio console, on its own
virtio-serial bus, backed by a Unix socket; it comes second in device-tree
order, so the manifest names it `instance = 1`. All use the modern transport
(`-global virtio-mmio.force-legacy=false`).

**Real time:** `--realtime` (and `--interactive`) run QEMU without `-icount`,
one host thread per hart, so guest time is wall-clock time. Not
`-icount sleep=on`: with QEMU 8.2 and two harts that stalls the boot once a
hart-1 domain starts. Without `-icount`, OpenSBI's boot-hart lottery can
pick either hart; the kernel makes the boot hart logical hart 0 either way,
and repeated real-time runs cover both outcomes.

**Determinism with devices:** the kernel suite is byte-identical run to run.
For whole systems, the sequence of records is identical every run, but
instruction-level counters (context switches, profile averages) can vary a
little, because QEMU's rng backend reads its file on the host's I/O thread.
Bit-exact runs with devices need QEMU record/replay (`-icount rr=…`).

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
   forward, so timer tests take milliseconds. The flip side: a guest waiting
   on the host (an agent's next message) sees no time pass, which is why
   the agent run uses real time.

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

**Found while Phase 5 was built:**
- the two-boot disk test: under QEMU `-icount`, a machine with every hart
  idle and no timer never receives the host's I/O completion, so a disk
  flush waited forever; the kernel now keeps a 10 ms heartbeat when fully
  idle (ARCHITECTURE §2.5);
- the same test: Steward called the store to confirm the boot and would
  have deadlocked had the store faulted; Steward now never calls a domain
  (the store asks it, `ready`);
- the system run without a disk: clients of a skipped provider were minted
  live capabilities to an endpoint nobody serves, and blocked forever;
- the crash simulator first flagged a test scenario step that made two
  commits; then, mutated to drop the flush before the superblock write, it
  failed at once with a superblock pointing at a lost table;
- Envoy and Tablecloth overflowed their stacks (512-byte messages, a 250 KB
  store built on the stack): stacks are per-domain now (`stack_kib`), and
  the store mounts in place.

**Found while Phase 4 was built:**
- QEMU plus gdb (a hardware breakpoint on Steward's system-call stub, with
  a backtrace per hit): the dev system "hung" under two harts. It was busy,
  not stuck: every page-table change sent a remote TLB fence to the other
  hart, and Steward copies every program page through a scratch mapping.
  Flushes now go only to harts on the affected root (ARCHITECTURE §2.5).
- the agent run: records from two harts tore mid-line, because the debug
  console took 32 bytes per call; one call now writes a whole line
  (scenario test and a `long_write_ok` record the harness checks).
- real-time runs: the kernel panicked when firmware booted on hart 1.
- the QEMU trace (`-trace 'virtio_serial*'`): both virtconsoles sat on the
  first virtio-serial bus, so Envoy's device had no port; each now names
  its bus.

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

User space: a domain's program has its own symbols. To see what one is
doing, boot with `--qemu-arg=-s`, load the program (Steward is
`zig-out/bin/steward-system`) and put a *hardware* breakpoint on an address
in it (`llvm-objdump -d` finds one, e.g. the `ecall` of the inlined
system-call stub; other domains map different programs at the same
addresses, so pick one only that program uses). Each hit gives a source
backtrace:

```sh
gdb-multiarch -batch zig-out/bin/steward-system -ex 'target remote :1234' \
    -ex 'hbreak *0x7e65e' -ex c -ex 'bt 12'
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
| 4 Envoy | the AI interface end to end | the harness is a **driver**: it opens Envoy's virtio console as a socket (`-chardev socket`) and runs an agent script of Envoy calls with expected typed results (`tools/agent_session.py`). `zig build run` plus grainsh or the MCP bridge is how to operate the OS interactively ✅ |
| 5 Storage and identity | Granary, Ledger, generations, Seal | virtio-blk images; power-cut injection (kill QEMU at random instructions, reboot, verify) |
| 6 Desktop | compositor, UI | virtio-gpu and virtio-input in QEMU, driven through QMP (`screendump`, `input-send-event`); the scene (`scene.v1`, through Envoy) is checked against screenshots ✅ |
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
