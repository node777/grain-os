// The web page, in a real browser (headless Chromium through Playwright):
//   node tools/web_test.mjs zig-out/web
// Serves the directory, then: boots the kernel suite; boots the dev system on
// a fresh disk (choosing a passphrase), uses grainsh through Envoy (caps, a
// store call, an ask the owner answers in the console, the audit chain), has
// the agent panel act through Envoy (against a stand-in for the API), opens
// the shell from the desktop's dock with a click on the canvas and types a
// command there (holding the scene, read through Envoy, against the pixels),
// says bye; reloads in the same browser profile and checks the disk persisted (the
// same identity, a wrong passphrase refused, the right one accepted); exports the
// disk, forgets it and imports it back; boots with a larger screen. Along the way:
// the task manager restarts and stops domains, and Settings restyles the
// desktop and changes the passphrase (both kept across boots).
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
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
async function tab(page, name) {
  if (await page.$eval(`#${name}-panel`, (e) => e.hidden)) await page.click(`#tab-${name}`);
}
async function shell(page, line, needle) {
  await tab(page, 'shell');
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
/// The index of the window `owner` opened.
async function windowOf(page, owner) {
  const { count } = await call(page, 'scene.windows');
  for (let i = 1; i < count; i++) if ((await call(page, `scene.window index=${i}`)).owner === owner) return i;
  return -1;
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
async function toScreen(page, x, y) {
  const box = await page.locator('#screen').boundingBox();
  return [box.x + (x + 0.5) * box.width / 1024, box.y + (y + 0.5) * box.height / 768];
}
/// Press at one screen point, move to another, release: a drag.
async function dragScreen(page, x0, y0, x1, y1) {
  await page.locator('#screen').scrollIntoViewIfNeeded();
  await page.mouse.move(...await toScreen(page, x0, y0));
  await page.mouse.down();
  await page.mouse.move(...await toScreen(page, x1, y1), { steps: 6 });
  await page.mouse.up();
}
// The page keeps only the last few thousand log lines, so waits count lines
// in a copy of every line, kept by the test (watchLog, in each page).
const watchLog = () => {
  window.__lines = [];
  new MutationObserver((changes) => {
    for (const c of changes) for (const node of c.addedNodes) window.__lines.push(node.textContent);
  }).observe(document, { childList: true, subtree: true });
};
const logSince = (page, n, re, timeout = 120_000) => page.waitForFunction(([n, src]) => {
  const r = new RegExp(src);
  return window.__lines.slice(n).some((l) => r.test(l));
}, [n, re.source], { timeout, polling: 200 });
const logLength = (page) => page.evaluate(() => window.__lines.length);

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
  await tab(page, 'console');
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
  const ctx = await browser.newContext({ viewport: { width: 1600, height: 1100 }, acceptDownloads: true });
  await ctx.addInitScript(watchLog);
  {
    const page = await ctx.newPage();
    page.on('pageerror', (e) => check('no_page_errors', false, e.message));
    await page.goto(`${base}?config=dev&autostart=1&scale=actual`);
    await until(page, 'console-out', 'Choose a passphrase');
    await typeConsole(page, 'open sesame');
    await until(page, 'console-out', 'once more');
    await typeConsole(page, 'open sesame');
    await until(page, 'log-out', 'kumara_ready');
    const log = await text(page, 'log-out');
    const name = /kumara_ready domain=kumara name=(\S+) .* created=true/.exec(log);
    const identityNow = name && name[1];
    check('identity_created', name !== null, log);
    await shell(page, 'caps', 'kv.v1');
    check('grainsh_caps', (await text(page, 'shell-out')).includes('entropy.v1'));
    await shell(page, 'call store.put key=9 value=90', '"had"');
    await shell(page, 'call store.get key=9', '"value":90');
    check('grainsh_store', true);
    // An ask: the owner answers yes in the console.
    await tab(page, 'shell');
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
    await tab(page, 'agent');
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
    const shellWin = await windowOf(page, 'shell');
    check('apps_have_windows', shellWin > 0 && (await windowOf(page, 'tasks')) > 0, shellWin);
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
    check('shell_opened', (await call(page, `scene.window index=${shellWin}`)).shown === true);
    await page.locator('#screen').focus(); // the grainsh call took the keyboard
    await page.keyboard.type('whoami');
    await page.keyboard.press('Enter');
    await page.waitForFunction(() => /shell_ran [^@]*command=whoami ok=true/.test(document.getElementById('log-out').textContent), null, { timeout: 120_000, polling: 200 });
    check('typed_on_canvas', true);
    // Text pasted onto the desktop arrives as keystrokes, shifted ones too.
    await page.$eval('#screen', (c) => {
      const data = new DataTransfer();
      data.setData('text/plain', 'echo Pasted, with CAPS & symbols!\n');
      c.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
    });
    await page.waitForFunction(() => /shell_ran [^@]*command=echo ok=true/.test(document.getElementById('log-out').textContent), null, { timeout: 120_000, polling: 200 });
    const echoed = (await elements(page, shellWin)).some((e) => e.text === 'Pasted, with CAPS & symbols!');
    check('pasted_on_canvas', echoed);

    // Windows: drag by the title bar, resize from the corner, minimize, close.
    let f = await call(page, `scene.window index=${shellWin}`);
    let n = await logLength(page);
    await dragScreen(page, f.x + 60, f.y + 12, f.x + 160, f.y + 62);
    await logSince(page, n, /surf_window_moved [^@]*owner=shell/);
    let g = await call(page, `scene.window index=${shellWin}`);
    check('window_dragged', g.x === f.x + 100 && g.y === f.y + 50 && g.w === f.w, JSON.stringify([f, g]));
    n = await logLength(page);
    await dragScreen(page, g.x + g.w - 5, g.y + g.h - 5, g.x + g.w + 75, g.y + g.h + 35);
    await logSince(page, n, /surf_window_resized [^@]*owner=shell width=720 height=444/);
    await logSince(page, n, /surf_presented [^@]*owner=shell/);
    f = await call(page, `scene.window index=${shellWin}`);
    const prompt = (await elements(page, shellWin)).find((e) => e.role === 'prompt');
    check('window_resized', f.w === g.w + 80 && f.h === g.h + 40 && prompt && prompt.y > f.y + f.h - 60, JSON.stringify([g, f, prompt]));
    n = await logLength(page);
    await clickScreen(page, f.x + f.w - 6 - 4 - 16 - 6 - 8, f.y + 15); // "-"
    await logSince(page, n, /surf_window_hidden [^@]*title=shell/);
    check('window_minimized', !(await call(page, `scene.window index=${shellWin}`)).shown);
    n = await logLength(page);
    await clickScreen(page, launcher.x + (launcher.w >> 1), launcher.y + (launcher.h >> 1));
    await logSince(page, n, /surf_window_shown [^@]*title=shell/);
    f = await call(page, `scene.window index=${shellWin}`);
    check('window_restored_in_place', f.shown && f.x === g.x && f.w === g.w + 80, JSON.stringify(f));
    n = await logLength(page);
    await clickScreen(page, f.x + f.w - 6 - 4 - 8, f.y + 15); // "x"
    await logSince(page, n, /surf_window_closed [^@]*title=shell/);
    check('window_closed', !(await call(page, `scene.window index=${shellWin}`)).shown);

    // The task manager: every domain, restart one, stop and restart another.
    const tasksWin = await windowOf(page, 'tasks');
    const tasksLauncher = (await elements(page, 0)).find((e) => e.role === 'launcher' && e.text === 'tasks');
    n = await logLength(page);
    await clickScreen(page, tasksLauncher.x + (tasksLauncher.w >> 1), tasksLauncher.y + (tasksLauncher.h >> 1));
    await logSince(page, n, /surf_window_shown [^@]*title=tasks/);
    await logSince(page, n, /surf_presented [^@]*owner=tasks/);
    let tw = await elements(page, tasksWin);
    const cells = tw.filter((e) => e.role === 'cell').map((e) => e.text);
    check('tasks_lists_domains', ['console', 'store', 'hello'].every((d) => cells.includes(d)) && tw.some((e) => e.role === 'column' && e.text === 'cpu'), JSON.stringify(cells));
    const clickCell = async (text) => { const c = tw.find((e) => e.role === 'cell' && e.text === text); await clickScreen(page, c.x + 4, c.y + 6); };
    const clickButton = async (text) => { const b = tw.find((e) => e.role === 'button' && e.text === text); await clickScreen(page, b.x + (b.w >> 1), b.y + (b.h >> 1)); };
    const settle = async (re) => { await logSince(page, n, re); await page.waitForTimeout(1500); tw = await elements(page, tasksWin); };
    n = await logLength(page);
    await clickCell('hello');
    await settle(/surf_presented [^@]*owner=tasks/);
    n = await logLength(page);
    await clickButton('Restart');
    await settle(/domain_exit domain=hello /);
    check('tasks_restarts_a_task', /domain_restart domain=hello by=tasks was=exited/.test(await text(page, 'log-out')));
    n = await logLength(page);
    await clickCell('store');
    await settle(/surf_presented [^@]*owner=tasks/);
    n = await logLength(page);
    await clickButton('Stop');
    await settle(/taskman_action [^@]*action=stop domain=store ok=true/);
    check('tasks_stops_a_service', tw.some((e) => e.role === 'cell' && e.text === 'stopped'), JSON.stringify(tw.filter((e) => e.role === 'cell').map((e) => e.text)));
    n = await logLength(page);
    await clickButton('Restart');
    await settle(/domain_start domain=store [^@]*restart=1/);
    // Its clients have their capabilities again: the shell reads the store.
    n = await logLength(page);
    await clickScreen(page, launcher.x + (launcher.w >> 1), launcher.y + (launcher.h >> 1));
    await logSince(page, n, /surf_window_shown [^@]*title=shell/);
    await page.locator('#screen').focus();
    await page.keyboard.type('get 9');
    await page.keyboard.press('Enter');
    await logSince(page, n, /shell_ran [^@]*command=get ok=true/);
    check('store_back_for_its_clients', true);

    // Settings: the system as it is, the desktop's style, the passphrase.
    const setWin = await windowOf(page, 'settings');
    const setLauncher = (await elements(page, 0)).find((e) => e.role === 'launcher' && e.text === 'settings');
    n = await logLength(page);
    await clickScreen(page, setLauncher.x + (setLauncher.w >> 1), setLauncher.y + (setLauncher.h >> 1));
    await logSince(page, n, /surf_window_shown [^@]*title=settings/);
    await logSince(page, n, /surf_presented [^@]*owner=settings/);
    let sw = await elements(page, setWin);
    check('settings_shows_identity', sw.some((e) => e.role === 'value' && e.text === identityNow), JSON.stringify(sw.filter((e) => e.role === 'value').map((e) => e.text)));
    const press = async (role, label) => {
      const e = sw.find((x) => x.role === role && x.text === label);
      await clickScreen(page, e.x + (e.w >> 1), e.y + (e.h >> 1));
    };
    const settled = async (re) => {
      try { await logSince(page, n, re, 180_000); } catch (e) {
        if (process.env.WEB_TEST_SHOTS) await page.locator('#screen').screenshot({ path: path.join(process.env.WEB_TEST_SHOTS, 'settings-stuck.png') });
        const now = await elements(page, setWin);
        check('settings_settled', false, JSON.stringify({ waiting: re.source, focus: await call(page, 'scene.windows'), roles: now.map((x) => `${x.role}:${x.text}`), log: await page.evaluate(() => window.__lines.slice(-12)) }));
        throw e;
      }
      await page.waitForTimeout(1200);
      sw = await elements(page, setWin);
    };
    n = await logLength(page);
    await press('tab', 'Desktop');
    await settled(/surf_presented [^@]*owner=settings/);
    n = await logLength(page);
    await press('button', 'Daylight');
    await settled(/settings_style [^@]*style=daylight/);
    await logSince(page, n, /surf_presented [^@]*owner=shell/);
    const deskBg = (await elements(page, 0)).find((e) => e.role === 'background');
    const shellBg = (await elements(page, shellWin)).find((e) => e.role === 'background');
    check('daylight_everywhere', deskBg.color === 0xe4ddd0 && shellBg.color === 0xf6f1e8 && sw.find((e) => e.role === 'background').color === 0xf6f1e8,
      JSON.stringify([deskBg.color.toString(16), shellBg.color.toString(16)]));
    n = await logLength(page);
    await press('tab', 'Security');
    await settled(/surf_presented [^@]*owner=settings/);
    // The first time, click into the first field; after that, the focus is
    // on the last one (Enter was pressed there), and Tab wraps to the first.
    const typePassphrases = async (current, first) => {
      if (first) {
        const input = sw.find((e) => e.role === 'input');
        await clickScreen(page, input.x + 20, input.y + (input.h >> 1));
      }
      await page.locator('#screen').focus();
      if (!first) await page.keyboard.press('Tab');
      // At a person's pace: late in this run the system is busy, and a
      // burst of keys into a 1%-budget app has come out unequal.
      for (const [i, t] of [current, 'new sesame', 'new sesame'].entries()) {
        await page.keyboard.type(t, { delay: 40 });
        await page.keyboard.press(i < 2 ? 'Tab' : 'Enter');
      }
    };
    n = await logLength(page);
    await typePassphrases('not it', true);
    await settled(/tablecloth_passphrase_refused/);
    check('settings_refuses_a_wrong_passphrase', sw.some((e) => e.role === 'note' && e.text === 'That is not the current passphrase.'), JSON.stringify(sw.filter((e) => e.role === 'note')));
    n = await logLength(page);
    await typePassphrases('open sesame', false);
    // Two key derivations on the store's budget: give it time, and say what
    // the system was doing if it never answers.
    try { await logSince(page, n, /settings_passphrase [^@]*changed=/, 300_000); } catch (e) {
      check('settings_answers_a_passphrase_change', false, JSON.stringify(await page.evaluate(() => window.__lines.slice(-25))));
      throw e;
    }
    await page.waitForTimeout(1200);
    sw = await elements(page, setWin);
    const lines = (await page.$eval('#log-out', (e) => Array.from(e.children, (c) => c.textContent))).filter((t) => /passphrase/.test(t)).slice(-6);
    check('settings_changes_the_passphrase', lines.some((t) => /tablecloth_passphrase_changed [^@]*by=settings/.test(t)) && sw.some((e) => e.role === 'note' && e.text.startsWith('Passphrase changed')),
      JSON.stringify({ lines, notes: sw.filter((e) => e.role === 'note').map((e) => e.text) }));

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
    await typeConsole(page, 'open sesame'); // the old one: changed in Settings
    await until(page, 'log-out', 'tablecloth_unlock_failed');
    await typeConsole(page, 'new sesame');
    await until(page, 'log-out', 'kumara_ready');
    const log = await text(page, 'log-out');
    check('same_identity', log.includes(`name=${identity} `) && log.includes('created=false'), log);
    await until(page, 'log-out', 'settings_restored');
    check('style_kept_across_boots', /settings_restored [^@]*style=daylight/.test(await text(page, 'log-out')) && /surf_restyled [^@]*style=daylight/.test(await text(page, 'log-out')));
    await shell(page, 'call store.get key=9', '"value"');
    await shell(page, 'bye', '"actions"');
    await page.waitForFunction(() => document.body.dataset.exit === '0', null, { timeout: LONG, polling: 500 });

    // 4. Export the disk, forget it, import it back: the same instance.
    page.on('dialog', (d) => d.accept());
    await page.click('#open-settings');
    const [download] = await Promise.all([page.waitForEvent('download'), page.click('#disk-export')]);
    const saved = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'grain-web-')), 'grain-dev.img');
    await download.saveAs(saved);
    const bytes = fs.readFileSync(saved);
    check('disk_exported', download.suggestedFilename() === 'grain-dev.img' && bytes.length === 64 * 1024 * 1024 && bytes.some((b) => b !== 0), bytes.length);
    await page.click('#forget');
    await page.setInputFiles('#disk-file', saved);
    await until(page, 'status', 'Imported grain-dev.img', 60_000);
    fs.rmSync(path.dirname(saved), { recursive: true, force: true });
    await page.click('#settings button.primary');
    await page.close();
  }
  {
    const page = await ctx.newPage();
    await page.goto(`${base}?config=dev&autostart=1`);
    await until(page, 'console-out', 'passphrase');
    await typeConsole(page, 'new sesame');
    await until(page, 'log-out', 'kumara_ready');
    check('disk_imported_same_identity', (await text(page, 'log-out')).includes(`name=${identity} `), await text(page, 'log-out'));
    await shell(page, 'bye', '"actions"');
    await page.waitForFunction(() => document.body.dataset.exit === '0', null, { timeout: LONG, polling: 500 });
    await page.close();
  }
  await ctx.close();

  // 5. A larger screen, chosen in the settings (here by the URL).
  {
    const big = await browser.newContext({ viewport: { width: 1600, height: 1100 } });
    const page = await big.newPage();
    page.on('pageerror', (e) => check('no_page_errors', false, e.message));
    await page.goto(`${base}?config=dev&autostart=1&size=1280x800`);
    await until(page, 'log-out', 'surf_ready');
    check('screen_1280x800', /surf_ready domain=surf width=1280 height=800 /.test(await text(page, 'log-out')), await text(page, 'log-out'));
    await big.close();
  }
} catch (e) {
  check('exception', false, e.stack || e);
} finally {
  await browser.close();
  server.close();
}
console.log(failed ? `web_test: ${failed} checks failed` : 'web_test: all checks passed');
process.exit(failed ? 1 : 0);
