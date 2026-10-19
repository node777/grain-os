// The web page, in a real browser (headless Chromium through Playwright):
//   node tools/web_test.mjs zig-out/web
// Serves the directory, then: boots the kernel suite; boots the dev system on
// a fresh disk (choosing a passphrase), uses grainsh through Envoy (caps, a
// store call, an ask the owner answers in the console, the audit chain), opens
// the shell from the desktop's dock with a click on the canvas and types a
// command there (holding the scene, read through Envoy, against the pixels),
// says bye; reloads in the same browser profile and checks the disk persisted (the
// same identity, a wrong passphrase refused, the right one accepted).
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { createRequire } from 'node:module';

const root = path.resolve(process.argv[2] || 'zig-out/web');
const require = createRequire(import.meta.url);
const { chromium } = require(path.join(execSync('npm root -g').toString().trim(), 'playwright'));

const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.wasm': 'application/wasm', '.brix': 'text/plain', '.elf': 'application/octet-stream' };
const server = http.createServer((req, res) => {
  const p = path.join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname));
  const file = p.endsWith('/') ? path.join(p, 'index.html') : p;
  if (!file.startsWith(root) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}/`;

let failed = 0;
function check(name, ok, detail = '') {
  console.log(`@web check name=${name} result=${ok ? 'pass' : 'fail'}${ok ? '' : ` detail=${JSON.stringify(String(detail).slice(-400))}`}`);
  if (!ok) failed++;
}

const LONG = 600_000; // debug images boot slowly; release ones in seconds
const text = (page, id) => page.$eval(`#${id}`, (e) => e.textContent);
async function until(page, id, needle, timeout = LONG) {
  await page.waitForFunction(([i, n]) => document.getElementById(i).textContent.includes(n), [id, needle], { timeout, polling: 200 });
}
async function shell(page, line, needle) {
  await page.fill('#shell-in', line);
  await page.press('#shell-in', 'Enter');
  if (needle) await until(page, 'shell-out', needle, 120_000);
  await page.waitForFunction(() => !document.getElementById('shell-in').disabled, null, { timeout: 120_000 });
}
// One grainsh call; its JSON result.
async function call(page, line) {
  const before = (await text(page, 'shell-out')).length;
  await shell(page, `call ${line}`);
  const out = (await text(page, 'shell-out')).slice(before).trim().split('\n');
  return JSON.parse(out[out.length - 1]);
}
async function elements(page, window) {
  const n = (await call(page, `scene.window index=${window}`)).elements;
  const all = [];
  for (let i = 0; i < n; i++) all.push({ ...(await call(page, `scene.element window=${window} index=${i}`)), index: i });
  return all;
}
// The canvas as the browser shows it, read back as RGBA at the machine's resolution.
async function screenshot(page) {
  const png = (await page.locator('#screen').screenshot()).toString('base64');
  return page.evaluate(async (data) => {
    const img = new Image();
    img.src = `data:image/png;base64,${data}`;
    await img.decode();
    const c = new OffscreenCanvas(1024, 768);
    const g = c.getContext('2d');
    g.imageSmoothingEnabled = false;
    g.drawImage(img, 0, 0, 1024, 768);
    return Array.from(g.getImageData(0, 0, 1024, 768).data);
  }, png);
}
const pixel = (img, x, y) => { const i = (y * 1024 + x) * 4; return (img[i] << 16) | (img[i + 1] << 8) | img[i + 2]; };
async function clickScreen(page, x, y) {
  await page.locator('#screen').scrollIntoViewIfNeeded();
  const box = await page.locator('#screen').boundingBox();
  await page.mouse.click(box.x + (x + 0.5) * box.width / 1024, box.y + (y + 0.5) * box.height / 768);
}

async function typeConsole(page, line) {
  await page.fill('#console-in', line);
  await page.press('#console-in', 'Enter');
}

