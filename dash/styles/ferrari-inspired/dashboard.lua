-- dashboard.lua (Ferrari-inspired): steering wheel display inspired by the Ferrari F1 wheel
-- (built from onboard footage; unofficial).
-- A grid with thin white lines: lap time / lap / delta on top, the gear in the middle, the
-- tyres as colored blocks, side bars left and right and the battery bar at the bottom.
--
-- Module: { update = fn(dt), leds = 15 rgbm (preview), ledModule = shift light state (AC) }.
-- Pages (settings.pages, the wheel's page switch): 'race' and 'quali', also with the engine off.
-- On top of them: launch (the page on a background that fades green -> red -> blue with the RPM),
-- the pit limiter, antistall and full-screen pop-ups. After the line the top row
-- shows the lap just driven.

local settings = require('dash.styles.ferrari-inspired.settings')
local data = require('dash.core.data')
local format = require('dash.core.format')
local draw = require('dash.core.draw')
local Leds = require('dash.core.leds')
local Popups = require('dash.core.popups')
local LapPopup = require('dash.core.lappopup')
local Pages = require('dash.core.pages')

draw.setArea(settings.display)
local W = draw.W
local A = ui.Alignment

local function color(c) return rgbm(c[1], c[2], c[3], c[4] or 1) end
local C = {}
for name, c in pairs(settings.colors) do C[name] = color(c) end
local POPUP_COLORS = {}
for key, p in pairs(settings.popupColors) do
  POPUP_COLORS[key] = { box = p.box and color(p.box), value = color(p.value) }
end

local family = settings.fonts.family
local F = {
  regular = ui.DWriteFont(family),
  bold = ui.DWriteFont(family):weight(ui.DWriteFont.Weight.Bold),
}

local leds = Leds.new(settings.shiftLights, settings.palette)
local popups = Popups.new({
  { key = 'brakeBias', label = 'BBAL', fmt = '%.1f' },
  { key = 'brakeShape', label = 'BMIG', fmt = '%d' },
  { key = 'ersMode', label = 'SOC', fmt = '%d' },
  { key = 'puMode', label = 'MODE', fmt = '%d', names = settings.puModeNames },
  { key = 'engineBrake', label = 'EB', fmt = '%d' },
  { key = 'diffEntry', label = 'ENT', fmt = '%d' },
  { key = 'diffMid', label = 'MID', fmt = '%d' },
  { key = 'diffExit', label = 'EXIT', fmt = '%d' },
}, settings.popupDuration)
local lapPopup = LapPopup.new(settings.lapPopupDuration)

-- ---------------------------------------------------------------------------
-- Parts
-- ---------------------------------------------------------------------------

local function value(d, key, fmt)
  if key == 'diff' then
    return (d.diffEntry and d.diffMid and d.diffExit) and string.format(fmt, d.diffEntry, d.diffMid, d.diffExit) or '-'
  end
  local v = d[key]
  if fmt == 'name' then return v ~= nil and settings.puModeNames[v] or '-' end -- PU mode by name
  return v ~= nil and string.format(fmt, v) or '-'
end

-- Flags: the gear cell takes the flag color during a yellow or blue flag.
local FLAG_CELL = {}
for name, c in pairs(settings.flagColors or {}) do
  if ac.FlagType[name] then FLAG_CELL[ac.FlagType[name]] = color(c) end
end
local BLACK = rgbm(0, 0, 0, 1)

-- Battery bar: a separate red piece for the lowest zone, then the green part, both with a
-- cut-off top-left corner. Charged = solid, empty = dark blocks with lines between.
local function chamferedRect(x, y, w, h, ch, col)
  draw.rect(x + ch - 1, y, w - ch + 1, h, col) -- 1 px overlap with the corner: no seam
  draw.quad(x, y + ch, x + ch, y, x + ch, y + h, x, y + h, col)
end

local function ersBar(d, rect)
  local cfg = settings.ersBar
  local x, y, w, h = rect.x, rect.y, rect.w, rect.h
  local lowX, ch, gap = x + w * cfg.lowZone, cfg.chamfer, 3
  local pieces = { { x, lowX - gap }, { lowX + gap, x + w } }
  for _, p in ipairs(pieces) do chamferedRect(p[1], y, p[2] - p[1], h, ch, p == pieces[1] and C.ersLow or C.ersFull) end
  -- Empty blocks stay inside their piece (not over the gap) and follow its cut-off corner.
  local n, inset = cfg.blocks, 4
  local chIn = ch - inset * (2 - math.sqrt(2)) -- the corner inset by `inset` px along the diagonal
  local line = 1.5 -- half the width of the lines between empty blocks
  local bw = w / n
  local fill = x + w * math.saturate(d.ersCharge)
  for i = 1, n do
    local bx0, bx1 = x + (i - 1) * bw + line, x + i * bw - line
    for _, p in ipairs(pieces) do
      local p0 = p[1] + inset
      local from, to = math.max(bx0, fill, p0), math.min(bx1, p[2] - inset)
      if from < to then
        if from < p0 + chIn then chamferedRect(p0, y + inset, to - p0, h - 2 * inset, chIn, C.ersEmpty)
        else draw.rect(from, y + inset, to - from, h - 2 * inset, C.ersEmpty) end
      end
    end
  end
end

-- Sets `out` to the color between the { value, color } stops (rising values) for `v`.
-- The brightness is kept while fading, so green -> red passes yellow instead of olive.
local function fadeColor(stops, v, out)
  local c = stops[#stops][2]
  local r, g, b = c[1], c[2], c[3]
  if v <= stops[1][1] then
    c = stops[1][2]
    r, g, b = c[1], c[2], c[3]
  else
    for i = 2, #stops do
      local lo, hi = stops[i - 1], stops[i]
      if v < hi[1] then
        local k = (v - lo[1]) / (hi[1] - lo[1])
        r = math.lerp(lo[2][1], hi[2][1], k)
        g = math.lerp(lo[2][2], hi[2][2], k)
        b = math.lerp(lo[2][3], hi[2][3], k)
        local peak = math.lerp(math.max(lo[2][1], lo[2][2], lo[2][3]), math.max(hi[2][1], hi[2][2], hi[2][3]), k)
        local s = peak / math.max(r, g, b, 0.001)
        r, g, b = r * s, g * s, b * s
        break
      end
    end
  end
  out.r, out.g, out.b = r, g, b
  return out
end

-- Background: black, or during a launch a color between the stops for the current RPM.
local background = rgbm(0, 0, 0, 1)
local function launchColor(d)
  return fadeColor(settings.launchScreen.stops, d.rpm, background)
end

-- ---------------------------------------------------------------------------
-- Race page (helmet-cam shots batch2/22.23.07, and 22.16.18 for the first seconds after the line)
-- ---------------------------------------------------------------------------
-- Columns: left a|b, centre a|b, right a|b. Rows: top row, then rows 1..4; the tyres split
-- rows 3-4 in two, the gear spans rows 1-2. Teal bars on both sides, the battery bar below.
local RX = { 50, 209, 364, 519, 652, 829, 980 }
local RY = { 8, 89, 182, 275, 381, 525 }
local TYRE_Y = { 275, 400, 525 }
local RACE_BAR = { x = 6, y = 534, w = 1012, h = 36 } -- full width, like before
local SIDE_L = { x = 6, y = 8, w = 36, h = 517 }
local SIDE_R = { x = 986, y = 8, w = 32, h = 517 }

local TYRE_BLOCK = { rgbm(0, 0, 0, 1), rgbm(0, 0, 0, 1), rgbm(0, 0, 0, 1), rgbm(0, 0, 0, 1) }
local lapSummary = LapPopup.new(settings.lapSummaryDuration, true)

-- `quali` = the right side like the left: brake | tyre columns down to the bottom.
local function raceGrid(col, quali)
  draw.outline(RX[1], RY[1], RX[7] - RX[1], RY[6] - RY[1], col, 1.5)
  for _, y in ipairs({ RY[2], RY[4] }) do draw.line(RX[1], y, RX[7], y, col, 1.5) end
  draw.line(RX[1], RY[3], RX[3], RY[3], col, 1.5)            -- left rows 1|2
  draw.line(RX[5], RY[3], RX[7], RY[3], col, 1.5)            -- right rows 1|2
  draw.line(RX[3], RY[5], RX[5], RY[5], col, 1.5)            -- mode name | small cells
  draw.line(RX[1], TYRE_Y[2], RX[3], TYRE_Y[2], col, 1.5)    -- tyres front | rear
  for _, x in ipairs({ RX[3], RX[5] }) do draw.line(x, RY[1], x, RY[6], col, 1.5) end
  draw.line(RX[2], RY[2], RX[2], RY[6], col, 1.5)
  draw.line(RX[6], RY[2], RX[6], quali and RY[6] or RY[4], col, 1.5)
  draw.line(RX[4], RY[5], RX[4], RY[6], col, 1.5)
  if quali then draw.line(RX[5], TYRE_Y[2], RX[7], TYRE_Y[2], col, 1.5) end -- tyres front | rear
end

-- Small cell: tiny label top left, value centered.
local function smallCell(x0, x1, y0, y1, label, text, size, col, bg, labelCol)
  if bg then draw.rect(x0 + 3, y0 + 3, x1 - x0 - 6, y1 - y0 - 6, bg) end
  if label and settings.labels then draw.text(label, 13, x0 + 6, y0 + 3, x1 - x0 - 12, 16, labelCol or C.label, F.bold, A.Start) end
  draw.text(text, size, x0, y0 + 8, x1 - x0, y1 - y0 - 8, col, F.regular)
end

local function cellColor(d, c)
  if c[4] == 'fuel' then
    return (d.fuelTarget and d.fuelPerLap > d.fuelTarget) and C.rpm or C.green
  end
  return C[c[4]] or C.text
end

-- Two cells per row, row by row, in the box x0..x2 (split at x1) from row r.
local function cellPairs(list, d, x0, x1, x2, r)
  for i, c in ipairs(list) do
    local row = r + math.floor((i - 1) / 2)
    local left = i % 2 == 1
    smallCell(left and x0 or x1, left and x1 or x2, RY[row], RY[row + 1], c[1], value(d, c[2], c[3]), 40, cellColor(d, c))
  end
end

-- Top row: lap time | lap number | delta. `rpmMiddle`: the RPM (red) instead of the lap number,
-- like at a launch. After the line (pop-up time): the lap just driven.
local function raceTop(d, rpmMiddle)
  if lapPopup.active then -- the lap just driven (22.01.35), for the pit-menu pop-up time
    smallCell(RX[1], RX[3], RY[1], RY[2], 'LAP TIME', format.lapTime(lapPopup.timeMs), 48, lapPopup.isBest and C.best or C.text)
    smallCell(RX[3], RX[5], RY[1], RY[2], nil, string.format('LAP %d', lapPopup.number), 44, C.text)
    if lapPopup.diff then
      smallCell(RX[5], RX[7], RY[1], RY[2], 'BEST', format.delta2(lapPopup.diff), 48, lapPopup.diff < 0 and C.green or C.rpm)
    end
    return
  end
  smallCell(RX[1], RX[3], RY[1], RY[2], nil, format.lapTime(d.lapTimeMs), 46, C.green)
  if d.launch or rpmMiddle then -- start / clutch in: the RPM big in red instead of the lap number
    smallCell(RX[3], RX[5], RY[1], RY[2], nil, string.format('%d', math.floor(d.rpm + 0.5)), 64, C.rpm)
  else
    smallCell(RX[3], RX[5], RY[1], RY[2], 'LAP', string.format('%d', d.lap), 46, C.text)
  end
  smallCell(RX[5], RX[7], RY[1], RY[2], nil, format.delta2(d.delta), 46, C.delta)
end

local function raceGear(d)
  local flag = FLAG_CELL[d.flag]
  if flag then draw.rect(RX[3] + 3, RY[2] + 3, RX[5] - RX[3] - 6, RY[4] - RY[2] - 6, flag) end
  draw.text(d.gearText, 150, RX[3], RY[2] - 6, RX[5] - RX[3], RY[4] - RY[2] + 6, flag and BLACK or C.text, F.regular)
end

-- Mode name under the gear (purple box in recharge mode, unless `noBox`), two small cells below it.
local function raceCentre(d, layout, noBox)
  local name = d.puMode and settings.puModeNames[d.puMode] or '-'
  local box = d.recharge and not noBox
  smallCell(RX[3], RX[5], RY[4], RY[5], nil, name, 34, box and C.chargeText or C.text, box and C.charge or nil)
  for i, c in ipairs(layout.centre) do
    smallCell(RX[2 + i], RX[3 + i], RY[5], RY[6], c[1], value(d, c[2], c[3]), 40, cellColor(d, c))
  end
end

-- Tyres (FL FR / RL RR): blocks whose color fades with the temperature (blue cold, green
-- normal, red hot), or white numbers during the lap summary.
local function raceTyres(d, plain)
  for i = 1, 4 do
    local t = d.tyres[i].core
    local x0, x1 = i % 2 == 1 and RX[1] or RX[2], i % 2 == 1 and RX[2] or RX[3]
    local y0, y1 = TYRE_Y[i <= 2 and 1 or 2], TYRE_Y[i <= 2 and 2 or 3]
    local text = string.format('%d', math.floor(t + 0.5))
    if plain then
      smallCell(x0, x1, y0, y1, nil, text, 62, C.text)
    else
      local block = fadeColor(settings.tyreBlocks, t, TYRE_BLOCK[i])
      smallCell(x0, x1, y0, y1, nil, text, 62, C.tyreBlockText, block)
    end
  end
end

-- Bottom right: the car ahead (top line) and behind (bottom line), blue three-letter code and
-- the gap in seconds. During the lap summary (first seconds after the line, 22.16.18) a triangle
-- instead of the gap: up green = gained on that car over the lap, down red = lost, with the amount.
local function gapLines(d, summary)
  local x0, x1 = RX[5] + 20, RX[7] - 14
  local lines = {
    { d.aheadName, d.aheadGap, lapSummary.aheadGain },
    { d.behindName, d.behindGap, lapSummary.behindGain },
  }
  for i, l in ipairs(lines) do
    local y = RY[6] - 10 - (#lines - i + 1) * 64 + 8 -- at the bottom of the block
    if l[1] then
      draw.text(l[1], 34, x0, y, 120, 56, C.infoLabel, F.regular, A.Start)
      if summary and l[3] then
        local up = l[3] >= 0
        local col = up and C.green or C.rpm
        local tx, ty, s = x0 + 120, y + 10, 36
        if up then draw.quad(tx, ty + s, tx + s, ty + s, tx + s / 2, ty, tx + s / 2, ty, col)
        else draw.quad(tx, ty, tx + s, ty, tx + s / 2, ty + s, tx + s / 2, ty + s, col) end
        draw.text(string.format('%.2f', math.abs(l[3])), 40, x0 + 170, y, x1 - x0 - 170, 56, col, F.regular, A.End)
      else
        draw.text(string.format('%.2f', math.min(l[2], 99.99)), 40, x0 + 120, y, x1 - x0 - 120, 56, C.text, F.regular, A.End)
      end
    end
  end
end

-- Side bars. Left: fuel level (from the bottom). Right, two parts: on top the ERS deploy left
-- this lap (4 MJ, solid, drains downwards), below it blocks for the energy harvested this lap
-- (2 MJ, lit from the bottom up).
local SIDE_SPLIT, HARVEST_BLOCKS = 0.55, 6
local function raceSideBars(d)
  local l, r = SIDE_L, SIDE_R
  draw.rect(l.x, l.y, l.w, l.h, C.ersEmpty)
  local fh = l.h * math.saturate(d.fuelLevel)
  draw.rect(l.x, l.y + l.h - fh, l.w, fh, C.sideBar)
  local th = r.h * SIDE_SPLIT
  draw.rect(r.x, r.y, r.w, th, C.ersEmpty)
  local dh = th * math.saturate(d.ersDeployLeft)
  draw.rect(r.x, r.y + th - dh, r.w, dh, C.sideBar)
  local by0, bh = r.y + th + 6, (r.h - th - 6) / HARVEST_BLOCKS
  local lit = math.floor(math.saturate(d.ersRegenLap) * HARVEST_BLOCKS + 0.5)
  for i = 1, HARVEST_BLOCKS do -- i = 1 is the bottom block
    local y0 = by0 + (HARVEST_BLOCKS - i) * bh
    draw.rect(r.x + 2, y0 + 1.5, r.w - 4, bh - 3, i <= lit and C.regenBar or C.ersEmpty)
  end
end

local function race(d)
  local summary = lapSummary.active
  local layout = settings.raceLayout
  raceGrid(C.grid)
  raceSideBars(d)
  raceTop(d)
  cellPairs(layout.left, d, RX[1], RX[2], RX[3], 2)
  cellPairs(layout.right, d, RX[5], RX[6], RX[7], 2)
  raceGear(d)
  raceCentre(d, layout)
  raceTyres(d, summary)
  gapLines(d, summary)
  ersBar(d, RACE_BAR)
end

-- Quali page (22.04.49), in the race page's format: the same grid, side bars and ERS bar.
-- Top row with the RPM in the middle; below it the tyres as colored blocks next to
-- the gear column with the brake temperatures on the outside, like the real one. Recharge: the
-- purple CHR bar over the top right row.
local QUALI_TYRES = { -- tyre block x0, x1, brake x0, x1, row (FL, FR, RL, RR)
  { RX[2], RX[3], RX[1], RX[2], 1 }, { RX[5], RX[6], RX[6], RX[7], 1 },
  { RX[2], RX[3], RX[1], RX[2], 2 }, { RX[5], RX[6], RX[6], RX[7], 2 },
}
local function qualiTyres(d)
  for i = 1, 4 do
    local tyre, q = d.tyres[i], QUALI_TYRES[i]
    local y0, y1 = TYRE_Y[q[5]], TYRE_Y[q[5] + 1]
    local block = fadeColor(settings.tyreBlocks, tyre.core, TYRE_BLOCK[i])
    smallCell(q[1], q[2], y0, y1, nil, string.format('%d', math.floor(tyre.core + 0.5)), 62, C.tyreBlockText, block)
    smallCell(q[3], q[4], y0, y1, 'BRAKE', string.format('%d', math.floor(tyre.disc + 0.5)), 44, C.green)
  end
end

local function quali(d)
  local layout = settings.qualiLayout
  raceGrid(C.grid, true)
  raceSideBars(d)
  raceTop(d, true)
  cellPairs(layout.left, d, RX[1], RX[2], RX[3], 2)
  cellPairs(layout.right, d, RX[5], RX[6], RX[7], 2)
  if d.recharge then smallCell(RX[5], RX[7], RY[2], RY[3], nil, 'CHR', 48, C.chargeText, C.charge) end
  raceGear(d)
  raceCentre(d, layout, true) -- recharge already shows as the CHR bar
  qualiTyres(d)
  ersBar(d, RACE_BAR)
end

local PAGES = { race = race, quali = quali }
local pager = Pages.new(settings.pages)

-- Pit limiter (batch2/22.29.16, 22.29.26). Race page: the layout stays, the gear cell turns
-- yellow (gear in black) and the gap area bottom right turns yellow with the time in the pit
-- lane. Quali page: a white box with the speed in the top middle and a blue strip under it.
local PIT_STRIP_H = 26
local pitSince = nil
local function pitScreen(d, page)
  PAGES[page](d)
  if page == 'race' then
    if d.inPitlane then pitSince = pitSince or d.clock else pitSince = nil end
    draw.rect(RX[3] + 3, RY[2] + 3, RX[5] - RX[3] - 6, RY[4] - RY[2] - 6, C.pitBox)
    draw.text(d.gearText, 150, RX[3], RY[2] - 6, RX[5] - RX[3], RY[4] - RY[2] + 6, BLACK, F.regular)
    draw.rect(RX[5] + 3, RY[4] + 3, RX[7] - RX[5] - 6, RY[6] - RY[4] - 6, C.pitBox)
    draw.text('PIT', 15, RX[5] + 8, RY[4] + 6, 100, 18, BLACK, F.bold, A.Start)
    draw.text(format.lapTime(pitSince and (d.clock - pitSince) * 1000 or 0):sub(1, -3), 56,
      RX[5], RY[4], RX[7] - RX[5], RY[6] - RY[4], BLACK, F.regular)
    return
  end
  local x0, x1, y0, y1 = RX[3], RX[5], RY[1], RY[2]
  draw.rect(x0 + 3, y0 + 3, x1 - x0 - 6, y1 - y0 - 6, C.pitBoxQuali)
  draw.text('PIT', 15, x0 + 8, y0 + 4, 100, 18, BLACK, F.bold, A.Start)
  draw.text(format.int(d.speed), 60, x0, y0 + 8, x1 - x0, y1 - y0 - 8, BLACK, F.regular)
  draw.rect(x0 + 3, y1 + 3, x1 - x0 - 6, PIT_STRIP_H, C.pitStrip)
end

-- Antistall: the page stays; the centre column under the top row becomes one red block with
-- the gear, the RPM and ANTISTALL.
local function antistall(d, page)
  PAGES[page](d)
  local x0, x1, y0, y1 = RX[3], RX[5], RY[2], RY[6]
  local w = x1 - x0
  draw.rect(x0 + 3, y0 + 3, w - 6, y1 - y0 - 6, C.antistall)
  draw.text(d.gearText, 150, x0, y0 - 6, w, 190, C.text, F.regular)
  draw.text(string.format('%d', math.floor(d.rpm + 0.5)), 60, x0, y0 + 190, w, 80, C.text, F.regular)
  local size = math.min(48, 48 * (w - 30) / math.max(draw.textWidth('ANTISTALL', 48, F.regular), 1))
  draw.text('ANTISTALL', size, x0, y0 + 300, w, 110, C.text, F.regular)
end

-- Pop-up: the setting name on the left half, the value in a colored box that fills the right
-- half, like MODE / BMIG / ENT / TRQ on the real wheel. Both centred in their half, as big as
-- fits (settings.popupText).
local PT = settings.popupText
local function fitSize(str, w)
  local tw = draw.textWidth(str, PT.size, F.regular)
  return tw > 0 and math.min(PT.size, PT.size * (w - 2 * PT.margin) / tw) or PT.size
end

local function popup(p)
  local col = POPUP_COLORS[p.key] or POPUP_COLORS.default
  local half = W / 2
  if col.box then draw.rect(half, 0, W - half, draw.H, col.box) end
  draw.text(p.label, fitSize(p.label, half), 0, 0, half, draw.H, C.popupLabel, F.regular)
  draw.text(p.text, fitSize(p.text, W - half), half, 0, W - half, draw.H, col.value, F.regular)
end

-- ---------------------------------------------------------------------------
-- Screen choice
-- ---------------------------------------------------------------------------

local M = { leds = leds.colors, ledModule = leds, data = data }

function M.update(dt)
  data.update(dt)
  leds:update(dt, data)
  popups:update(dt, data)
  lapPopup:update(data)
  lapSummary:update(data)

  local launch = settings.launchScreen.enabled and data.launch and data.gear > 0
  draw.rect(0, 0, W, draw.H, launch and launchColor(data) or C.background)
  if not data.ignition then
    pager:ignitionOff()
    return
  end
  local page = pager:update(data)
  if data.antistall then antistall(data, page)
  elseif popups.active then popup(popups.active)
  elseif launch then PAGES[page](data)
  elseif data.pitLimiter then pitScreen(data, page)
  else PAGES[page](data) end
  ac.debug('page', page)
end

return M
