// render.js: draws the command buffer produced by csp-shim.lua onto a 2D canvas.
// Commands are arrays: [op, ...args]. Coordinates are display texture pixels.

(function () {
  'use strict';

  const fonts = { families: new Set(), warned: new Set(), onWarn: null };

  const WEIGHTS = {
    Thin: 100, UltraLight: 200, Light: 300, SemiLight: 350, Regular: 400, Medium: 500,
    SemiBold: 600, Bold: 700, UltraBold: 800, Black: 900, UltraBlack: 950,
  };
  const STRETCH = {
    UltraCondensed: 'ultra-condensed', ExtraCondensed: 'extra-condensed', Condensed: 'condensed',
    SemiCondensed: 'semi-condensed', Medium: 'normal', SemiExpanded: 'semi-expanded', Expanded: 'expanded',
    ExtraExpanded: 'extra-expanded', UltraExpanded: 'ultra-expanded',
  };

  // Parses a CSP font string: 'Name:path;Weight=Bold;Style=Italic;Stretch=Expanded'
  const fontCache = new Map();
  function parseFont(spec) {
    let f = fontCache.get(spec);
    if (f) return f;
    const [head, ...attrs] = spec.split(';');
    const family = head.split(':')[0].trim() || 'Segoe UI';
    f = { family, weight: 400, style: 'normal', stretch: 'normal' };
    for (const a of attrs) {
      const [k, v] = a.split('=').map((s) => s && s.trim());
      if (k === 'Weight') f.weight = WEIGHTS[v] || 400;
      else if (k === 'Style') f.style = v === 'Normal' ? 'normal' : 'italic';
      else if (k === 'Stretch') f.stretch = STRETCH[v] || 'normal';
    }
    const known = fonts.families.has(family);
    if (!known && family !== 'Segoe UI' && !fonts.warned.has(family)) {
      fonts.warned.add(family);
      fonts.onWarn && fonts.onWarn(`font "${family}" not found in dash/fonts/, falling back to a system font`);
    }
    const fam = known ? `"${family}"` : family === 'Segoe UI' ? '"Segoe UI", system-ui, sans-serif' : 'sans-serif';
    f.css = (size) => `${f.style} ${f.weight} ${size}px ${fam}, sans-serif`;
    fontCache.set(spec, f);
    return f;
  }

  // Measuring uses its own context so it can run while Lua builds the frame.
  const measureCtx = document.createElement('canvas').getContext('2d');
  function applyFont(ctx, spec, size) {
    const f = parseFont(spec);
    ctx.font = f.css(size);
    if ('fontStretch' in ctx) ctx.fontStretch = f.stretch;
    return f;
  }
  function measure(text, size, spec) {
    applyFont(measureCtx, spec, size);
    const m = measureCtx.measureText(text);
    const asc = m.fontBoundingBoxAscent ?? size * 0.9;
    const desc = m.fontBoundingBoxDescent ?? size * 0.25;
    return [m.width, asc + desc, asc];
  }

  // Images, loaded on demand by path relative to the script folder.
  const images = new Map();
  let knownSizes = {};
  function setKnownSizes(sizes) { knownSizes = sizes || {}; }
  function getImage(path) {
    let e = images.get(path);
    if (!e) {
      const zip = /^zip:(.*)\|(.*)$/.exec(path);
      const url = zip ? `/api/zip?zip=${encodeURIComponent(zip[1])}&name=${encodeURIComponent(zip[2])}`
        : '/' + path.replace(/\\/g, '/').replace(/^\.?\//, '');
      e = { img: new Image(), ready: false, failed: false };
      e.img.onload = () => { e.ready = true; };
      e.img.onerror = () => {
        e.failed = true;
        fonts.onWarn && fonts.onWarn(`image not found: ${path}`);
      };
      e.img.src = url;
      images.set(path, e);
    }
    return e;
  }
  function imageSize(path) {
    const e = getImage(path);
    if (e.ready) return [e.img.naturalWidth, e.img.naturalHeight];
    return knownSizes[path] || [0, 0]; // sizes from serve.js, so scripts can ask at load time

  }
  function reloadImages() { images.clear(); }

  const c255 = (v) => Math.max(0, Math.min(255, Math.round(v * 255)));
  const rgba = (r, g, b, a) => `rgba(${c255(r)},${c255(g)},${c255(b)},${Math.max(0, Math.min(1, a))})`;

  function roundedRectPath(ctx, x1, y1, x2, y2, rounding, flags) {
    const w = x2 - x1, h = y2 - y1;
    ctx.beginPath();
    if (rounding > 0 && flags) {
      const r = Math.min(rounding, Math.abs(w) / 2, Math.abs(h) / 2);
      ctx.roundRect(x1, y1, w, h, [flags & 1 ? r : 0, flags & 2 ? r : 0, flags & 8 ? r : 0, flags & 4 ? r : 0]);
    } else ctx.rect(x1, y1, w, h);
  }

  function ellipsePath(ctx, cx, cy, rx, ry, segs) {
    // ImGui draws circles as polygons: keep the segment count visible on purpose.
    segs = Math.max(3, segs | 0);
    ctx.beginPath();
    for (let i = 0; i < segs; i++) {
      const a = (i / segs) * Math.PI * 2;
      const x = cx + Math.cos(a) * rx, y = cy + Math.sin(a) * ry;
      i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
    }
    ctx.closePath();
  }

  const gradCanvas = document.createElement('canvas');
  gradCanvas.width = gradCanvas.height = 2;
  const gradCtx = gradCanvas.getContext('2d');
  const tintCanvas = document.createElement('canvas');
  const tintCtx = tintCanvas.getContext('2d');

  // Bounding box of a command (for ui.endRotation pivots).
  function bbox(c) {
    const op = c[0];
    switch (op) {
      case 'rect': case 'rectF': case 'rectGrad': case 'line': case 'clip':
        return [Math.min(c[1], c[3]), Math.min(c[2], c[4]), Math.max(c[1], c[3]), Math.max(c[2], c[4])];
      case 'circle': case 'circleF':
        return [c[1] - c[3], c[2] - c[4], c[1] + c[3], c[2] + c[4]];
      case 'image':
        return [c[2], c[3], c[4], c[5]];
      case 'text':
        return [c[4], c[5], c[4] + c[10], c[5] + c[11]];
      case 'acText':
        return [c[3], c[4], c[3] + c[1].length * c[5], c[4] + c[6]];
      case 'poly': case 'polyF': case 'bezier': case 'imageQuad': {
        const start = op === 'poly' ? 7 : op === 'polyF' ? 5 : op === 'bezier' ? 1 : 2;
        const end = op === 'bezier' ? 9 : op === 'imageQuad' ? 10 : c.length;
        let x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity;
        for (let i = start; i + 1 < end; i += 2) {
          x1 = Math.min(x1, c[i]); y1 = Math.min(y1, c[i + 1]);
          x2 = Math.max(x2, c[i]); y2 = Math.max(y2, c[i + 1]);
        }
        return [x1, y1, x2, y2];
      }
    }
    return null;
  }

  // Command buffer for one frame. Transforms are resolved here so the renderer
  // only needs push/pop of plain matrices.
  class Frame {
    constructor() {
      this.cmds = [];
      this.leds = [];
      this.tStack = [];
      this.clipDepth = 0;
    }
    push(c) {
      const op = c[0];
      if (op === 'led') { this.leds[c[1] - 1] = [c[2], c[3], c[4], c[5]]; return; }
      if (op === 'text') {
        const [w, h, asc] = measure(c[1], c[2], c[3]);
        c.push(w, h, asc);
      }
      if (op === 'beginT') { this.tStack.push(this.cmds.length); this.cmds.push(['noop']); return; }
      if (op === 'endRot' || op === 'endPivotRot' || op === 'endScale' || op === 'endNoop') {
        const start = this.tStack.pop();
        if (start === undefined) return;
        if (op === 'endNoop') return;
        let x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity;
        for (let i = start + 1; i < this.cmds.length; i++) {
          const b = bbox(this.cmds[i]);
          if (!b) continue;
          x1 = Math.min(x1, b[0]); y1 = Math.min(y1, b[1]);
          x2 = Math.max(x2, b[2]); y2 = Math.max(y2, b[3]);
        }
        if (x1 === Infinity) return;
        let cx = (x1 + x2) / 2, cy = (y1 + y2) / 2, ox = 0, oy = 0, m;
        if (op === 'endScale') {
          m = ['scale', cx, cy, c[1], c[2]];
        } else {
          // CSP rotates counter-clockwise with a built-in 90° offset: endRotation(a + 90) turns by a.
          const deg = c[1];
          if (op === 'endPivotRot') { cx = c[2]; cy = c[3]; ox = c[4]; oy = c[5]; } else { ox = c[2]; oy = c[3]; }
          m = ['rot', cx, cy, (-(deg - 90) * Math.PI) / 180, ox, oy];
        }
        this.cmds[start] = ['pushT', m];
        this.cmds.push(['popT']);
        return;
      }
      this.cmds.push(c);
    }
  }

  function render(ctx, frame) {
    ctx.save();
    let depth = 0;
    for (const c of frame.cmds) {
      switch (c[0]) {
        case 'noop': break;
        case 'rect': {
          const t = c[11];
          roundedRectPath(ctx, c[1] + t / 2, c[2] + t / 2, c[3] - t / 2, c[4] - t / 2, c[9], c[10]);
          ctx.strokeStyle = rgba(c[5], c[6], c[7], c[8]);
          ctx.lineWidth = t;
          ctx.stroke();
          break;
        }
        case 'rectF':
          roundedRectPath(ctx, c[1], c[2], c[3], c[4], c[9], c[10]);
          ctx.fillStyle = rgba(c[5], c[6], c[7], c[8]);
          ctx.fill();
          break;
        case 'rectGrad': {
          // Bilinear 4-corner gradient: 2x2 image scaled up between pixel centres.
          const id = gradCtx.createImageData(2, 2);
          const corners = [[5, 0], [9, 4], [13, 12], [17, 8]]; // TL, TR, BR, BL (arg index, byte offset)
          for (const [ai, off] of corners) {
            id.data[off] = c255(c[ai]); id.data[off + 1] = c255(c[ai + 1]);
            id.data[off + 2] = c255(c[ai + 2]); id.data[off + 3] = c255(c[ai + 3]);
          }
          gradCtx.putImageData(id, 0, 0);
          ctx.imageSmoothingEnabled = true;
          ctx.drawImage(gradCanvas, 0.5, 0.5, 1, 1, c[1], c[2], c[3] - c[1], c[4] - c[2]);
          break;
        }
        case 'line':
          ctx.beginPath();
          ctx.moveTo(c[1], c[2]);
          ctx.lineTo(c[3], c[4]);
          ctx.strokeStyle = rgba(c[5], c[6], c[7], c[8]);
          ctx.lineWidth = c[9];
          ctx.lineCap = 'butt';
          ctx.stroke();
          break;
        case 'circle':
          ellipsePath(ctx, c[1], c[2], c[3], c[4], c[9]);
          ctx.strokeStyle = rgba(c[5], c[6], c[7], c[8]);
          ctx.lineWidth = c[10];
          ctx.stroke();
          break;
        case 'circleF':
          ellipsePath(ctx, c[1], c[2], c[3], c[4], c[9]);
          ctx.fillStyle = rgba(c[5], c[6], c[7], c[8]);
          ctx.fill();
          break;
        case 'poly': case 'polyF': {
          const stroke = c[0] === 'poly';
          const start = stroke ? 7 : 5;
          ctx.beginPath();
          ctx.moveTo(c[start], c[start + 1]);
          for (let i = start + 2; i + 1 < c.length; i += 2) ctx.lineTo(c[i], c[i + 1]);
          if (stroke) {
            if (c[6]) ctx.closePath();
            ctx.strokeStyle = rgba(c[1], c[2], c[3], c[4]);
            ctx.lineWidth = c[5];
            ctx.lineJoin = 'miter';
            ctx.stroke();
          } else {
            ctx.closePath();
            ctx.fillStyle = rgba(c[1], c[2], c[3], c[4]);
            ctx.fill();
          }
          break;
        }
        case 'bezier':
          ctx.beginPath();
          ctx.moveTo(c[1], c[2]);
          ctx.bezierCurveTo(c[3], c[4], c[5], c[6], c[7], c[8]);
          ctx.strokeStyle = rgba(c[9], c[10], c[11], c[12]);
          ctx.lineWidth = c[13];
          ctx.stroke();
          break;
        case 'text': {
          // [text, size, font, x, y, r, g, b, a, w, h, ascent]
          const f = applyFont(ctx, c[3], c[2]);
          ctx.textBaseline = 'alphabetic';
          ctx.textAlign = 'left';
          ctx.fillStyle = rgba(c[6], c[7], c[8], c[9]);
          ctx.fillText(c[1], c[4], c[5] + c[12]);
          // Fonts from dash/fonts or VRC are loaded as a single (regular) face and the canvas
          // doesn't fake bold for those. DirectWrite does (bold simulation), so emulate it.
          if (f.weight >= 600 && fonts.families.has(f.family)) {
            ctx.strokeStyle = ctx.fillStyle;
            ctx.lineJoin = 'round';
            ctx.lineWidth = c[2] * 0.04 * (f.weight - 400) / 300;
            ctx.strokeText(c[1], c[4], c[5] + c[12]);
          }
          break;
        }
        case 'acText': {
          // AC bitmap fonts are approximated with a monospace font, one cell per letter.
          const [, text, , x, y, lw, lh, spacing, r, g, b, a] = c;
          ctx.font = `${lh}px ui-monospace, Menlo, monospace`;
          ctx.textBaseline = 'top';
          ctx.textAlign = 'left';
          ctx.fillStyle = rgba(r, g, b, a);
          for (let i = 0; i < text.length; i++) {
            const cx = x + i * (lw + spacing);
            const cw = ctx.measureText(text[i]).width || lw;
            ctx.save();
            ctx.translate(cx, y);
            ctx.scale(lw / cw, 1);
            ctx.fillText(text[i], 0, 0);
            ctx.restore();
          }
          break;
        }
        case 'image': {
          const [, path, x1, y1, x2, y2, r, g, b, a, u1, v1, u2, v2, keep] = c;
          const e = getImage(path);
          if (!e.ready) break;
          const iw = e.img.naturalWidth, ih = e.img.naturalHeight;
          const sx = u1 * iw, sy = v1 * ih, sw = (u2 - u1) * iw, sh = (v2 - v1) * ih;
          let dx = x1, dy = y1, dw = x2 - x1, dh = y2 - y1;
          if (keep) {
            const k = Math.min(dw / sw, dh / sh);
            dx += (dw - sw * k) / 2; dy += (dh - sh * k) / 2; dw = sw * k; dh = sh * k;
          }
          ctx.globalAlpha = Math.max(0, Math.min(1, a));
          if (r === 1 && g === 1 && b === 1) {
            ctx.drawImage(e.img, sx, sy, sw, sh, dx, dy, dw, dh);
          } else {
            tintCanvas.width = Math.max(1, Math.ceil(Math.abs(dw)));
            tintCanvas.height = Math.max(1, Math.ceil(Math.abs(dh)));
            tintCtx.globalCompositeOperation = 'source-over';
            tintCtx.drawImage(e.img, sx, sy, sw, sh, 0, 0, tintCanvas.width, tintCanvas.height);
            tintCtx.globalCompositeOperation = 'multiply';
            tintCtx.fillStyle = rgba(r, g, b, 1);
            tintCtx.fillRect(0, 0, tintCanvas.width, tintCanvas.height);
            tintCtx.globalCompositeOperation = 'destination-in';
            tintCtx.drawImage(e.img, sx, sy, sw, sh, 0, 0, tintCanvas.width, tintCanvas.height);
            ctx.drawImage(tintCanvas, dx, dy, dw, dh);
          }
          ctx.globalAlpha = 1;
          break;
        }
        case 'imageQuad': {
          // Affine approximation using p1, p2, p4.
          const [, path, x1, y1, x2, y2, , , x4, y4, , , , a] = c;
          const e = getImage(path);
          if (!e.ready) break;
          const iw = e.img.naturalWidth, ih = e.img.naturalHeight;
          ctx.save();
          ctx.globalAlpha = Math.max(0, Math.min(1, a));
          ctx.transform((x2 - x1) / iw, (y2 - y1) / iw, (x4 - x1) / ih, (y4 - y1) / ih, x1, y1);
          ctx.drawImage(e.img, 0, 0);
          ctx.restore();
          break;
        }
        case 'clip':
          ctx.save();
          depth++;
          ctx.beginPath();
          ctx.rect(c[1], c[2], c[3] - c[1], c[4] - c[2]);
          ctx.clip();
          break;
        case 'unclip':
          if (depth > 0) { ctx.restore(); depth--; }
          break;
        case 'pushT': {
          ctx.save();
          depth++;
          const m = c[1];
          if (m[0] === 'rot') {
            ctx.translate(m[1] + m[4], m[2] + m[5]);
            ctx.rotate(m[3]);
            ctx.translate(-m[1], -m[2]);
          } else {
            ctx.translate(m[1], m[2]);
            ctx.scale(m[3], m[4]);
            ctx.translate(-m[1], -m[2]);
          }
          break;
        }
        case 'popT':
          if (depth > 0) { ctx.restore(); depth--; }
          break;
      }
    }
    while (depth-- > 0) ctx.restore();
    ctx.restore();
  }

  window.Render = { Frame, render, measure, imageSize, reloadImages, setKnownSizes, fonts };
})();
