#!/usr/bin/env node
// Mini dev server for the dashboard preview. No npm dependencies.
//   node preview/serve.js [--port 5173] [--vrc <path to vrc_formula_alpha_2025_csp>]
//
// Serves the repo root, bundles all Lua sources for the browser (/api/bundle),
// lists fonts with their family names (/api/fonts), exposes the field schema
// parsed from sdk/lib.lua (/api/fields) and pushes reload events over SSE (/events).
//
// Dashboards: every dash/styles/<name>/dashboard.lua is one dashboard, plus VRC's original.

const http = require('http');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const ROOT = path.resolve(__dirname, '..');
const args = process.argv.slice(2);
const portArg = args.indexOf('--port');
const PORT = portArg >= 0 ? Number(args[portArg + 1]) : 5173;
const vrcArg = args.indexOf('--vrc');
const DASH_DIR = path.join(ROOT, 'dash');
const STYLES_DIR = path.join(DASH_DIR, 'styles');

// VRC's original display/lights scripts, read from the local car download (never copied
// into the repo). Lets the preview show the dashboard that's in the car today.
const VRC_DIR = path.resolve(vrcArg >= 0 ? args[vrcArg + 1]
  : path.join(ROOT, 'VRC_-_AC_-_FA_2025_-_V1.1', 'AC Files', 'content', 'cars', 'vrc_formula_alpha_2025_csp'),
'extension', 'data_override');
const HAS_VRC = fs.existsSync(path.join(VRC_DIR, 'display', 'styles'));
const VRC_FILES = ['display', 'lights', 'lights.lua'];
const VRC_FONTS = path.resolve(VRC_DIR, '..', '..', '..', '..', 'fonts'); // content/fonts

// Own dashboards: dash/styles/<name>/dashboard.lua, read fresh on every bundle so new ones show up live.
function listDashboards() {
  if (!fs.existsSync(STYLES_DIR)) return [];
  return fs.readdirSync(STYLES_DIR).sort()
    .filter((name) => fs.existsSync(path.join(STYLES_DIR, name, 'dashboard.lua')))
    .map((name) => ({ id: name, label: name, entry: `dash/styles/${name}/dashboard.lua` }));
}
if (!HAS_VRC && !listDashboards().length) {
  console.error('Nothing to show: no dash/styles/<name>/dashboard.lua and the VRC car was not found (--vrc <car folder>).');
  process.exit(1);
}

// Lua sources visible to `require` in the preview. Keys are paths relative to the
// script folder (repo root here, data_override/ in AC). Emulated car modules
// (like VRC's `can`) live in preview/emu/ and are mounted at the root.
const LUA_DIRS = [
  { dir: DASH_DIR, mount: 'dash' },
  { dir: path.join(ROOT, 'preview', 'emu'), mount: '' },
];

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.lua': 'text/plain; charset=utf-8',
  '.json': 'application/json',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.dds': 'application/octet-stream',
};

function walk(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name);
    const st = fs.statSync(full);
    if (st.isDirectory()) walk(full, out);
    else out.push(full);
  }
  return out;
}

const toPosix = (p) => p.split(path.sep).join('/');

// PNG width/height from the IHDR chunk (scripts may ask ui.imageSize() before the browser loaded it).
function pngSize(buf) {
  if (buf.length < 24 || buf.readUInt32BE(12) !== 0x49484452) return null;
  return [buf.readUInt32BE(16), buf.readUInt32BE(20)];
}

