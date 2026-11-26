#!/usr/bin/env node
// Builds dist/ : everything that has to go into the car for AC.
//   node tools/build.js [--dash <name>] [--car "<path to vrc_formula_alpha_2025_csp>"]
//
// All dashboards in dash/styles/ are copied; dash/active.lua picks the one AC draws
// (<name>, default: the first one). Switching in AC = edit that one line, restart the session.
// Output (mirrors the car folder):
//   dist/vrc_formula_alpha_2025_csp/extension/data_override/dash/...       our dashboard
//   dist/vrc_formula_alpha_2025_csp/extension/data_override/display.lua    VRC file + hook (screen)
//   dist/vrc_formula_alpha_2025_csp/extension/data_override/lights.lua     VRC file + hook (shift lights)
//   dist/INSTALL.txt
//
// The two VRC files are patched copies of the originals in your own download, so
// dist/ contains VRC code: it's in .gitignore and must not be shared.

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const args = process.argv.slice(2);
const carArg = args.indexOf('--car');
const CAR = carArg >= 0 ? path.resolve(args[carArg + 1])
  : path.join(ROOT, 'VRC_-_AC_-_FA_2025_-_V1.1', 'AC Files', 'content', 'cars', 'vrc_formula_alpha_2025_csp');
const CAR_ID = path.basename(CAR);
const SRC = path.join(CAR, 'extension', 'data_override');
const OUT_CAR = path.join(ROOT, 'dist', CAR_ID);
const OUT = path.join(OUT_CAR, 'extension', 'data_override');
const MARK = '-- [custom dashboard]';
const dashArg = args.indexOf('--dash');
const STYLES = path.join(ROOT, 'dash', 'styles');
const DASHBOARDS = fs.existsSync(STYLES)
  ? fs.readdirSync(STYLES).filter((n) => fs.existsSync(path.join(STYLES, n, 'dashboard.lua'))) : [];
const DASH = dashArg >= 0 ? args[dashArg + 1] : DASHBOARDS[0];
const DASH_MODULE = 'dash.active';

function fail(msg) { console.error('build: ' + msg); process.exit(1); }

function copyDir(from, to) {
  fs.mkdirSync(to, { recursive: true });
  for (const name of fs.readdirSync(from)) {
    const a = path.join(from, name), b = path.join(to, name);
    if (fs.statSync(a).isDirectory()) copyDir(a, b);
    else fs.copyFileSync(a, b);
  }
}

// Replaces exactly one match of `pattern`; fails loudly if VRC changed the file.
function patchOnce(text, pattern, replacement, what) {
  const matches = text.match(new RegExp(pattern.source, 'g'));
  if (!matches || matches.length !== 1) fail(`anchor for "${what}" not found (exactly once); did the VRC version change?`);
  return text.replace(pattern, replacement);
}

function patchDisplay(src) {
  if (src.includes(MARK)) fail('display.lua is already patched; use the original (display.lua.orig)');
  const nl = src.includes('\r\n') ? '\r\n' : '\n';
  const L = (lines) => lines.join(nl);
  src = patchOnce(src, /local display = \{\}\r?\n/, L([
    'local display = {}',
    '',
    `${MARK} load our dashboard; fall back to VRC's own style when it fails`,
    `local hasCustomDashboard, customDashboard = pcall(require, "${DASH_MODULE}")`,
    'if hasCustomDashboard and type(customDashboard) ~= "table" then hasCustomDashboard, customDashboard = false, "dash/active.lua returns no dashboard" end',
    'if not hasCustomDashboard then',
    '        ac.log("custom dashboard not loaded: " .. tostring(customDashboard))',
    '        customDashboard = nil',
    'end',
    `${MARK} end`,
    '',
  ]), 'local display = {}');
  src = patchOnce(src,
    /( *)if style\[displayStyleIndex\]\["update"\] ~= nil then style\[displayStyleIndex\]:update\(dt\) end/,
    (m, indent) => L([
      `${indent}${MARK} draw our dashboard instead of VRC's style`,
      `${indent}if customDashboard then`,
      `${indent}        local ok, err = pcall(customDashboard.update, dt)`,
      `${indent}        if not ok then`,
      `${indent}                ac.log("custom dashboard error: " .. tostring(err))`,
      `${indent}                customDashboard = nil`,
      `${indent}        end`,
      `${indent}        return`,
      `${indent}end`,
      `${indent}${MARK} end`,
      m,
    ]), 'style:update(dt)');
  return src;
}

