#!/usr/bin/env node
// Loads the running preview in headless Chrome and reports console errors/warnings.
//   node tools/check-preview.js [--url http://localhost:5173] [--wait 4] [--shot out.png] [--eval "js"]
// Needs Google Chrome (macOS default path) or CHROME=/path/to/chrome. No npm dependencies.

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const URL_ = opt('--url', 'http://localhost:5173');
const WAIT = Number(opt('--wait', 4));
const SHOT = opt('--shot', null);
const EVAL = opt('--eval', null);
const W = Number(opt('--width', 1600)), H = Number(opt('--height', 1000));
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = 9300 + Math.floor(Math.random() * 500);

const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'preview-check-'));
const chrome = spawn(CHROME, [
  '--headless=new', `--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`,
  `--window-size=${W},${H}`, '--no-first-run', '--no-default-browser-check', 'about:blank',
], { stdio: 'ignore' });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  let target;
  for (let i = 0; i < 50 && !target; i++) {
    await sleep(200);
    try {
      const list = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
      target = list.find((t) => t.type === 'page');
    } catch { /* not up yet */ }
  }
  if (!target) throw new Error('Chrome DevTools not reachable');

  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener('open', r, { once: true }));
  let id = 0;
  const pending = new Map();
  const messages = [];
  ws.addEventListener('message', (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); return; }
    if (msg.method === 'Runtime.consoleAPICalled') {
      const text = msg.params.args.map((a) => a.value ?? a.description ?? '').join(' ');
      messages.push(`[console.${msg.params.type}] ${text}`);
    } else if (msg.method === 'Runtime.exceptionThrown') {
      const d = msg.params.exceptionDetails;
      messages.push(`[exception] ${d.exception?.description || d.text} (${d.url || ''}:${d.lineNumber})`);
    } else if (msg.method === 'Log.entryAdded') {
      const e = msg.params.entry;
      if (e.level === 'error' || e.level === 'warning') messages.push(`[${e.level}] ${e.text} ${e.url || ''}`);
    }
  });
  const send = (method, params = {}) => new Promise((resolve) => {
    const mid = ++id;
    pending.set(mid, resolve);
    ws.send(JSON.stringify({ id: mid, method, params }));
  });

  await send('Runtime.enable');
  await send('Log.enable');
  await send('Page.enable');
  await send('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: 1, mobile: false });
  await send('Page.navigate', { url: URL_ });
  await sleep(WAIT * 1000);

  const appState = await send('Runtime.evaluate', {
    expression: `JSON.stringify({ error: document.querySelector('#errorBox')?.style.display === 'block' ? document.querySelector('#errorBox').innerText : null,
      stat: document.querySelector('#stat')?.textContent,
      console: [...document.querySelectorAll('#console > div:not(.panelTitle)')].map(d => d.className + ': ' + d.textContent).slice(-30) })`,
    returnByValue: true,
  });
  const state = JSON.parse(appState.result.result.value || '{}');

  if (EVAL) {
    const r = await send('Runtime.evaluate', { expression: EVAL, returnByValue: true, awaitPromise: true, replMode: true });
    console.log('eval:', JSON.stringify(r.result.result.value ?? r.result.result.description));
    await sleep(1500);
  }
  if (SHOT) {
    const shot = await send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(SHOT, Buffer.from(shot.result.data, 'base64'));
    console.log('screenshot:', SHOT);
  }

  console.log('stat:', state.stat);
  console.log('preview console:\n  ' + (state.console || []).join('\n  '));
  if (state.error) console.log('ERROR OVERLAY:\n' + state.error);
  console.log(messages.length ? 'browser console:\n  ' + messages.join('\n  ') : 'browser console: no errors or warnings');
  ws.close();
  return messages.some((m) => /exception|error/.test(m)) || state.error ? 1 : 0;
}

main()
  .then((code) => { chrome.kill(); process.exitCode = code; })
  .catch((e) => { console.error(e.message); chrome.kill(); process.exitCode = 2; })
  .finally(() => setTimeout(() => fs.rmSync(profile, { recursive: true, force: true }), 300));
