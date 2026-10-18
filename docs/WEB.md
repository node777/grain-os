# Grain in a browser

The web page (`web/`) runs the system in a browser tab: `grain-emu`
(ARCHITECTURE §3.10), compiled to WebAssembly, boots the same kernel and
system images as QEMU. It is a static site: no server does anything but
hand out files.

## Try it locally

```sh
zig build web -Doptimize=ReleaseSafe     # zig-out/web: the page, the module, the images
python3 -m http.server -d zig-out/web 8000
# open http://localhost:8000
```

Any static file server works. Use a release build (`-Doptimize=ReleaseSafe`)
for anything but debugging the page: the dev system then reaches its
passphrase prompt in about a second and a half; a debug build takes tens of
seconds.

## What the page offers

**Setups** (`web/configs.json`): each names an image, the devices it gets
and a default number of harts.

| Setup | What it is |
|---|---|
| The dev system | Steward, the drivers, the key-value store, Tablecloth on a disk, Kumara, the Ledger, consent and Envoy. The disk is kept in the browser. |
| The kernel test suite | The kernel with its test program as the root task; it powers off with a summary. |
| Failure handling | The faults system: a domain that crashes until Steward stops it, and a caller that gets an error instead of hanging. |

**Panels:**

- **Console**: the system's own console (the first virtio console). The
  passphrase is typed here, and so are the owner's answers to the agent's
  asks. Typing is hidden unless "show" is ticked.
- **grainsh**: the structured shell of `tools/envoy.py`, ported to the page
  (`web/grainsh.js`). It talks Envoy's JSON-lines protocol over the second
  virtio console, with the same commands and output, and checks the audit
  chain with BLAKE3 from the WebAssembly module.
- **System log**: the serial console, with `@caravan`/`@grain` records
  highlighted ("records only" hides the rest).
- **The manifest** of the setup, as written in Brix.

**Machine settings**: the number of harts (1, 2 or 4). Time is real time
(the browser's clock), so leases expire as they would on a device.

## How it works

- `emu/wasm.zig` is the module's host: it exports `grain_start`,
  `grain_run`, `grain_input` and a few more, and imports the console,
  entropy (`crypto.getRandomValues`), the clock (`performance.now`) and a
  "the disk was flushed" notice. The machine code is the same as the
  native emulator's.
- `web/worker.js` runs the machine in a Web Worker, a slice of about 30 ms
  at a time, so the page stays responsive; while every hart waits it
  sleeps until the next timer or input.
- **The disk** lives in the module's memory while the machine runs. Each
  4 KiB block written is marked; when the guest flushes, the worker saves
  the marked blocks to IndexedDB (database `grain`, one record per block),
  and loads them back before the next boot. A new disk is all zeros:
  Tablecloth formats it and asks for a passphrase. "Forget disk" deletes a
  setup's blocks.
- About 120-140 million guest instructions per second in Chromium (as fast
  as the native build). While the system waits for the owner, a few
  million per second.

## What it is, and is not

- Everything runs in the tab. Nothing is sent anywhere: there is no
  network device, and the page makes no requests after loading its files.
- The browser's sandbox is the outer boundary, stronger than QEMU's on a
  workstation.
- The disk is encrypted by Tablecloth, but it is a demonstration: keep
  secrets out of it. Clearing the site's data in the browser deletes it.
- Not yet: the desktop (virtio-gpu and virtio-input in the emulator), two
  instances meeting (virtio-net), and an AI agent connected to the page.

## Tests

`zig build web-test` builds the site and drives it in headless Chromium
(Node and Playwright; `tools/web_test.mjs`): the kernel suite; the dev
system on a fresh disk, choosing a passphrase; grainsh listing capabilities
and using the store; an ask the owner approves in the console; the audit
chain verified in the page; `bye`; then a reload in the same browser
profile, where the disk must still be there (the same identity, a wrong
passphrase refused, the right one accepted).

## Publishing it (GitHub Pages)

`.github/workflows/web.yml` builds the site with release images on every
push to `main` (and on pull requests, without publishing), runs
`zig build test` and the browser test, and keeps the site as a workflow
artifact. To publish it as well, to a separate public repository:

1. Create the public repository (say `you/grain-os-web`), empty.
2. Make a deploy key for it: `ssh-keygen -t ed25519 -N "" -f grain-pages`.
   Add `grain-pages.pub` to the public repository (Settings → Deploy keys)
   **with write access**.
3. In this repository (Settings → Secrets and variables → Actions): a
   secret `PAGES_DEPLOY_KEY` holding the private key `grain-pages`, and a
   variable `PAGES_REPO` holding `you/grain-os-web`. Then delete the local
   key files.
4. Run the workflow (or push to `main`). It pushes the site to the public
   repository's `gh-pages` branch.
5. In the public repository: Settings → Pages → Deploy from a branch →
   `gh-pages`, `/ (root)`. The site appears at
   `https://you.github.io/grain-os-web/`.

The deploy key can write to that one repository and nothing else; this
repository can stay private. What gets published is the built site: the
page, the WebAssembly module and the compiled images (anyone can download
and disassemble them), not the source.