function patchLights(src) {
  if (src.includes(MARK)) fail('lights.lua is already patched; use the original (lights.lua.orig)');
  const nl = src.includes('\r\n') ? '\r\n' : '\n';
  const L = (lines) => lines.join(nl);
  src = patchOnce(src, /local RPM_LED_CONTROLLER = class\("RPM_LED_CONTROLLER"\)\r?\n/, L([
    `${MARK} shift lights computed by dash/core/leds.lua`,
    `local hasCustomDashboard, customDashboard = pcall(require, "${DASH_MODULE}")`,
    'local customLeds = hasCustomDashboard and type(customDashboard) == "table" and customDashboard.ledModule or nil',
    'if customLeds and not customLeds.enabled then customLeds = nil end',
    'local customLedColor = vec3()',
    'local customLedIntensity = 90',
    `${MARK} end`,
    '',
    'local RPM_LED_CONTROLLER = class("RPM_LED_CONTROLLER")',
    '',
  ]), 'RPM_LED_CONTROLLER class');
  src = patchOnce(src,
    /(function RPM_LED_CONTROLLER:run\(dt, forceOff, reloadLeds\)\r?\n(?:.*\r?\n)*? *if forceOff then\r?\n *self:offline\(\)\r?\n *return\r?\n *end\r?\n)/,
    (m) => m + L([
      '',
      `        ${MARK} copy our LED colors onto the wheel LEDs`,
      '        if customLeds then',
      '                local brightness = customLedIntensity * colorBaseMult * (can.bus.ledBrightness or 100) * 0.01',
      '                for i = 1, 15 do',
      '                        local c = customLeds.colors[i]',
      '                        if c and c.mult > 0 then',
      '                                self.rpmLeds[i]:setState(true, customLedColor:set(c.r, c.g, c.b):scale(brightness))',
      '                        else',
      '                                self.rpmLeds[i]:setState(false)',
      '                        end',
      '                end',
      '                if customLeds.shiftRpm then audio.targetShiftRpm = customLeds.shiftRpm end',
      '                return',
      '        end',
      `        ${MARK} end`,
      '',
    ]), 'RPM_LED_CONTROLLER:run');
  return src;
}

if (!DASHBOARDS.length) fail('no dashboard yet (dash/styles/<name>/dashboard.lua); nothing to build');
if (!DASHBOARDS.includes(DASH)) fail(`dashboard "${DASH}" not found (${DASHBOARDS.join(', ')})`);
if (!fs.existsSync(path.join(SRC, 'display.lua'))) fail(`VRC files not found in ${SRC}`);

fs.rmSync(path.join(ROOT, 'dist'), { recursive: true, force: true });
copyDir(path.join(ROOT, 'dash'), path.join(OUT, 'dash'));
fs.writeFileSync(path.join(OUT, 'dash', 'active.lua'), [
  '-- Which dashboard AC draws. Change the name to one of: ' + DASHBOARDS.join(', '),
  '-- and restart the session. Back to VRC\'s own dashboard: put "--" in front of the return line.',
  `return require('dash.styles.${DASH}.dashboard')`,
  '',
].join('\r\n'));
fs.writeFileSync(path.join(OUT, 'display.lua'), patchDisplay(fs.readFileSync(path.join(SRC, 'display.lua'), 'utf8')));
fs.writeFileSync(path.join(OUT, 'lights.lua'), patchLights(fs.readFileSync(path.join(SRC, 'lights.lua'), 'utf8')));

fs.writeFileSync(path.join(ROOT, 'dist', 'INSTALL.txt'), [
  'Installing a custom dashboard (Windows PC with AC + CSP)',
  '',
  `1. Go to <AC>\\content\\cars\\${CAR_ID}\\extension\\data_override\\`,
  '2. Make a backup first: copy display.lua to display.lua.orig and lights.lua to lights.lua.orig',
  `3. Copy the contents of dist\\${CAR_ID}\\ over the car folder (folder "dash" + display.lua + lights.lua).`,
  '4. Start AC. Errors show up in the CSP Lua Debug app and in ac.log.',
  '   If the custom dashboard fails to load or errors, the screen falls back to the VRC dashboard.',
  '',
  'Switching dashboards: open data_override\\dash\\active.lua in Notepad and replace the name',
  `(${DASHBOARDS.join(', ')}). Then restart the session / AC.`,
  'VRC dashboard back for a while: put "--" in front of the return line in active.lua.',
  '',
  'Uninstall: restore display.lua.orig and lights.lua.orig and delete the "dash" folder.',
  'Custom screen but VRC shift lights? Set shiftLights.enabled = false in dash\\styles\\<name>\\settings.lua.',
  '',
].join('\r\n'));

console.log(`dist/ built for ${CAR_ID}, active dashboard "${DASH}" (dash/active.lua; also: ${DASHBOARDS.join(', ')}):`);
console.log(`  ${path.relative(ROOT, OUT)}/dash/ (${fs.readdirSync(path.join(OUT, 'dash')).length} items)`);
console.log(`  ${path.relative(ROOT, OUT)}/display.lua (patched)`);
console.log(`  ${path.relative(ROOT, OUT)}/lights.lua (patched)`);
console.log('  dist/INSTALL.txt');
