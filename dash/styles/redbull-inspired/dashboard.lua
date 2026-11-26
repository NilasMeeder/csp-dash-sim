-- dashboard.lua (Red Bull-inspired): steering wheel display inspired by the Red Bull F1 wheel
-- (built from onboard footage; unofficial).
-- Kept simple on purpose, like the real one.
--
-- Module: { update = fn(dt), leds = 15 rgbm (preview), ledModule = shift light state (AC) }.
-- Pages (settings.pages, browsed with the wheel's page switch, also with the engine off):
-- 'race' (tyre/brake temperatures, settings, flags), 'quali' (push lap: energy, predicted lap),
-- 'home' (ignition on: clock, RPM, car and track data) and 'setup' (all wheel settings). Ignition off = black screen.
-- A lap pop-up shows the lap time after crossing the line.
-- Side bars, top row and gear are always there; a pop-up or ANTISTALL replaces the rest.

local settings = require('dash.styles.redbull-inspired.settings')
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

local function color(c) return rgbm(c[1], c[2], c[3], 1) end
local C = {}
for name, c in pairs(settings.colors) do C[name] = color(c) end
local POPUP_COLORS = {}
for key, p in pairs(settings.popupColors) do
  POPUP_COLORS[key] = { box = p.box and color(p.box), label = color(p.label), value = color(p.value) }
end
local FLAGS = {}
for name, text in pairs(settings.flags) do
  if ac.FlagType[name] then FLAGS[ac.FlagType[name]] = text end
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
  { key = 'ersMode', label = 'STRT', fmt = '%d' },
  { key = 'puMode', label = 'MODE', fmt = '%d' },
  { key = 'engineBrake', label = 'EB', fmt = '%d' },
  { key = 'diffEntry', label = 'ENTRY', fmt = '%d' },
  { key = 'diffMid', label = 'MID', fmt = '%d' },
  { key = 'diffExit', label = 'EXIT', fmt = '%d' },
}, settings.popupDuration)

-- Layout (pixels in the visible area, 1024 x 576)
local L = {
  barW = 52,                        -- side bars: full height, against the screen edges
  x0 = 68, x1 = W - 68,             -- content between the side bars
  topY = 20, topH = 150,
}

-- ---------------------------------------------------------------------------
-- Parts
-- ---------------------------------------------------------------------------

-- Left: battery charge (purple), right: fuel level (green), both from top to bottom against the
-- screen edges. The percentage and the liters sit next to the bars at the bottom.
local function sideBars(d)
  draw.vbar(0, 0, L.barW, draw.H, d.ersCharge, C.ersBar, C.barBackground)
  draw.vbar(W - L.barW, 0, L.barW, draw.H, d.fuelLevel, C.fuelBar, C.barBackground)
  local y = draw.H - 44
  draw.text(string.format('%d%%', d.ersPercent), 32, L.barW + 10, y, 140, 40, C.text, F.regular, A.Start)
  draw.text(string.format('%dL', math.floor(d.fuel + 0.5)), 32, W - L.barW - 150, y, 140, 40, C.text, F.regular, A.End)
end

local function gear(d)
  draw.text(d.gearText, 250, 362, -10, 300, 260, C.gear, F.regular)
end

local function rpmThousands(d) return string.format('%.1f', d.rpm / 1000) end

-- Top row: speed on the left; delta on the right, or the RPM (thousands) with the pit limiter
-- or antistall on, or during a launch (standing still, clutch in).
local function speedAndDelta(d)
  draw.text(format.int(d.speed), 120, L.x0, L.topY, 270, L.topH, C.text, F.regular, A.End)
  local right = (d.pitLimiter or d.antistall or d.launch) and rpmThousands(d) or format.delta2(d.delta)
  draw.text(right, 110, 640, L.topY, L.x1 - 640, L.topH, C.text, F.regular, A.End)
end

-- Core temperature of each tyre in its corner (FL top left, FR top right, RL/RR at the bottom),
-- with the brake disc temperature smaller on the inside.
local TYRE_SPOTS = { { 196, false }, { 196, true }, { 450, false }, { 450, true } } -- y, right side
local function tyreTemps(d)
  local cfg = settings.tyres
  for i = 1, 4 do
    local t = d.tyres[i]
    local col = t.core < cfg.cold and C.tyreCold or t.core > cfg.hot and C.tyreHot or C.text
    local y, right = TYRE_SPOTS[i][1], TYRE_SPOTS[i][2]
    local tyre = string.format('%d', math.floor(t.core + 0.5))
    local brake = string.format('%d', math.floor(t.disc + 0.5))
    local tw = draw.textWidth(tyre, 64, F.regular)
    local bx = right and L.x1 - tw - 12 - 90 or L.x0 + tw + 12
    draw.text(tyre, 64, right and L.x1 - 200 or L.x0, y, 200, 76, col, F.regular, right and A.End or A.Start)
    draw.text(brake, 30, bx, y + 26, 90, 44, C.dim, F.regular, right and A.End or A.Start)
  end
