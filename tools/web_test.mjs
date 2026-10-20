// The web page, in a real browser (headless Chromium through Playwright):
//   node tools/web_test.mjs zig-out/web
// Serves the directory, then: boots the kernel suite; boots the dev system on
// a fresh disk (choosing a passphrase), uses grainsh through Envoy (caps, a
// store call, an ask the owner answers in the console, the audit chain), has
// the agent panel act through Envoy (against a stand-in for the API), opens
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

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.wasm': 'application/wasm', '.brix': 'text/plain', '.elf': 'application/octet-stream' };
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

// A stand-in for the Messages API: each call answers with the next scripted
// turn, as a server-sent event stream.
function sseTurn(blocks, stop) {
  const ev = [{ type: 'message_start', message: { id: 'msg_test', type: 'message', role: 'assistant', model: 'claude-opus-5-5', content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 0 } } }];
  blocks.forEach((b, index) => {
    if (b.type === 'thinking') {
      ev.push({ type: 'content_block_start', index, content_block: { type: 'thinking', thinking: '', signature: '' } });
      ev.push({ type: 'content_block_delta', index, delta: { type: 'thinking_delta', thinking: b.thinking } });
      ev.push({ type: 'content_block_delta', index, delta: { type: 'signature_delta', signature: b.signature } });
    } else if (b.type === 'text') {
      ev.push({ type: 'content_block_start', index, content_block: { type: 'text', text: '' } });
      ev.push({ type: 'content_block_delta', index, delta: { type: 'text_delta', text: b.text } });
    } else {
      ev.push({ type: 'content_block_start', index, content_block: { type: 'tool_use', id: b.id, name: b.name, input: {} } });
      ev.push({ type: 'content_block_delta', index, delta: { type: 'input_json_delta', partial_json: JSON.stringify(b.input) } });
    }
    ev.push({ type: 'content_block_stop', index });
  });
  ev.push({ type: 'message_delta', delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 5 } });
  ev.push({ type: 'message_stop' });
  return ev.map((e) => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join('');
}
async function fakeApi(page, turns) {
  const seen = [];
  const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'POST, OPTIONS' };
  await page.route('https://api.anthropic.com/**', async (route) => {
    const req = route.request();
    if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: cors });
    seen.push({ headers: req.headers(), body: req.postDataJSON() });
    const turn = turns[Math.min(seen.length - 1, turns.length - 1)];
    await route.fulfill({ status: 200, headers: { ...cors, 'content-type': 'text/event-stream' }, body: turn });
  });
  return seen;
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

    // The agent panel, against a stand-in for the API: it asks for a store
    // call, Envoy runs it, and the result goes back with the thinking block
    // unchanged.
    const api = await fakeApi(page, [
      sseTurn([{ type: 'thinking', thinking: 'The owner wants 7 stored under key 3.', signature: 'sig-1' },
        { type: 'tool_use', id: 'toolu_1', name: 'store__put', input: { key: 3, value: 7 } }], 'tool_use'),
      sseTurn([{ type: 'text', text: 'Stored 7 under key 3.' }], 'end_turn'),
    ]);
    await page.fill('#agent-key', 'sk-ant-test-key');
    await page.fill('#agent-in', 'store 7 under key 3');
    await page.press('#agent-in', 'Enter');
    await until(page, 'agent-out', 'Stored 7 under key 3.', 120_000);
    const first = api[0], second = api[1];
    check('agent_request', first && first.headers['x-api-key'] === 'sk-ant-test-key' && first.headers['anthropic-dangerous-direct-browser-access'] === 'true'
      && first.body.model === 'claude-opus-5-5' && first.body.tools.some((t) => t.name === 'store__put') && first.body.tools.some((t) => t.name === 'grain_ask')
      && !first.body.tools.some((t) => t.name === 'grain_bye'), JSON.stringify(first && { headers: first.headers, model: first.body.model, tools: first.body.tools.map((t) => t.name) }));
    const back = second && second.body.messages;
    const toolResult = back && back[2] && back[2].content[0];
    check('agent_tool_ran', api.length === 2 && toolResult.tool_use_id === 'toolu_1' && !toolResult.is_error && toolResult.content.includes('had'), JSON.stringify(back));
    check('agent_thinking_kept', back && back[1].content[0].type === 'thinking' && back[1].content[0].signature === 'sig-1', JSON.stringify(back && back[1]));
    await shell(page, 'call store.get key=3', '"value":7');
    check('agent_changed_the_store', true);
    check('agent_shown', (await text(page, 'agent-out')).includes('→ store__put'), await text(page, 'agent-out'));
    await page.unroute('https://api.anthropic.com/**');

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