const browser = await chromium.launch();
try {
  // 1. The kernel suite.
  {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    page.on('pageerror', (e) => check('no_page_errors', false, e.message));
    await page.goto(`${base}?config=ktest&harts=2&autostart=1`);
    await page.waitForFunction(() => document.body.dataset.exit !== undefined && document.body.dataset.exit !== '', null, { timeout: LONG, polling: 500 });
    const log = await text(page, 'log-out');
    check('kernel_suite', log.includes('summary tests=18 failed=0') && (await page.$eval('body', (b) => b.dataset.exit)) === '0', log);
    await ctx.close();
  }

  // 2. The dev system on a fresh disk, then 3. again on the same disk.
  const ctx = await browser.newContext({ viewport: { width: 1400, height: 1100 } });
  {
    const page = await ctx.newPage();
    page.on('pageerror', (e) => check('no_page_errors', false, e.message));
    await page.goto(`${base}?config=dev&autostart=1`);
    await until(page, 'console-out', 'Choose a passphrase');
    await typeConsole(page, 'open sesame');
    await until(page, 'console-out', 'once more');
    await typeConsole(page, 'open sesame');
    await until(page, 'log-out', 'kumara_ready');
    const log = await text(page, 'log-out');
    const name = /kumara_ready domain=kumara name=(\S+) .* created=true/.exec(log);
    check('identity_created', name !== null, log);
    await shell(page, 'caps', 'kv.v1');
    check('grainsh_caps', (await text(page, 'shell-out')).includes('entropy.v1'));
    await shell(page, 'call store.put key=9 value=90', '"had"');
    await shell(page, 'call store.get key=9', '"value":90');
    check('grainsh_store', true);
    // An ask: the owner answers yes in the console.
    await page.fill('#shell-in', 'ask entropy for a nonce');
    await page.press('#shell-in', 'Enter');
    await until(page, 'console-out', "asks for 'entropy'", 120_000);
    await typeConsole(page, 'yes');
    await until(page, 'shell-out', '"granted":true', 120_000);
    check('owner_approves_ask', (await text(page, 'console-out')).includes('Allowed.'));
    await page.waitForFunction(() => !document.getElementById('shell-in').disabled, null, { timeout: 60_000 });
    await shell(page, 'call entropy.get', '"bytes"');
    await shell(page, 'log', 'hash chain:');
    check('audit_chain_verified_in_page', (await text(page, 'shell-out')).includes('hash chain: verified'), await text(page, 'shell-out'));

    // The desktop: what the scene says is on the screen is in the canvas.
    await until(page, 'log-out', 'surf_ready');
    check('desktop_up', /surf_ready domain=surf width=1024 height=768 screen=virtio keyboard=true pointer=true/.test(await text(page, 'log-out')), await text(page, 'log-out'));
    const desk = await elements(page, 0);
    const launcher = desk.find((e) => e.role === 'launcher' && e.text === 'shell');
    check('launcher_in_scene', launcher !== undefined, JSON.stringify(desk));
    await page.waitForTimeout(500); // the last frame drawn
    const img = await screenshot(page);
    const fills = desk.filter((e) => (e.kind === 'fill' || e.kind === 'panel') && e.w > 8 && e.h > 8 && !e.text);
    const bad = [];
    let compared = 0;
    for (const e of fills) {
      const px = e.x + Math.max(1, e.w >> 3), py = e.y + (e.h >> 1);
      const top = await call(page, `scene.at x=${px} y=${py}`);
      if (top.window !== 0 || top.element !== e.index) continue;
      compared++;
      if (pixel(img, px, py) !== e.color) bad.push([e.index, e.role, e.color.toString(16), pixel(img, px, py).toString(16)]);
    }
    check('canvas_matches_scene', compared > 0 && bad.length === 0, JSON.stringify({ compared, bad }));
    // Open the shell from the dock, as the owner would, and type into it.
    const shown = (await text(page, 'log-out')).length;
    await clickScreen(page, launcher.x + (launcher.w >> 1), launcher.y + (launcher.h >> 1));
    await page.waitForFunction((n) => /surf_window_shown [^@]*title=shell/.test(document.getElementById('log-out').textContent.slice(n)), shown, { timeout: 120_000, polling: 200 });
    check('shell_opened', (await call(page, 'scene.window index=1')).shown === true);
    await page.locator('#screen').focus(); // the grainsh call took the keyboard
    await page.keyboard.type('whoami');
    await page.keyboard.press('Enter');
    await page.waitForFunction(() => /shell_ran [^@]*command=whoami ok=true/.test(document.getElementById('log-out').textContent), null, { timeout: 120_000, polling: 200 });
    check('typed_on_canvas', true);

    await shell(page, 'bye', '"actions"');
    await page.waitForFunction(() => document.body.dataset.exit === '0', null, { timeout: LONG, polling: 500 });
    check('dev_powers_off_cleanly', (await text(page, 'log-out')).includes('summary') && !(await text(page, 'log-out')).includes('failed=1'));
    await page.close();
    var identity = name && name[1];
  }
  {
    const page = await ctx.newPage();
    await page.goto(`${base}?config=dev&autostart=1`);
    await until(page, 'log-out', '[page] disk "dev":');
    check('disk_persisted', (await text(page, 'log-out')).includes("blocks from this browser's storage"));
    await until(page, 'console-out', 'passphrase');
    check('disk_not_new', !(await text(page, 'console-out')).includes('this disk is new'), await text(page, 'console-out'));
    await typeConsole(page, 'wrong guess');
    await until(page, 'log-out', 'tablecloth_unlock_failed');
    await typeConsole(page, 'open sesame');
    await until(page, 'log-out', 'kumara_ready');
    const log = await text(page, 'log-out');
    check('same_identity', log.includes(`name=${identity} `) && log.includes('created=false'), log);
    await shell(page, 'call store.get key=9', '"value"');
    await shell(page, 'bye', '"actions"');
    await page.waitForFunction(() => document.body.dataset.exit === '0', null, { timeout: LONG, polling: 500 });
    await page.close();
  }
  await ctx.close();
} catch (e) {
  check('exception', false, e.stack || e);
} finally {
  await browser.close();
  server.close();
}
console.log(failed ? `web_test: ${failed} checks failed` : 'web_test: all checks passed');
process.exit(failed ? 1 : 0);
