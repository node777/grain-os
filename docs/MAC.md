# Grain OS on a Mac: getting ready, and using it safely

> **Status: not yet run on macOS.** Everything here comes from reading the
> code and the tools; the whole suite passes on Linux (QEMU 8.2). Section 2
> lists what should change in the repository first, section 9 what to send
> back when something breaks.

Grain runs on a Mac the way it runs everywhere today: inside QEMU, which
emulates a RISC-V computer in software. There is nothing to install into
macOS itself: no kernel extension, no hypervisor entitlement, no root.

## 1. What can reach your Mac, and what cannot

QEMU runs as your user. The guest (Grain) sees only the emulated hardware
QEMU gives it, and in `zig build run` that hardware has **no network card**.
Grain cannot see your files, your network, or other programs. These are the
only channels between the Mac and the guest:

| Channel | When | Who can use it | Note |
|---|---|---|---|
| Terminal output (serial console) | always | you | records and log lines |
| Your typing (virtio console) | `zig build run` | you | the passphrase goes this way, **visible on screen** (§6) |
| The Envoy socket, `$TMPDIR/grain-XXXX/envoy1.sock` | `zig build run` | your user only (the directory is mode 0700) | grainsh or an AI agent connects here; one client at a time |
| The disk image, `zig-out/run-disk.img` | `zig build run` | your user | encrypted with your passphrase, but see §6 |
| `/dev/urandom` (read only) | `zig build run` | QEMU | gives the guest real randomness for its keys |
| The window, and a QMP socket beside the Envoy socket | `-Ddisplay` | your user only | QMP controls QEMU itself; nothing exposes it to the agent |
| **A GDB stub on TCP port 1234, all interfaces** | `zig build debug` only | **anyone on your network** | fix before using (§2, item 2) |
| Two guests linked by Unix datagram sockets | `tools/pair.py` | the two guests | stays on your Mac |

So the outer safety boundary is QEMU. A bug in QEMU that let the guest out
would give it **your** user's rights (not root's). The guest only runs code
built from this repository, so that risk is small. Keep QEMU up to date
anyway, and never run QEMU or the build with `sudo`.

## 2. What should change in the repository first

None of these block a first try (section 4 has workarounds), but each one is
small, and the first three are about safety.

| # | Change | Why | Kind |
|---|---|---|---|
| 1 | `zig build debug`: QEMU's `-s` becomes `-gdb tcp:127.0.0.1:1234` | `-s` listens on every interface: anyone on the same Wi-Fi could attach a debugger to the guest | safety, one line |
| 2 | Read the passphrase without echoing it | today it shows in the terminal and stays in its scrollback | safety, small (harness.py) |
| 3 | Ask the owner before granting an agent an **askable** capability | today an `askable` lease is granted **at once** on the agent's first request: no question is put to you. In the dev system those are `tablecloth` (install or roll back system generations), `comlink` (meet other instances) and `entropy` | safety, a design change (a prompt on the console or the desktop) |
| 4 | `tools/setup.sh` learns macOS (Homebrew, the `aarch64-macos` Zig) | it handles only `apt` and Linux Zig, and on a Mac it stops with an error | convenience |
| 5 | A fixed Envoy socket path (`zig build run -Dsocket=PATH`) | the path changes on every run, so an MCP client's config must be edited each time | convenience |
| 6 | The harness deletes its temporary directory | test runs leave `$TMPDIR/grain-*` behind, some with 256 MiB disk copies | tidiness |
| 7 | Confirm the suite on Homebrew's QEMU (9.x or 10.x) and its Cocoa window | everything was tested on QEMU 8.2 with GTK | needs your Mac |

Unix socket paths are limited to 104 characters on macOS. The harness's
paths come to about 80 there, so they should fit; if you see `AF_UNIX path
too long`, run with `TMPDIR=/tmp`.

## 3. Install, without sudo

Apple Silicon or Intel both work: the RISC-V machine is emulated either way.

**Homebrew packages** (Homebrew installs as your user):

```sh
brew install qemu python@3.12
qemu-system-riscv64 --version     # note the version for your report
```

Homebrew's QEMU includes the OpenSBI firmware the boot uses
(`-bios default`).

