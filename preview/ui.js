// ui.js: preview app. Main loop, hot reload, console, grid and the control panel.

(async function () {
  'use strict';
  const $ = (s) => document.querySelector(s);
  const TEX_W = 1024, TEX_H = 1024;
  const VISIBLE = { x: 0, y: 448, w: 1024, h: 576 }; // matches dash/settings.lua display area

  // ---------------------------------------------------------------------------
  // Console and debug
  // ---------------------------------------------------------------------------
  const consoleEl = $('#console');
  const debugValues = new Map();
  let consoleCount = 0;
  function log(kind, text) {
    const div = document.createElement('div');
    div.className = kind;
    div.textContent = text;
    consoleEl.appendChild(div);
    if (++consoleCount > 400) { consoleEl.children[1].remove(); consoleCount--; }
    consoleEl.scrollTop = consoleEl.scrollHeight;
  }
  $('#btnClear').onclick = () => { while (consoleEl.children.length > 1) consoleEl.lastChild.remove(); consoleCount = 0; };
  Render.fonts.onWarn = (msg) => log('warn', msg);

  function renderDebug() {
    const rows = [...debugValues].map(([k, v]) => `<tr><td>${esc(k)}</td><td class="mono">${esc(v)}</td></tr>`);
    $('#debugTable').innerHTML = rows.join('');
  }
  const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));

  // ---------------------------------------------------------------------------
  // Load fields, fonts and the Lua bundle
  // ---------------------------------------------------------------------------
  const schema = await (await fetch('/api/fields')).json();

  async function loadFonts() {
    const list = await (await fetch('/api/fonts')).json();
    for (const f of list) {
      try {
        const face = new FontFace(f.family, `url(${f.url}?t=${Date.now()})`);
        await face.load();
        document.fonts.add(face);
        Render.fonts.families.add(f.family);
      } catch (e) {
        log('warn', `font ${f.file} could not be loaded: ${e.message}`);
      }
    }
    return list;
  }
  const fontList = await loadFonts();
  log('info', `fonts: ${fontList.map((f) => `${f.family} (${f.file})`).join(', ') || 'none'}`);

  const model = new Sim.Model(schema);
  window.preview = { model, get runtime() { return runtime; }, get frame() { return lastGood; } }; // for debugging/tools
  let runtime = null;
  let lastGood = null;
  let currentError = null;

  const hooks = {
    log: (kind, text) => log(kind, text),
    debug: (k, v) => debugValues.set(k, v),
    clock: () => model.clock,
  };

  // Which dashboard runs: 'vrc' or the name of a dash/styles/<name>/ folder.
  let source = 'vrc';
  try { source = localStorage.getItem('previewSource') || 'vrc'; } catch (e) {}

  function fillSourceSelect(entries, current) {
    const sel = $('#selSource');
    const ids = entries.map((e) => e.id).join('|');
    if (sel.dataset.ids !== ids) {
      sel.innerHTML = entries.map((e) => `<option value="${esc(e.id)}">${esc(e.label)}</option>`).join('');
      sel.dataset.ids = ids;
    }
    sel.value = current;
  }

  async function startRuntime(reason) {
    const bundle = await (await fetch('/api/bundle?entry=' + encodeURIComponent(source))).json();
    Render.setKnownSizes(bundle.images);
    // Keep the wanted source even when it's (temporarily) missing, e.g. while renaming its folder.
    // No warning for the default 'vrc' when the VRC car isn't installed.
    if (source !== 'vrc' && !bundle.entries.some((e) => e.id === source)) log('warn', `dashboard "${source}" not found, showing ${bundle.id}`);
    fillSourceSelect(bundle.entries, bundle.id);
    const rt = new Bridge.LuaRuntime({ bundle, schema, canSchema: Sim.CAN_SCHEMA, width: TEX_W, height: TEX_H, hooks });
    try {
      rt.start();
    } catch (e) {
      showError(e, 'load');
      return false; // keep the previous runtime running
    }
    runtime = rt;
    debugValues.clear();
    clearError();
    log('info', `${reason}: ${bundle.entry} loaded (${Object.keys(bundle.files).length} Lua files)`);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Error overlay
  // ---------------------------------------------------------------------------
  const errorBox = $('#errorBox');
  function showError(e, phase) {
    const key = e.raw || String(e);
    if (currentError === key) return;
    currentError = key;
    const where = e.file ? `<b>${esc(e.file)}:${e.line}</b> ` : '';
    errorBox.innerHTML = `Error during ${phase}: ${where}${esc(e.message || e)}\n\n${esc(e.traceback || '')}` +
      (lastGood ? '\n\n(last working frame stays visible)' : '');
    errorBox.style.display = 'block';
    log('error', `${e.file ? `${e.file}:${e.line}: ` : ''}${e.message || e}`);
  }
  function clearError() {
    currentError = null;
    errorBox.style.display = 'none';
  }

  // ---------------------------------------------------------------------------
  // Stage: display canvas, LEDs, grid
  // ---------------------------------------------------------------------------
  // Only the visible region is drawn, straight into the display canvas, at the screen's
  // own pixel density (`ss`) so it stays sharp on Retina. "Scherp" off (ss = 1) shows
  // the real 1024 resolution that AC renders.
  let ss = 1, sharp = true;
  const display = $('#display');
  const displayCtx = display.getContext('2d');
  const grid = $('#grid');
  const gridCtx = grid.getContext('2d');
  let crop = true, showGrid = false, framed = true;
  let region = VISIBLE;
  let cssPerTex = 1; // CSS pixels per texture pixel on screen

  const ledsEl = $('#leds');
  const ledEls = [];
  // 0..14 shift lights above the screen, 15..17 info LEDs left, 18..20 info LEDs right.
  const ledParents = [...Array(15).fill(ledsEl), ...Array(3).fill($('#infoL')), ...Array(3).fill($('#infoR'))];
  for (const parent of ledParents) {
    const d = document.createElement('div');
    d.className = 'led';
    parent.appendChild(d);
    ledEls.push(d);
  }

  function layout() {
    region = crop ? VISIBLE : { x: 0, y: 0, w: TEX_W, h: TEX_H };
    grid.width = region.w; grid.height = region.h;
    const stage = $('#stage');
    const padW = framed ? 180 : 120, padH = framed ? 110 : 80;
    const scale = Math.min((stage.clientWidth - padW) / region.w, (stage.clientHeight - padH) / region.h, 1.5);
    const cssW = Math.max(200, Math.floor(region.w * scale)), cssH = Math.floor(cssW * region.h / region.w);
    ss = sharp ? Math.min(2.5, Math.max(1, (cssW / region.w) * (window.devicePixelRatio || 1))) : 1;
    display.width = Math.round(region.w * ss); display.height = Math.round(region.h * ss);
    display.style.imageRendering = sharp ? 'auto' : 'pixelated';
    for (const c of [display, grid]) { c.style.width = cssW + 'px'; c.style.height = cssH + 'px'; }
    const ledSize = Math.max(10, Math.min(26, cssW / 30));
    for (const l of ledEls) { l.style.width = l.style.height = ledSize + 'px'; }
    ledsEl.style.gap = Math.round(ledSize * 0.45) + 'px';
    cssPerTex = cssW / region.w;
    drawGrid();
  }
  window.addEventListener('resize', layout);

  function drawGrid() {
    gridCtx.clearRect(0, 0, grid.width, grid.height);
    if (!showGrid) return;
    for (let x = 0; x <= region.w; x += 32) {
      gridCtx.fillStyle = x % 128 === 0 ? '#3d8bff88' : '#ffffff1c';
      gridCtx.fillRect(x, 0, 1, region.h);
    }
    for (let y = 0; y <= region.h; y += 32) {
      gridCtx.fillStyle = (y + region.y) % 128 === 0 ? '#3d8bff88' : '#ffffff1c';
      gridCtx.fillRect(0, y, region.w, 1);
    }
    gridCtx.fillStyle = '#9ef';
    gridCtx.font = '14px ui-monospace, Menlo, monospace';
    for (let x = 0; x < region.w; x += 128) gridCtx.fillText(String(x), x + 3, 14);
    for (let y = 128 - (region.y % 128); y < region.h; y += 128) gridCtx.fillText(String(y + region.y), 3, y - 3);
  }

  const mousePos = $('#mousePos');
  display.parentElement.addEventListener('mousemove', (e) => {
    if (!showGrid) return;
    const r = display.getBoundingClientRect();
    const x = Math.round(((e.clientX - r.left) / r.width) * region.w + region.x);
    const y = Math.round(((e.clientY - r.top) / r.height) * region.h + region.y);
    mousePos.textContent = `x ${x}  y ${y}   (in dash-area: ${x - VISIBLE.x}, ${y - VISIBLE.y})`;
    mousePos.style.display = 'block';
  });
  display.parentElement.addEventListener('mouseleave', () => { mousePos.style.display = 'none'; });

  function paint(frame) {
    const sx = display.width / region.w, sy = display.height / region.h;
    displayCtx.setTransform(sx, 0, 0, sy, -region.x * sx, -region.y * sy);
    displayCtx.fillStyle = '#000';
    displayCtx.fillRect(region.x, region.y, region.w, region.h);
    if (frame) Render.render(displayCtx, frame);
    for (let i = 0; i < ledEls.length; i++) {
      const c = frame && frame.leds[i];
      const el = ledEls[i];
      // Only touch the DOM when the LED changes (glow shadows are expensive to repaint).
      const css = c && c[3] > 0
        ? `rgb(${Math.round(Math.min(255, c[0] * 255))},${Math.round(Math.min(255, c[1] * 255))},${Math.round(Math.min(255, c[2] * 255))})` : '';
      const op = c && c[3] > 0 ? (0.35 + 0.65 * Math.min(1, c[3])).toFixed(2) : '';
      if (el._css === css && el._op === op) continue;
      el._css = css; el._op = op;
      el.style.background = css;
      el.style.boxShadow = css ? `0 0 12px 3px ${css}, inset 0 0 4px #fff8` : '';
      el.style.opacity = op;
    }
  }

  // ---------------------------------------------------------------------------
  // Main loop
  // ---------------------------------------------------------------------------
  let paused = false, slow = false, stepOnce = false;
  let last = performance.now();
  let frameMs = 0, frameMsMax = 0, statTimer = 0;

  function tick(now) {
    let dt = Math.min(0.1, (now - last) / 1000);
    last = now;
    if (slow) dt *= 0.25;
    if (stepOnce) dt = 1 / 60;
    // Pause freezes the simulated data; the dashboard keeps running so changes from the
    // panel (and blinking/popups) stay live. Step advances the data by one frame.
    if (runtime) {
      if (!paused || stepOnce) model.step(dt);
      else model.hold();
      const t0 = performance.now();
      try {
        lastGood = runtime.step(dt, model.state);
        if (currentError) clearError();
      } catch (e) {
        showError(e, 'update');
      }
      const ms = performance.now() - t0;
      frameMs = frameMs * 0.95 + ms * 0.05;
      frameMsMax = Math.max(frameMsMax * 0.995, ms);
      stepOnce = false;
    }
    paint(lastGood);
    statTimer += 1;
    if (statTimer % 15 === 0) {
      $('#stat').textContent = `update ${frameMs.toFixed(2)} ms (max ${frameMsMax.toFixed(1)})  ·  ` +
        `lap ${model.state.car.lapCount + 1}  ·  ${(model.state.car.splinePosition * 100).toFixed(0)}%` +
        (paused ? '  ·  PAUSED' : slow ? '  ·  0.25×' : '');
      renderDebug();
      refreshPanel();
    }
    if (statTimer % 4 === 0) refreshControls();
    requestAnimationFrame(tick);
  }

  // ---------------------------------------------------------------------------
  // Toolbar
  // ---------------------------------------------------------------------------
  const btn = (id, fn) => { $(id).onclick = fn; };
  btn('#btnPause', () => { paused = !paused; $('#btnPause').title = 'Freeze the simulation; the dashboard stays live (space)'; $('#btnPause').classList.toggle('on', paused); $('#btnPause').textContent = paused ? '▶ Resume' : '⏸ Pause'; });
  btn('#btnSlow', () => { slow = !slow; $('#btnSlow').classList.toggle('on', slow); });
  btn('#btnStep', () => { if (!paused) $('#btnPause').click(); stepOnce = true; });
  btn('#btnGrid', () => { showGrid = !showGrid; $('#btnGrid').classList.toggle('on', showGrid); drawGrid(); });
  btn('#btnCrop', () => { crop = !crop; $('#btnCrop').classList.toggle('on', crop); layout(); });
  btn('#btnSharp', () => { sharp = !sharp; $('#btnSharp').classList.toggle('on', sharp); layout(); });
  $('#selSource').onchange = async (e) => {
    source = e.target.value;
    try { localStorage.setItem('previewSource', source); } catch (err) {}
    e.target.blur(); // keep keyboard shortcuts working
    await startRuntime('dashboard switched');
  };
  btn('#btnFrame', () => { framed = !framed; $('#btnFrame').classList.toggle('on', framed); $('#wheel').classList.toggle('framed', framed); layout(); });
  btn('#btnReload', () => startRuntime('restart'));
  document.addEventListener('keydown', (e) => {
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT') return;
    if (e.key === ' ') { e.preventDefault(); $('#btnPause').click(); }
    else if (e.key === '.') $('#btnStep').click();
    else if (e.key === 'g') $('#btnGrid').click();
    else if (e.key === 'r') $('#btnReload').click();
    else if (e.key === 'ArrowLeft') stepPage(-1);
    else if (e.key === 'ArrowRight') stepPage(1);
  });

  // ---------------------------------------------------------------------------
  // Hot reload (Server-Sent Events from serve.js)
  // ---------------------------------------------------------------------------
  const events = new EventSource('/events');
  events.addEventListener('reload', async (e) => {
    const { file } = JSON.parse(e.data);
    if (/\.(ttf|otf)$/i.test(file)) await loadFonts();
    if (/\.(png|jpe?g)$/i.test(file)) Render.reloadImages();
    startRuntime(`changed: ${file}`);
  });
  events.addEventListener('page', () => location.reload());

  // ---------------------------------------------------------------------------
  // Scenarios
  // ---------------------------------------------------------------------------
  const scenEl = $('#scenarios');
  for (const sc of Sim.SCENARIOS) {
    const b = document.createElement('button');
    b.textContent = sc.name;
    b.title = sc.desc;
    b.onclick = () => {
      if (model.scenario === sc) Sim.stopScenario(model);
      else Sim.startScenario(model, sc.id);
      updateScenarioButtons();
    };
    b.dataset.id = sc.id;
    scenEl.appendChild(b);
  }
  function updateScenarioButtons() {
    for (const b of scenEl.children) b.classList.toggle('on', model.scenario && model.scenario.id === b.dataset.id);
  }
  btn('#btnStopScenario', () => { Sim.stopScenario(model); updateScenarioButtons(); });
  btn('#btnAllSim', () => { Sim.stopScenario(model); model.clearAllManual(); updateScenarioButtons(); });
  // A reset is a fresh start: the dashboard restarts too (page switch, pop-ups), like a new session in AC.
  btn('#btnResetSim', () => { Sim.stopScenario(model); model.clearAllManual(); model.reset(); updateScenarioButtons(); startRuntime('reset'); });

  // ---------------------------------------------------------------------------
  // Wheel controls: the rotaries and buttons as you'd use them in the car
  // (see ext_car_controls.ini of the VRC car). Values go into the same fields
  // the dashboard reads, as manual overrides.
  // ---------------------------------------------------------------------------
  const PAGES = ['RACE', 'QUALI', 'START'];
  const PU_MODES = ['', 'RECHARGE', 'QUALI', 'FORM', 'START', 'SLOW', 'RACE', 'RACE+'];
  const plus1 = (v) => String(Math.round(v) + 1);
  const STEPPERS = [
    // [label, path, min, max, step, format]
    ['BBAL', 'can.bus.frontBias', 0.40, 0.70, 0.005, (v) => (v * 100).toFixed(1)],
    ['BMIG', 'can.bus.brakeShapeMap', 1, 5, 1, (v) => String(v)],
    ['STRAT', 'car.mgukDelivery', 0, 7, 1, plus1],
    ['MODE', 'can.bus.puMode', 1, 7, 1, (v) => `${v} ${PU_MODES[v] || ''}`],
    ['EB', 'can.bus.engineBrakeSetting', 0, 11, 1, plus1],
    ['ENTRY', 'can.bus.differentialEntrySetting', 0, 11, 1, plus1],
    ['MID', 'can.bus.differentialMidSetting', 0, 11, 1, plus1],
    ['EXIT', 'can.bus.differentialExitHispdSetting', 0, 11, 1, plus1],
  ];
  const SWITCHES = [
    // [label, paths, kind, title]. 'toggle' stays on, 'hold' only while pressed.
    ['Ignition', ['can.bus.isIgnitionStage1', 'can.bus.isIgnitionStage2', 'can.bus.isElectronicsBooted'], 'toggle', 'Ignition on/off'],
    ['Engine', ['can.bus.isEngineRunning'], 'engine', 'Start the engine (with starter) or stall it'],
    ['Antistall', ['can.bus.isAntistallActive'], 'toggle', 'Antistall active'],
    ['DRS', ['car.drsAvailable', 'car.drsActive'], 'toggle', 'DRS open (again = back to simulation)'],
    ['Pitlimiter', ['car.manualPitsSpeedLimiterEnabled'], 'toggle', 'Pit limiter on/off'],
    ['Clutch', ['car.clutch'], 'clutch', 'Hold the clutch in (launch procedure when stationary)'],
    ['Overtake', ['car.kersButtonPressed'], 'hold', 'ERS Overtake (hold)'],
    ['ERS Anti', ['can.bus.isHybridAntiActive'], 'hold', 'ERS Anti: no deploy (hold)'],
    ['Preset 1', ['can.bus.driverPreset1Active'], 'toggle', 'Driver preset 1'],
    ['Preset 2', ['can.bus.driverPreset2Active'], 'toggle', 'Driver preset 2'],
  ];

  // Pit menu: the driver settings from VRC's "Advanced Setup" app (LEDs/Display) that
  // the dashboard and lights.lua actually read. Remembered in the browser, like the
  // car remembers them in ac.storage.
  const PIT_SETTINGS = [
    // [label, path, default, {options} | [min, max, step, format]]
    ['Shift pattern', 'can.bus.ledShiftPattern', 0, { 0: 'Sequential', 1: 'Seq-Block', 2: 'Block-Block' }],
    ['LED brightness', 'can.bus.ledBrightness', 100, [10, 100, 5, (v) => `${v}%`]],
    ['Popup time', 'can.bus.displayPopupTime', 10, [2, 30, 1, (v) => `${(v / 10).toFixed(1)} s`]],
    ['Lap popup', 'can.bus.displayLapPopupTime', 30, [2, 60, 1, (v) => `${(v / 10).toFixed(1)} s`]],
    ['Delta vs.', 'can.bus.lapDelta', 1, { 0: 'Previous', 1: 'Best', 2: 'Target' }],
  ];
  const pitValues = {};
  try { Object.assign(pitValues, JSON.parse(localStorage.getItem('previewPitMenu') || '{}')); } catch (e) {}
  const pitEls = [];
  function setPit(path, v) {
    pitValues[path] = v;
    try { localStorage.setItem('previewPitMenu', JSON.stringify(pitValues)); } catch (e) {}
  }
  function buildPitMenu() {
    for (const [label, path, def, opt] of PIT_SETTINGS) {
      if (!(path in pitValues)) pitValues[path] = def;
      const row = document.createElement('div');
      row.className = 'pitRow';
      row.innerHTML = `<label>${esc(label)}</label>`;
      if (Array.isArray(opt)) {
        const [min, max, step, fmt] = opt;
        const input = document.createElement('input');
        input.type = 'range'; input.min = min; input.max = max; input.step = step;
        const val = document.createElement('span');
        val.className = 'val mono';
        input.oninput = () => setPit(path, Number(input.value));
        row.append(input, val);
        pitEls.push(() => { input.value = pitValues[path]; val.textContent = fmt(pitValues[path]); });
      } else {
        const seg = document.createElement('div');
        seg.className = 'seg';
        for (const [v, name] of Object.entries(opt)) {
          const b = document.createElement('button');
          b.textContent = name;
          b.onclick = () => setPit(path, Number(v));
          seg.appendChild(b);
          pitEls.push(() => b.classList.toggle('on', pitValues[path] === Number(v)));
        }
        row.appendChild(seg);
      }
      $('#pitRows').appendChild(row);
    }
  }

  // Flags: sim.raceFlagType (ac.FlagType). VRC's own dashboard only shows yellow (info LEDs).
  const FLAGS = [['None', 0, ''], ['Yellow', 2, '#ffd400'], ['Blue', 12, '#3d8bff'], ['White', 14, '#ffffff'],
    ['Chequered', 13, '#bbbbbb'], ['Black', 5, '#777777']];
  function buildFlags() {
    for (const [name, v, color] of FLAGS) {
      const b = document.createElement('button');
      b.textContent = name;
      b.onclick = () => {
        if (v === 0) { model.clearManual('sim.raceFlagType'); model.set('sim.raceFlagType', 0); }
        else model.setManual('sim.raceFlagType', v);
      };
      $('#flagSeg').appendChild(b);
      controlEls.push({ kind: 'flag', v, color, el: b });
    }
  }

  const controlEls = [];
  function stepField(spec, dir) {
    const [, path, min, max, step] = spec;
    const v = Number(model.get(path)) || 0;
    const next = Math.round(Math.min(max, Math.max(min, v + dir * step)) / step) * step;
    model.setManual(path, step < 1 ? Number(next.toFixed(4)) : next);
  }
  function stepPage(dir) {
    const v = Number(model.get('can.bus.displayPage')) || 1;
    model.setManual('can.bus.displayPage', ((v - 1 + dir + PAGES.length) % PAGES.length) + 1);
  }
  function buildControls() {
    $('#pagePrev').onclick = () => stepPage(-1);
    $('#pageNext').onclick = () => stepPage(1);
    $('#pageName').parentElement.addEventListener('wheel', (e) => { e.preventDefault(); stepPage(e.deltaY > 0 ? 1 : -1); }, { passive: false });
    for (const spec of STEPPERS) {
      const el = document.createElement('div');
      el.className = 'stepper';
      el.innerHTML = `<button>−</button><div class="mid"><div class="lbl">${spec[0]}</div><div class="v">–</div></div><button>+</button>`;
      const [minus, , plus] = el.children;
      minus.onclick = () => stepField(spec, -1);
      plus.onclick = () => stepField(spec, 1);
      el.addEventListener('wheel', (e) => { e.preventDefault(); stepField(spec, e.deltaY > 0 ? -1 : 1); }, { passive: false });
      $('#steppers').appendChild(el);
      controlEls.push({ kind: 'stepper', spec, el, val: el.querySelector('.v') });
    }
    for (const spec of SWITCHES) {
      const [label, paths, kind, title] = spec;
      const b = document.createElement('button');
      b.textContent = label;
      b.title = title;
      if (kind === 'hold' || kind === 'clutch') {
        b.classList.add('hold');
        const on = kind === 'clutch' ? 0 : true, off = kind === 'clutch' ? 1 : false;
        const press = (e) => { e.preventDefault(); b.setPointerCapture(e.pointerId); for (const p of paths) model.setManual(p, on); };
        const release = () => { for (const p of paths) { model.clearManual(p); model.set(p, off); } };
        b.addEventListener('pointerdown', press);
        b.addEventListener('pointerup', release);
        b.addEventListener('pointercancel', release);
      } else if (kind === 'engine') {
        b.onclick = () => {
          if (model.get(paths[0])) { model.setManual(paths[0], false); return; }
          // Starter cranks for a moment, then the engine runs (VRC shows its start sequence).
          model.setManual('can.bus.isStarterCranking', true);
          setTimeout(() => { model.setManual('can.bus.isStarterCranking', false); model.setManual(paths[0], true); }, 900);
        };
      } else {
        b.onclick = () => {
          const cur = !!model.get(paths[0]);
          // Fields the simulation drives (DRS) go back to the simulation when switched off.
          if (cur && model.isManual(paths[0]) && paths[0].startsWith('car.drs')) { for (const p of paths) model.clearManual(p); return; }
          for (const p of paths) model.setManual(p, !cur);
        };
      }
      $('#switches').appendChild(b);
      controlEls.push({ kind, spec, el: b });
    }
    btn('#btnCtlReset', () => {
      for (const s of STEPPERS) model.clearManual(s[1]);
      for (const s of SWITCHES) for (const p of s[1]) model.clearManual(p);
      for (const p of ['can.bus.displayPage', 'can.bus.isStarterCranking']) model.clearManual(p);
      model.reset();
      startRuntime('reset');
    });
  }
  function refreshControls() {
    // Pit-menu values are sticky: they survive scenario/sim resets.
    for (const [, path] of PIT_SETTINGS) if (model.get(path) !== pitValues[path]) model.set(path, pitValues[path]);
    for (const f of pitEls) f();
    // Own dashboards can have their own pages: they report the current one with ac.debug('page', name).
    const ownPage = debugValues.get('page');
    $('#pageName').textContent = ownPage != null ? String(ownPage).toUpperCase()
      : PAGES[(Number(model.get('can.bus.displayPage')) || 1) - 1] || '?';
    for (const c of controlEls) {
      if (c.kind === 'flag') {
        const on = (Number(model.get('sim.raceFlagType')) || 0) === c.v;
        c.el.classList.toggle('on', on);
        c.el.style.background = on && c.color ? c.color : '';
        c.el.style.borderColor = on && c.color ? c.color : '';
        continue;
      }
      if (c.kind === 'stepper') {
        c.val.textContent = c.spec[5](Number(model.get(c.spec[1])) || 0);
        c.el.classList.toggle('manual', model.isManual(c.spec[1]));
      } else {
        const v = model.get(c.spec[1][0]);
        c.el.classList.toggle('on', c.kind === 'clutch' ? v < 0.95 : !!v);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Control panel. Field names are the real ones from sdk/lib.lua (car./sim.)
  // or VRC's can module (can.bus./can.stream.). Wheel fields use 'w.' and the
  // wheel picker. Spec: [path, min, max, step] or [path, 'bool'] or [path, {options}].
  // ---------------------------------------------------------------------------
  const FLAG_OPTS = { 0: 'None', 1: 'Start', 2: 'Caution (yellow)', 5: 'Stop (black)', 8: 'ReturnToPits', 12: 'FasterCar (blue)', 13: 'Finished (chequered)', 14: 'OneLapLeft (white)' };
  const SESSION_OPTS = { 1: 'Practice', 2: 'Qualify', 3: 'Race', 4: 'Hotlap' };
  const ERS_OPTS = Object.fromEntries(Sim.ERS_MODE_NAMES.map((n, i) => [i, `${i} ${n}`]));
  const GROUPS = [
    ['Driving', [['car.speedKmh', 0, 360, 1], ['car.rpm', 0, 12500, 10], ['car.gear', -1, 8, 1], ['car.gas', 0, 1, 0.01],
      ['car.brake', 0, 1, 0.01], ['car.clutch', 0, 1, 0.01], ['car.steer', -200, 200, 1]]],
    ['Shiftlights / limiter', [['car.rpm', 0, 12500, 10], ['car.rpmLimiter', 8000, 15000, 50], ['car.isEngineLimiterOn', 'bool'], ['car.gearCount', 1, 8, 1]]],
    ['DRS', [['car.drsPresent', 'bool'], ['car.drsAvailable', 'bool'], ['car.drsActive', 'bool']]],
    ['ERS / hybrid', [['car.kersCharge', 0, 1, 0.01], ['car.kersInput', 0, 1, 0.01], ['car.kersLoad', 0, 1, 0.01],
      ['car.kersCharging', 'bool'], ['car.kersCurrentKJ', 0, 4000, 10], ['car.kersMaxKJ', 0, 8000, 100], ['car.kersButtonPressed', 'bool'],
      ['car.mgukDelivery', ERS_OPTS], ['car.mgukDeliveryCount', 1, 8, 1], ['car.mgukRecovery', 0, 10, 1], ['car.mguhChargingBatteries', 'bool']]],
    ['Engine and strategy switches', [['car.currentEngineBrakeSetting', 0, 10, 1], ['car.engineBrakeSettingsCount', 1, 13, 1],
      ['car.fuelMap', 0, 3, 1], ['car.brakeBias', 0.4, 0.7, 0.005], ['car.tractionControlMode', 0, 10, 1], ['car.absMode', 0, 10, 1]]],
    ['Pit', [['car.isInPitlane', 'bool'], ['car.isInPit', 'bool'], ['car.manualPitsSpeedLimiterEnabled', 'bool'],
      ['car.speedLimiterInAction', 'bool'], ['car.speedLimiter', 0, 120, 1]]],
    ['Lap', [['car.lapTimeMs', 0, 200000, 1], ['car.previousLapTimeMs', 0, 200000, 1], ['car.bestLapTimeMs', 0, 200000, 1],
      ['car.estimatedLapTimeMs', 0, 200000, 1], ['car.performanceMeter', -5, 5, 0.001], ['car.lapCount', 0, 80, 1],
      ['car.currentSector', 0, 2, 1], ['car.racePosition', 1, 22, 1], ['car.isLapValid', 'bool'], ['car.splinePosition', 0, 1, 0.001]]],
    ['Fuel and temperatures', [['car.fuel', 0, 110, 0.1], ['car.maxFuel', 0, 150, 1], ['car.fuelPerLap', 0, 5, 0.01],
      ['car.waterTemperature', 40, 140, 0.5], ['car.oilTemperature', 40, 160, 0.5], ['car.oilPressure', 0, 10, 0.1]]],
    ['Tyres', [['w.tyreCoreTemperature', 20, 160, 0.5], ['w.tyreInsideTemperature', 20, 160, 0.5], ['w.tyreMiddleTemperature', 20, 160, 0.5],
      ['w.tyreOutsideTemperature', 20, 160, 0.5], ['w.tyreOptimumTemperature', 60, 130, 1], ['w.tyrePressure', 15, 30, 0.1],
      ['w.tyreWear', 0, 1, 0.01], ['w.discTemperature', 0, 1300, 5]], 'wheels'],
    ['Steering wheel buttons', [['car.extraA', 'bool'], ['car.extraB', 'bool'], ['car.extraC', 'bool'], ['car.extraD', 'bool'],
      ['car.extraE', 'bool'], ['car.extraF', 'bool'], ['car.headlightsActive', 'bool'], ['car.flashingLightsActive', 'bool']]],
    ['G-forces', [['car.acceleration.x', -6, 6, 0.05], ['car.acceleration.z', -6, 6, 0.05]]],
    ['Session (sim)', [['sim.raceFlagType', FLAG_OPTS], ['sim.raceSessionType', SESSION_OPTS], ['sim.timeHours', 0, 23, 1],
      ['sim.ambientTemperature', -5, 45, 0.5], ['sim.roadTemperature', -5, 65, 0.5], ['sim.rainIntensity', 0, 1, 0.01], ['sim.isPaused', 'bool']]],
    ['VRC CAN-bus (can.bus / can.stream)', [['can.bus.displayPage', 1, 3, 1], ['can.bus.isIgnitionStage2', 'bool'], ['can.bus.isEngineRunning', 'bool'],
      ['can.bus.isAntistallActive', 'bool'], ['can.bus.puMode', 0, 5, 1], ['can.bus.engineBrakeSetting', 0, 10, 1],
      ['can.bus.differentialEntrySetting', 0, 10, 1], ['can.bus.differentialMidSetting', 0, 10, 1], ['can.bus.differentialExitHispdSetting', 0, 10, 1],
      ['can.bus.frontBias', 0.4, 0.7, 0.005], ['can.bus.brakeMigration', 0, 0.1, 0.005], ['can.bus.brakeShapeMap', 1, 5, 1],
      ['can.bus.fuelUseTarget', 0, 4, 0.01], ['can.bus.lapDelta', 0, 2, 1], ['can.bus.pitSpeedLimit', 40, 120, 1],
      ['can.stream.kersChargeMJ', 0, 4, 0.01], ['can.stream.kersDeployMJ', 0, 4, 0.01], ['can.stream.kersRegenMJ', 0, 2, 0.01]]],
  ];

  const WHEEL_NAMES = ['FL', 'FR', 'RL', 'RR'];
  let wheelPick = 0; // 0..3, or 4 = all
  const rows = [];

  function fmtVal(v, step) {
    if (typeof v === 'boolean') return v ? 'on' : 'off';
    if (typeof v !== 'number' || !isFinite(v)) return String(v);
    const dec = step >= 1 ? 0 : step >= 0.1 ? 1 : step >= 0.01 ? 2 : 3;
    return v.toFixed(dec);
  }

  function wheelPaths(field) {
    const name = field.slice(2);
    return wheelPick === 4 ? [0, 1, 2, 3].map((i) => `wheels.${i}.${name}`) : [`wheels.${wheelPick}.${name}`];
  }
  const pathsOf = (spec) => (spec[0].startsWith('w.') ? wheelPaths(spec[0]) : [spec[0]]);

  function buildPanel() {
    const groupsEl = $('#groups');
    for (const [title, specs, special] of GROUPS) {
      const det = document.createElement('details');
      det.innerHTML = `<summary>${esc(title)}<span class="count"></span></summary><div class="rows"></div>`;
      const rowsEl = det.querySelector('.rows');
      const groupRows = [];
      if (special === 'wheels') {
        const pick = document.createElement('div');
        pick.className = 'wheelPick';
        [...WHEEL_NAMES, 'alle'].forEach((n, i) => {
          const b = document.createElement('button');
          b.textContent = n;
          b.classList.toggle('on', i === wheelPick);
          b.onclick = () => { wheelPick = i; pick.querySelectorAll('button').forEach((x, j) => x.classList.toggle('on', j === i)); };
          pick.appendChild(b);
        });
        rowsEl.appendChild(pick);
      }
      for (const spec of specs) {
        const [path, a, b, step] = spec;
        const row = document.createElement('div');
        row.className = 'row';
        const label = path.replace(/^car\.wheels\./, '').replace(/^w\./, 'wheels[i].');
        row.innerHTML = `<label class="mono" title="${esc(label)}">${esc(label)}</label><div class="ctl"></div><span class="val mono"></span><span class="src" title="Click to go back to the simulation">SIM</span>`;
        const ctl = row.querySelector('.ctl');
        let input;
        if (a === 'bool') {
          input = document.createElement('button');
          input.className = 'toggle';
          input.onclick = () => {
            const cur = !!model.get(pathsOf(spec)[0]);
            for (const p of pathsOf(spec)) model.setManual(p, !cur);
          };
        } else if (typeof a === 'object') {
          input = document.createElement('select');
          for (const [v, n] of Object.entries(a)) input.add(new Option(n, v));
          input.onchange = () => { for (const p of pathsOf(spec)) model.setManual(p, Number(input.value)); };
        } else {
          input = document.createElement('input');
          input.type = 'range';
          input.min = a; input.max = b; input.step = step;
          input.oninput = () => { for (const p of pathsOf(spec)) model.setManual(p, Number(input.value)); };
        }
        ctl.appendChild(input);
        row.querySelector('.src').onclick = () => { for (const p of pathsOf(spec)) model.clearManual(p); };
        const r = { spec, row, input, val: row.querySelector('.val'), src: row.querySelector('.src'), details: det };
        rows.push(r);
        groupRows.push(r);
        rowsEl.appendChild(row);
      }
      det._rows = groupRows;
      groupsEl.appendChild(det);
    }
  }

  function refreshPanel() {
    const counts = new Map();
    for (const r of rows) {
      const paths = pathsOf(r.spec);
      const manual = paths.some((p) => model.isManual(p));
      const v = model.get(paths[0]);
      r.row.classList.toggle('manual', manual);
      r.src.textContent = manual ? 'MAN' : 'SIM';
      if (manual) counts.set(r.details, (counts.get(r.details) || 0) + 1);
      if (!r.details.open) continue;
      const [, a, , step] = r.spec;
      r.val.textContent = fmtVal(v, step);
      if (document.activeElement === r.input) continue;
      if (a === 'bool') { r.input.textContent = v ? 'ON' : 'off'; r.input.classList.toggle('on', !!v); }
      else if (r.input.tagName === 'SELECT') r.input.value = String(v);
      else r.input.value = v;
    }
    for (const det of document.querySelectorAll('#groups details')) {
      const n = counts.get(det) || 0;
      det.querySelector('.count').textContent = n ? `${n} manual` : '';
    }
  }

  // ---------------------------------------------------------------------------
  buildControls();
  buildFlags();
  buildPitMenu();
  buildPanel();
  layout();
  await startRuntime('start');
  requestAnimationFrame((t) => { last = t; tick(t); });
})().catch((e) => {
  document.body.insertAdjacentHTML('afterbegin', `<pre style="color:#f66;padding:12px">Preview could not start: ${e.stack || e}</pre>`);
});