end

local function pitLimiter(d)
  if d.pitLimiter then draw.text('PIT LIMITER', 40, L.x0, 304, L.x1 - L.x0, 50, C.pit, F.regular) end
end

-- Small red box under the gear while the PU is in recharge mode (MODE 1).
local function recharge(d)
  if not d.recharge then return end
  local w = draw.textWidth('RECHARGE', 28, F.bold) + 30
  local x = math.floor((W - w) / 2)
  draw.outline(x, 258, w, 44, C.pit, 3)
  draw.text('RECHARGE', 28, x, 258, w, 44, C.pit, F.bold)
end

-- Flag in plain white text in the middle (only the flags listed in settings.flags).
local function flag(d)
  local text = FLAGS[d.flag]
  if text then draw.text(text, 40, L.x0, 354, L.x1 - L.x0, 50, C.text, F.bold) end
end

-- Antistall takes over everything below the top row, like a pop-up.
local function antistall()
  draw.text('ANTISTALL', 125, L.x0, 300, L.x1 - L.x0, 160, C.pit, F.regular)
end

-- Text for a { label, key, format } cell: format 'lap' = lap time, else string.format.
local function cellText(cell, v)
  if v == nil then return '-' end
  return cell[3] == 'lap' and format.lapTime(v) or string.format(cell[3], v)
end

