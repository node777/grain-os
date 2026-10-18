// The web page, in a real browser (headless Chromium through Playwright):
//   node tools/web_test.mjs zig-out/web
// Serves the directory, then: boots the kernel suite; boots the dev system on
// a fresh disk (choosing a passphrase), uses grainsh through Envoy (caps, a
// store call, an ask the owner answers in the console, the audit chain), says
// bye; reloads in the same browser profile and checks the disk persisted (the
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
  const ctx = await browser.newContext();
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