// Minimal zip reader (stored + deflate), enough for VRC's assets.zip.
function readZip(file) {
  const buf = fs.readFileSync(file);
  let eocd = buf.length - 22;
  while (eocd >= 0 && buf.readUInt32LE(eocd) !== 0x06054b50) eocd--;
  if (eocd < 0) throw new Error('not a zip: ' + file);
  const count = buf.readUInt16LE(eocd + 10);
  let p = buf.readUInt32LE(eocd + 16);
  const entries = {};
  for (let i = 0; i < count; i++) {
    const method = buf.readUInt16LE(p + 10);
    const csize = buf.readUInt32LE(p + 20);
    const nameLen = buf.readUInt16LE(p + 28), extraLen = buf.readUInt16LE(p + 30), commentLen = buf.readUInt16LE(p + 32);
    const local = buf.readUInt32LE(p + 42);
    const name = buf.toString('utf8', p + 46, p + 46 + nameLen);
    const dataStart = local + 30 + buf.readUInt16LE(local + 26) + buf.readUInt16LE(local + 28);
    const raw = buf.subarray(dataStart, dataStart + csize);
    entries[name] = () => (method === 0 ? raw : zlib.inflateRawSync(raw));
    p += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

function buildBundle(entryName) {
  const files = {};
  const addLua = (dir, mount) => {
    for (const full of walk(dir)) {
      if (!full.endsWith('.lua')) continue;
      const rel = path.posix.join(toPosix(mount), toPosix(path.relative(dir, full)));
      if (!(rel in files)) files[rel] = fs.readFileSync(full, 'utf8');
    }
  };
  for (const { dir, mount } of LUA_DIRS) addLua(dir, mount);

  // Image sizes known up front: dash/ images and images inside VRC zips.
  const images = {};
  for (const full of walk(path.join(ROOT, 'dash'))) {
    if (/\.png$/i.test(full)) images[toPosix(path.relative(ROOT, full))] = pngSize(fs.readFileSync(full));
  }

  // Data files (LUTs) readable from Lua via ac.DataLUT*.load().
  const data = {};
  if (HAS_VRC) {
    for (const item of VRC_FILES) {
      const full = path.join(VRC_DIR, item);
      if (!fs.existsSync(full)) continue;
      const list = fs.statSync(full).isDirectory() ? walk(full) : [full];
      for (const f of list) {
        const rel = toPosix(path.relative(VRC_DIR, f));
        if (f.endsWith('.lua')) files[rel] = fs.readFileSync(f, 'utf8');
        else if (/\.(lut|2dlut)$/i.test(f)) data[rel] = fs.readFileSync(f, 'utf8');
        else if (f.endsWith('.zip')) {
          for (const [name, get] of Object.entries(readZip(f))) {
            if (/\.png$/i.test(name)) images[`zip:${rel}|${name}`] = pngSize(get());
          }
        }
      }
    }
  }

  // With VRC available, own dashboards run like in AC: VRC's lights.lua keeps the info LEDs.
  const dashboards = listDashboards();
  if (HAS_VRC) {
    for (const d of dashboards) {
      const module = d.entry.replace(/\.lua$/, '').replace(/\//g, '.');
      d.entry = `__dash_${d.id}.lua`;
      files[d.entry] = `return require('dash_entry')('${module}')\n`;
    }
  }
  const entries = [
    ...(HAS_VRC ? [{ id: 'vrc', label: 'VRC original', entry: 'vrc_entry.lua' }] : []),
    ...dashboards,
  ];
  const chosen = entries.find((e) => e.id === entryName) || entries[0];
  return {
    id: chosen.id,
    entry: chosen.entry,
    entries,
    shim: fs.readFileSync(path.join(__dirname, 'csp-shim.lua'), 'utf8'),
    files,
    data,
    images,
  };
}

// --- Fonts: read the family name (nameID 1) from the TTF/OTF name table --------
function ttfFamily(buf) {
  try {
    const numTables = buf.readUInt16BE(4);
    for (let i = 0; i < numTables; i++) {
      const rec = 12 + i * 16;
      if (buf.toString('ascii', rec, rec + 4) !== 'name') continue;
      const off = buf.readUInt32BE(rec + 8);
      const count = buf.readUInt16BE(off + 2);
      const strOff = off + buf.readUInt16BE(off + 4);
      let fallback = null;
      for (let j = 0; j < count; j++) {
        const r = off + 6 + j * 12;
        const platform = buf.readUInt16BE(r);
        const nameID = buf.readUInt16BE(r + 6);
        const len = buf.readUInt16BE(r + 8);
        const at = strOff + buf.readUInt16BE(r + 10);
        if (nameID !== 1) continue;
        if (platform === 3 || platform === 0) {
          let s = '';
          for (let k = 0; k < len; k += 2) s += String.fromCharCode(buf.readUInt16BE(at + k));
          return s;
        }
        if (platform === 1) fallback = buf.toString('latin1', at, at + len);
      }
      return fallback;
    }
  } catch (e) { /* ignore broken fonts */ }
  return null;
}

function listFonts() {
  return [...walk(path.join(ROOT, 'dash', 'fonts')), ...walk(VRC_FONTS)]
    .filter((f) => /\.(ttf|otf)$/i.test(f))
    .map((f) => ({
      url: '/' + encodeURI(path.relative(ROOT, f).split(path.sep).join('/')),
      file: path.basename(f),
      family: ttfFamily(fs.readFileSync(f)) || path.basename(f).replace(/\.\w+$/, ''),
    }));
}

// --- Field schema from sdk/lib.lua ----------------------------------------------
function parseFields() {
  const src = fs.readFileSync(path.join(ROOT, 'sdk', 'lib.lua'), 'utf8').split(/\r?\n/);
  const wanted = { 'ac.StateCar': 'car', 'ac.StateWheel': 'wheel', 'ac.StateSim': 'sim' };
  const out = { car: [], wheel: [], sim: [] };
  let current = null;
  for (const line of src) {
    const cls = line.match(/^---@class ([\w.]+)/);
    if (cls) { current = wanted[cls[1]] || null; continue; }
    if (!current) continue;
    const f = line.match(/^---@field (\w+) ([^\s@]+)\s*(?:@(.*))?$/);
    if (f) out[current].push({ name: f[1], type: f[2], doc: (f[3] || '').trim() });
    else if (!line.startsWith('---')) current = null;
  }
  return out;
}

// --- Live reload over SSE ---------------------------------------------------------
const clients = new Set();
let reloadTimer = null;
function broadcastReload(file) {
  clearTimeout(reloadTimer);
  reloadTimer = setTimeout(() => {
    for (const res of clients) res.write(`event: reload\ndata: ${JSON.stringify({ file })}\n\n`);
    console.log(`[reload] ${file}`);
  }, 80);
}
// Created up front so dashboards added later are picked up too.
fs.mkdirSync(STYLES_DIR, { recursive: true });
for (const dir of [DASH_DIR, path.join(__dirname, 'emu'), __dirname]) {
  fs.watch(dir, { recursive: true }, (_evt, name) => {
    if (!name || name.includes('vendor')) return;
    const rel = path.relative(ROOT, path.join(dir, name)).split(path.sep).join('/');
    // Lua/asset changes restart only the Lua state; preview JS/HTML changes need a page refresh.
    const kind = /\.(lua|ttf|otf|png|jpg|jpeg)$/i.test(name) ? 'lua' : 'page';
    if (kind === 'page') {
      for (const res of clients) res.write(`event: page\ndata: ${JSON.stringify({ file: rel })}\n\n`);
    } else broadcastReload(rel);
  });
}

function send(res, code, body, type = 'text/plain; charset=utf-8') {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(body);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const p = decodeURIComponent(url.pathname);

  if (p === '/events') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', Connection: 'keep-alive' });
    res.write('retry: 1000\n\n');
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }
  try {
    if (p === '/api/bundle') return send(res, 200, JSON.stringify(buildBundle(url.searchParams.get('entry'))), MIME['.json']);
    if (p === '/api/zip') {
      // /api/zip?zip=display/styles/style_0/assets.zip&name=x.png (zip relative to VRC data_override)
      const zipPath = path.resolve(VRC_DIR, url.searchParams.get('zip') || '');
      if (!HAS_VRC || !zipPath.startsWith(VRC_DIR) || !fs.existsSync(zipPath)) return send(res, 404, 'zip not found');
      const entry = readZip(zipPath)[url.searchParams.get('name')];
      if (!entry) return send(res, 404, 'not in zip');
      return send(res, 200, entry(), MIME[path.extname(url.searchParams.get('name')).toLowerCase()] || 'application/octet-stream');
    }
    if (p === '/api/fonts') return send(res, 200, JSON.stringify(listFonts()), MIME['.json']);
    if (p === '/api/fields') return send(res, 200, JSON.stringify(parseFields()), MIME['.json']);
  } catch (e) {
    return send(res, 500, String(e.stack || e));
  }

  let file = p === '/' ? path.join(__dirname, 'index.html') : path.join(ROOT, p);
  if (!file.startsWith(ROOT)) return send(res, 403, 'forbidden');
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) return send(res, 404, 'not found: ' + p);
  res.writeHead(200, { 'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream', 'Cache-Control': 'no-store' });
  fs.createReadStream(file).pipe(res);
});

server.listen(PORT, () => {
  console.log(`Dashboard preview: http://localhost:${PORT}`);
  const own = listDashboards();
  console.log(`Dashboards:        ${own.length ? own.map((d) => d.id).join(', ') : '(no dash/styles/<name>/dashboard.lua yet)'}`);
  console.log(`VRC original:      ${HAS_VRC ? path.relative(ROOT, VRC_DIR) : 'not found (use --vrc <car folder>)'}`);
});