**Zig 0.17.0, exactly.** Other versions will not build this tree. Unless
`brew info zig` shows exactly 0.17.0, install it into your home directory:

```sh
mkdir -p ~/opt/zig-0.17.0 && cd ~/opt
arch=aarch64            # Intel Mac: x86_64
curl -fLO https://ziglang.org/download/0.17.0/zig-$arch-macos-0.17.0.tar.xz
# Check the download against the published checksum:
curl -fsSL https://ziglang.org/download/index.json \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['0.17.0']['$arch-macos']['shasum'])"
shasum -a 256 zig-$arch-macos-0.17.0.tar.xz          # the two must match
tar -xJf zig-$arch-macos-0.17.0.tar.xz -C ~/opt/zig-0.17.0 --strip-components=1
echo 'export PATH="$HOME/opt/zig-0.17.0:$PATH"' >> ~/.zshrc && source ~/.zshrc
zig version                                           # 0.17.0
```

The checksum guards against a damaged download. For a check that the
release really is Zig's, ziglang.org also publishes a minisign signature
beside each tarball (`brew install minisign`, with the public key from
<https://ziglang.org/download/>). Downloading with `curl` rather than a
browser avoids Gatekeeper's quarantine prompts.

**Python.** The tools use the standard library only. `cryptography` is needed
just for the attestation check in `zig build qemu-test`; keep it in a
virtual environment, not in the system Python:

```sh
python3.12 -m venv ~/.venvs/grain && source ~/.venvs/grain/bin/activate
pip install cryptography
```

**The source.**

```sh
git clone https://github.com/node777/grain-os && cd grain-os
git checkout claude/grain-os-caravan-design-dbqp0x
```

Building runs the repository's `build.zig` with your rights, as every build
system does. Build only branches you trust.

**Optional:** keep the build cache and the disk image out of Time Machine:
`tmutil addexclusion .zig-cache zig-out`.

## 4. Check that it works

From quickest to fullest. Stop at the first failure and send it to me
(§9).

```sh
zig build                 # compiles everything (a few minutes the first time)
zig build test            # host tests, no VM: about 2 minutes
python3 tools/harness.py --expect "summary failed=0" zig-out/bin/caravan-ktest
                          # the kernel test suite in QEMU, a few seconds
zig build qemu-test       # every system test; much longer
```

Skip `zig build fuzz --fuzz=...` on the Mac: Zig's coverage-guided fuzzer
has only been used on Linux here (`zig build test` already runs a seeded
sweep of every fuzz target). Fuzzing also grew the build cache past 20 GB
on Linux; `.zig-cache` can always be deleted.

## 5. Use it

### In the terminal

```sh
zig build run
```

The first boot finds a blank disk and asks you to choose a passphrase (§6);
later boots ask for it to unlock the disk. The harness then prints the
Envoy socket path and the command to connect, for example:

```
harness: connect with: python3 tools/envoy.py shell --socket /var/folders/.../grain-ab12cd34/envoy1.sock
```

Run that command in a second terminal to get **grainsh**, the structured
shell (`help` lists the commands). `bye` ends the session and powers the
guest off; Ctrl-C in the first terminal stops QEMU at once.

### The desktop

```sh
zig build run -Ddisplay
```

The same boot, with the screen in a window (QEMU's Cocoa display). Type the
passphrase in the **terminal**, not the window. Click the shell in the dock;
it takes commands such as `whoami`, `store`, `ledger`, `get`, `put` and
`echo`.

### Each build is a generation

Every `zig build run` adds the new build to `zig-out/run-disk.img` and makes
it current; the build before stays the rollback target. Your passphrase,
identity and Ledger survive. `zig-out/bin/grain-disk show
zig-out/run-disk.img` shows what the disk holds.

### Claude as the operator (MCP)

`tools/envoy.py mcp` is an MCP server (stdio) that connects to the Envoy
socket. Start `zig build run` first, then point a client at the socket path
it printed. The path changes on every run until item 5 of §2 is done, so
update it each time.

Claude Code:

```sh
claude mcp add grain -- python3 /ABSOLUTE/PATH/grain-os/tools/envoy.py mcp --socket /PATH/PRINTED/envoy1.sock
```

Claude Desktop, in `~/Library/Application Support/Claude/claude_desktop_config.json`
(restart Claude Desktop afterwards):

```json
{
  "mcpServers": {
    "grain": {
      "command": "python3",
      "args": ["/ABSOLUTE/PATH/grain-os/tools/envoy.py", "mcp",
               "--socket", "/PATH/PRINTED/envoy1.sock"]
    }
  }
}
```

Only one client can hold the Envoy socket at a time: close grainsh before
connecting Claude, and the reverse.

## 6. Using it safely

**Treat the disk as a test disk.** Tablecloth encrypts it under your
passphrase, but that cryptography has had no outside review
(docs/CAPABILITY_MODEL.md lists what has). Keep real secrets and personal
data out of it.

**Use a throwaway passphrase.** Until item 2 of §2 is done it appears in
the terminal as you type it and stays in the scrollback. Choose one you use
nowhere else. `zig-out/bin/grain-disk passwd zig-out/run-disk.img` changes
it.

**Know what an agent can do.** Connected through MCP, an AI agent holds
exactly the leases in the `agent` block of `system/dev.brix`:

- from boot: `echo` (15 s), `store` (the key-value store), `console`
  (20 uses), `scene` (reads the screen as data), `attest` (signed reports
  of what booted);
- **on request, granted without asking you** (item 3 of §2): `entropy`
  (2 uses), `tablecloth` (upload, switch to and roll back system
  generations, so it can change what the guest boots next), `comlink`
  (meet other instances and lend them things).

To keep an agent away from any of these, delete its `askable` line in
`system/dev.brix` before `zig build run`. Whatever it does, it stays inside
the guest: nothing in the agent's reach touches your Mac's files or
network. Every action is recorded in an audit log (`grain_observe`), and
`grain_plan` dry-runs steps before `grain_apply`. Leave your MCP client's
per-call approval on. Methods that reach another instance (Comlink's
`share`, `call`, `fetch` and the like) are marked destructive, and those
that only read are marked read-only, so a client can treat them
differently.

**Don't expose the debugger.** Use `zig build debug` only after item 1 of
§2, or on a network you trust. If macOS asks whether QEMU may accept
incoming connections, choose **Deny**: GDB on the same Mac still connects.

**Run nothing as root.** Not the build, not QEMU, not the tools. Nothing here
needs it.

## 7. Resources

- QEMU takes 256 MiB of RAM and two emulated harts, and uses about one CPU
  core while the guest is busy.
- `zig-out/run-disk.img` is 256 MiB. `.zig-cache` grows with every build;
  delete it whenever you like (the next build is slower).
- Test runs leave `$TMPDIR/grain-*` directories (sockets, copies of disks):
  `rm -rf "$TMPDIR"/grain-*` while no Grain VM is running.

## 8. Starting over and removing it

- Start over with a new identity and passphrase: `rm zig-out/run-disk.img`.
- Remove everything: delete the repository folder, `~/opt/zig-0.17.0`,
  `~/.venvs/grain`, the `$TMPDIR/grain-*` directories, any `grain` entry in
  your MCP configuration (`claude mcp remove grain`), and the export line in
  `~/.zshrc`; then `brew uninstall qemu` if nothing else uses it.

## 9. If something breaks

| Symptom | Likely cause | Try |
|---|---|---|
| `tools/setup.sh` fails | it only knows Linux (item 4 of §2) | install by hand (§3) |
| Zig errors in the standard library | not Zig 0.17.0 | `zig version`, then §3 |
| `qemu-system-riscv64: command not found` | Homebrew's bin not on PATH | `eval "$(/opt/homebrew/bin/brew shellenv)"` |
| `AF_UNIX path too long` | long `$TMPDIR` | `TMPDIR=/tmp zig build run` |
| The boot hangs after `harness: Envoy socket` | waiting for the passphrase | type it in the terminal and press Return |
| No window with `-Ddisplay` | QEMU's display backend | send `qemu-system-riscv64 -display help` |
| A test fails in `qemu-test` only | QEMU 9/10 versus 8.2 | send the failing step's output |

To report a problem, send: `sw_vers`, `uname -m`, `zig version`,
`qemu-system-riscv64 --version`, `python3 --version`, the command you ran
and its last 50 lines of output.
