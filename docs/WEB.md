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
| The dev system | Steward, the drivers, the key-value store, Tablecloth on a disk, Kumara, the Ledger, consent and Envoy, and the desktop (Surf and the shell). The disk is kept in the browser. |
| The kernel test suite | The kernel with its test program as the root task; it powers off with a summary. |
| Failure handling | The faults system: a domain that crashes until Steward stops it, and a caller that gets an error instead of hanging. |

**The layout.** The machine fills the page; a drawer beside it (below it
on a narrow window) holds the system's text: Console, grainsh, Agent, Log
and Manifest, one tab each. A dot on the Console tab means the system said
something there while another tab was open (the passphrase prompt, an ask).

- **The desktop** (setups with a screen): Surf's screen on a canvas. Click
  it to give it the keyboard (keys go by their place on the keyboard, as a
  US layout); the pointer follows the mouse. The shell waits in the dock:
  click it, then type `help` or `whoami`. Click outside the canvas to type
  elsewhere again. **Full screen** shows the desktop alone (Esc leaves).
  **Paste** (Ctrl+V or Cmd+V on the desktop) and **Type text** type text
  into the window that has the keyboard, as keystrokes, a few at a time.
- **Console**: the system's own console (the first virtio console). The
  passphrase is typed here, and so are the owner's answers to the agent's
  asks. Typing is hidden unless "show" is ticked.
- **grainsh**: the structured shell of `tools/envoy.py`, ported to the page
  (`web/grainsh.js`). It talks Envoy's JSON-lines protocol over the second
  virtio console, with the same commands and output, and checks the audit
  chain with BLAKE3 from the WebAssembly module.
- **Agent**: Claude, with your Anthropic API key, acting on the system
  through Envoy. Its tools are what the MCP bridge of `tools/envoy.py`
  offers: each method of each capability the manifest leases to the agent
  (`store__put`, `scene__windows`, ...) and the Envoy verbs (`grain_ask`,
  `grain_plan`, `grain_apply`, `grain_undo`, `grain_observe`). It has that
  authority and no more: it cannot type at the console or on the desktop,
  and when it asks for an askable capability, you answer in the Console.
  Everything it does is in its audit log (`log` in grainsh) and the Ledger.
  Choose the model (Claude Opus 5.5 by default, Sonnet 5.5 or Haiku 5.5);
  its thinking is shown folded, its tool calls and their results in full.
- **System log**: the serial console, with `@caravan`/`@grain` records
  highlighted ("records only" hides the rest).
- **The manifest** of the setup, as written in Brix.

**Machine settings**: the number of harts (1, 2 or 4) beside the setup.
Time is real time (the browser's clock), so leases expire as they would on
a device.

**Settings** (kept in this browser): the screen's size (1024×768 up to
1920×1080, from the next boot; Surf lays the desktop out for it), scaling
(fit the window, or actual pixels), the page's theme, and the setup's
disk: **export** it as a raw image (what QEMU and `grain-disk` read),
**import** one (it replaces the disk), or **forget** it. The machine must
be off for these.

## How it works

- `emu/wasm.zig` is the module's host: it exports `grain_start`,
  `grain_run`, `grain_input`, `grain_key`, `grain_pointer`,
  `grain_button`, `grain_screen` and a few more, and imports the console,
  entropy (`crypto.getRandomValues`), the clock (`performance.now`), a
  "the disk was flushed" notice and "this rectangle of the screen
  changed". The machine code is the same as the
  native emulator's.
- `web/agent.js` is the agent: the Anthropic TypeScript SDK
  (`web/vendor/anthropic-sdk.mjs`, a pinned copy bundled by
  `tools/vendor_sdk.sh`, so no third party's script runs in a page that
  holds the key), a streaming tool loop, tools rebuilt from `discover` and
  `describe` for every message (grants and leases change), and each tool
  input checked against its schema before it reaches Envoy. Server-side
  fallback is on for Opus and Sonnet, so a declined request is retried on
  the model Anthropic recommends; an exchange that fails part-way is
  dropped from the conversation (what its tools did stays in the log).
- `web/worker.js` runs the machine in a Web Worker, a slice of about 30 ms
  at a time, so the page stays responsive; while every hart waits it
  sleeps until the next timer or input. The page hands it the desktop's
  canvas (`transferControlToOffscreen`); after each slice it copies the
  changed rectangles from the module's memory with `putImageData`.
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
  network device, and the page makes no requests after loading its files,
  except the agent panel's, when you use it: those go from your browser to
  `api.anthropic.com` with your key (billed to your account), carrying
  your messages and what the tools return. The key stays in the tab unless
  you tick "remember", which keeps it in this site's storage in your
  browser; anyone who can run script on the page could read it there, so
  on a shared computer leave it unticked.
- The browser's sandbox is the outer boundary, stronger than QEMU's on a
  workstation.
- The disk is encrypted by Tablecloth, but it is a demonstration: keep
  secrets out of it. Clearing the site's data in the browser deletes it.
- Not yet: two instances meeting (virtio-net).

## Tests

`zig build web-test` builds the site and drives it in headless Chromium
(Node and Playwright; `tools/web_test.mjs`): the kernel suite; the dev
system on a fresh disk, choosing a passphrase; grainsh listing capabilities
and using the store; an ask the owner approves in the console; the audit
chain verified in the page; the agent panel against a stand-in for the
API (its request carries the key, the model and the tools; the tool call
it asks for changes the store through Envoy; the thinking block goes back
unchanged); the desktop (the scene, read through Envoy,
matches the canvas's pixels; a click on the dock opens the shell; `whoami`
typed on the canvas runs; text pasted onto it arrives as keystrokes);
`bye`; then a reload in the same browser profile, where the disk
must still be there (the same identity, a wrong passphrase refused, the
right one accepted); the disk exported, forgotten and imported again (the
same identity after); and a boot with a 1280×800 screen.

## Publishing it (GitHub Pages)

`.github/workflows/web.yml` builds the site with release images on every
push to `main` (or when run by hand from Actions, on any branch; only
`main` is published), runs
`zig build test` and the browser test, and keeps the site as a workflow
artifact. To publish it as well, to a separate public repository (here
`node777/grain-www`):

1. Make a deploy key: `ssh-keygen -t ed25519 -N "" -C grain-pages -f grain-pages`.
2. In `node777/grain-www`: Settings → Deploy keys → Add deploy key, paste
   `grain-pages.pub`, and tick **Allow write access**.
3. In this repository: Settings → Secrets and variables → Actions. Under
   *Secrets*, a secret `PAGES_DEPLOY_KEY` holding the private key (the
   whole of `grain-pages`); under *Variables*, a variable `PAGES_REPO`
   holding `node777/grain-www`. Then delete both key files.

   With the GitHub CLI, the same from a terminal:
   ```sh
   gh repo deploy-key add grain-pages.pub -R node777/grain-www -t grain-pages -w
   gh secret set PAGES_DEPLOY_KEY -R node777/grain-os < grain-pages
   gh variable set PAGES_REPO -R node777/grain-os -b node777/grain-www
   rm grain-pages grain-pages.pub
   ```
4. Push to `main`, or Actions → web → Run workflow on `main`. The
   workflow pushes the site to `node777/grain-www`'s `gh-pages` branch.
5. In `node777/grain-www`: Settings → Pages → Build and deployment →
   Deploy from a branch → `gh-pages`, `/ (root)`. The site appears at
   `https://node777.github.io/grain-www/`.

The deploy key can write to that one repository and nothing else; this
repository can stay private. What gets published is the built site: the
page, the WebAssembly module and the compiled images (anyone can download
and disassemble them), not the source.