-- Small settings at the bottom, centered between the lower tyre temperatures: rows of cells
-- (the last row at the bottom), a small label above the value.
local INFO_CELL, INFO_ROW, INFO_BOTTOM = 110, 78, 462
local function infoRows(list, d)
  for r, row in ipairs(list) do
    local y = INFO_BOTTOM - (#list - r) * INFO_ROW
    local x = math.floor((W - #row * INFO_CELL) / 2)
    for i, cell in ipairs(row) do
      local v = d[cell[2]]
      draw.text(cell[1], 18, x, y, INFO_CELL, 22, C.dim, F.bold)
      draw.text(cellText(cell, v), 34, x, y + 22, INFO_CELL, 44, C.text, F.regular)
      x = x + INFO_CELL
    end
  end
end

-- Settings in a column between the tyre temperatures on each side: small label above the
-- value (an empty label draws none), left column aligned left, right column aligned right.
-- A row can hold several cells next to each other (listed left to right).
local SIDE_GAP = 40
local function sideCell(cell, x, y, d, align)
  local v = d[cell[2]]
  if cell[1] ~= '' then draw.text(cell[1], 20, x, y, 200, 24, C.dim, F.bold, align) end
  local text = cellText(cell, v)
  draw.text(text, 44, align == A.End and x - 100 or x, y + 22, 300, 56, C.text, F.regular, align) -- room for a lap time
  return math.max(draw.textWidth(text, 44, F.regular), draw.textWidth(cell[1], 20, F.bold))
end

local function sideInfo(side, d)
  for _, col in ipairs({ { side.left, false }, { side.right, true } }) do
    local y = 290
    for _, row in ipairs(col[1] or {}) do
      local cells = type(row[1]) == 'table' and row or { row }
      if col[2] then
        local x = L.x1 - 4
        for i = #cells, 1, -1 do x = x - sideCell(cells[i], x - 200, y, d, A.End) - SIDE_GAP end
      else
        local x = L.x0 + 4
        for i = 1, #cells do x = x + sideCell(cells[i], x, y, d, A.Start) + SIDE_GAP end
      end
      y = y + 84
    end
  end
end

-- Pop-up under the gear, after the real wheel (screenshots/rb/per_bah_21, 18.05.00 / 18.04.18):
-- the setting name in plain text on the left, its value far right. A `box` color puts a box
-- behind the name. Only the side bars, top row and gear stay on screen meanwhile.
local function popup(p)
  local col = POPUP_COLORS[p.key] or POPUP_COLORS.default
  local y, h, x0, x1 = 280, 200, L.x0 + 16, L.x1 - 16
  if col.box then
    draw.rect(x0 - 16, y + 30, draw.textWidth(p.label, 120, F.regular) + 32, h - 60, col.box)
  end
  draw.text(p.label, 120, x0, y, 480, h, col.label, F.regular, A.Start)
  draw.text(p.text, 170, x1 - 400, y, 400, h, col.value, F.regular, A.End)
end

-- Lap pop-up after crossing the line: lap number left, lap time right (purple = new best),
-- the difference to the previous best underneath (green faster, red slower).
local lapPopup = LapPopup.new(settings.lapPopupDuration)
local function lapPopupView()
  local x0, x1 = L.x0 + 16, L.x1 - 16
  draw.text(string.format('LAP %d', lapPopup.number), 80, x0, 290, 400, 130, C.text, F.regular, A.Start)
  draw.text(format.lapTime(lapPopup.timeMs), 120, x1 - 560, 280, 560, 150, lapPopup.isBest and C.ersBar or C.text, F.regular, A.End)
  if lapPopup.diff then
    draw.text(format.delta(lapPopup.diff), 56, x1 - 400, 430, 400, 80, lapPopup.diff < 0 and C.ok or C.tyreHot, F.regular, A.End)
  end
end

-- Home screen (ignition on), after the real wheel's start screen (screenshots/rb/per_bah_21,
-- 18.02.36): clock and RPM on top, BBW | K start, a line, and a grid of car/track data.
local function homeTop(d)
  draw.text(format.clock(d.sessionTimeLeftMs), 96, L.x0, L.topY, 330, L.topH, C.text, F.regular, A.Start)
  draw.text(rpmThousands(d), 96, 640, L.topY, L.x1 - 640, L.topH, C.text, F.regular, A.End)
end

-- Grid of { label, key, format } cells, two per row (left | right): label left, value right.
local function grid(list, y0, d, divider)
  local cx = W / 2
  if divider then draw.line(cx, y0 + 6, cx, y0 + math.ceil(#list / 2) * 60, C.line, 2) end
  for i, cell in ipairs(list) do
    local x = i % 2 == 1 and 140 or cx + 30
    local y = y0 + math.floor((i - 1) / 2) * 60
    draw.text(cell[1], 30, x, y, 160, 60, C.dim, F.regular, A.Start)
    draw.text(cellText(cell, d[cell[2]]), 42, x + 130, y, cx - 170 - 130, 60, C.text, F.regular, A.End)
  end
end

local function home(d)
  local cx = W / 2
  draw.text(d.engineRunning and 'BBW On' or 'BBW Off', 40, L.x0, 250, cx - L.x0, 54, C.text, F.regular)
  local ready = d.ersCharge >= 0.95
  draw.text(ready and 'K Start Ready' or 'K Start Wait', 40, cx, 250, L.x1 - cx, 54, ready and C.text or C.fail, F.regular)
  draw.line(140, 330, W - 140, 330, C.line, 2)
  grid(settings.homeGrid, 372, d, true)
end

-- Setup: every wheel setting in one plain grid (EB and the diff aren't on the race page).
local function setup(d)
  grid(settings.setupGrid, 290, d, false)
end

local function race(d)
  tyreTemps(d)
  pitLimiter(d)
  recharge(d)
  flag(d)
  sideInfo(settings.raceSide, d)
  infoRows(settings.raceInfo, d)
end

-- Quali: the race layout tuned for a push lap: tyre/brake temperatures in the corners and
-- the energy numbers that matter on a flying lap between them; nothing at the bottom.
local function quali(d)
  tyreTemps(d)
  pitLimiter(d)
  recharge(d)
  flag(d)
  sideInfo(settings.qualiSide, d)
end

local PAGES = { race = race, quali = quali, home = home, setup = setup }

-- Page choice with the wheel's page switch (see dash/core/pages.lua).
local pager = Pages.new(settings.pages)

local M = { leds = leds.colors, ledModule = leds, data = data }

function M.update(dt)
  data.update(dt)
  leds:update(dt, data)
  popups:update(dt, data)
  lapPopup:update(data)

  draw.rect(0, 0, W, draw.H, C.background)
  if not data.ignition then
    pager:ignitionOff()
    return
  end
  local page = pager:update(data)
  sideBars(data)
  if page == 'home' then homeTop(data) else speedAndDelta(data) end
  gear(data)
  if data.antistall then antistall()
  elseif popups.active then popup(popups.active)
  elseif lapPopup.active then lapPopupView()
  else PAGES[page](data) end
  ac.debug('page', page)
end

return M
