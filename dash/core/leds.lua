-- core/leds.lua: shift light logic. Pure logic: computes one color per LED, it doesn't
-- touch meshes. The preview draws `leds.colors`; in AC the patched VRC lights.lua copies
-- them onto the LED meshes (see tools/build.js).
--
--   local leds = require('dash.core.leds').new(settings.shiftLights, settings.palette)
--   leds:update(dt, data)
-- See dash/styles/redbull/settings.lua for the config fields.

local M = {}
M.__index = M

local OFF = rgbm(0, 0, 0, 0)

local function blink(hz, t) return hz <= 0 or math.floor(t * hz * 2) % 2 == 0 end

local function perGearValue(v, gear)
  if type(v) == 'table' then return v[math.max(1, math.min(#v, gear))] end
  return v
end

function M.new(cfg, palette)
  local self = setmetatable({ cfg = cfg, colors = {}, enabled = cfg.enabled ~= false, shiftRpm = nil }, M)
  local named = {}
  for name, c in pairs(palette or {}) do named[name] = rgbm(c[1], c[2], c[3], 1) end
  local function color(c)
    if type(c) == 'string' then return named[c] or OFF end
    if type(c) == 'table' then return rgbm(c[1], c[2], c[3], 1) end
    return OFF
  end
  self.base = {}
  for i = 1, cfg.count do
    self.base[i] = color(cfg.colors[i])
    self.colors[i] = OFF
  end
  self.shiftFlashColor = color(cfg.shiftFlash.color)
  self.limiterFlashColor = color(cfg.limiterFlash.color)
  self.drsColor = cfg.drs and color(cfg.drs.color) or OFF
  self.flagColor = cfg.flag and color(cfg.flag.color) or OFF
  -- Static pit pattern: { colorName = { led, ... }, ... } -> led index -> rgbm.
  self.pitStatic = {}
  local static = cfg.pitLimiter and cfg.pitLimiter.static
  if type(static) == 'table' then
    for name, list in pairs(static) do
      for _, i in ipairs(list) do self.pitStatic[i] = color(name) end
    end
  end
  self.rechargeColor = cfg.recharge and color(cfg.recharge.color) or OFF
  self.flagTypes = {}
  for _, name in ipairs(cfg.flag and cfg.flag.flags or {}) do
    if ac.FlagType[name] then self.flagTypes[ac.FlagType[name]] = true end
  end
  return self
end

-- RPM at which RPM LED number `i` (1..#rpmLeds) lights up in `gear`.
function M:stepRpm(i, gear)
  local cfg = self.cfg
  local start = perGearValue(cfg.startRpm, gear)
  local shift = perGearValue(cfg.shiftRpm, gear)
  local n = #cfg.rpmLeds
  local k = n > 1 and (i - 1) / (n - 1) or 1
  return start + (shift - start) * (k ^ (1 / (cfg.curve or 1)))
end

-- Lights LEDs from..to (inclusive) in their base colors.
function M:range(from, to)
  for i = from, to do self.colors[i] = self.base[i] end
end

-- Engine start/stall sequences like VRC's lights.lua (times in seconds, `r` = time left).
-- Start: LEDs 4-8 briefly, then 1-5. Stall: a flash of all LEDs, then the middle block.
function M:engineSequence(t)
  local seq = self.cfg.engineSequences
  local r = self.seqUntil - t
  if self.seqKind == 'start' then
    if r > seq.duration - seq.startFirst then self:range(4, 8) else self:range(1, 5) end
  elseif r > seq.duration - seq.stallFlash then
    self:range(1, self.cfg.count)
  elseif r < seq.duration - seq.stallGap then
    self:range(6, 10)
  end
end

function M:update(dt, d)
  local cfg, c = self.cfg, self.colors
  for i = 1, cfg.count do c[i] = OFF end
  local t = d.clock
  if not d.ignition then
    self.wasRunning = nil
    return
  end

  -- Engine started or stalled: play the sequence first (like VRC).
  local seq = cfg.engineSequences
  if seq and seq.enabled then
    if self.wasRunning ~= nil and d.engineRunning ~= self.wasRunning then
      self.seqKind = d.engineRunning and 'start' or 'stall'
      self.seqUntil = t + seq.duration
    end
    self.wasRunning = d.engineRunning
    if self.seqUntil and t < self.seqUntil then
      self:engineSequence(t)
      return
    end
  end

  -- Antistall, like VRC: odd and even LEDs take turns (base colors), switching every 1/(2*hz) s.
  local anti = cfg.antistall
  if d.antistall and anti and anti.enabled then
    local even = blink(anti.hz, t)
    for i = 1, cfg.count do
      if (i % 2 == 0) == even then c[i] = self.base[i] end
    end
    return
  end

  -- Launch (standing still, clutch in), like VRC: a small window of LEDs walks up with the RPM,
  -- ending on the last LEDs at the launch RPM; it widens near the target.
  local launch = cfg.launch
  if launch and launch.enabled and d.launch then
    local window = d.rpm >= launch.wideFromRpm and launch.wideWindow or launch.window
    for i = 1, cfg.count do
      local top = launch.topRpm - launch.step * (cfg.count + 1 - i)
      if d.rpm >= top - window and d.rpm < top then c[i] = self.base[i] end
    end
    return
  end

  -- Pit limiter takes over the bar: lights fill from both ends towards the middle as the
  -- speed nears the limit (all on at the limit), in the base colors. Over the limit: blink.
  -- With `static` = { green = { 5, 6, 7 }, ... }: those LEDs on in those colors, nothing else.
  local pit = cfg.pitLimiter
  if d.pitLimiter and pit.enabled and pit.static then
    -- Static: a fixed pattern of LEDs, no ramp and no blinking.
    for i, col in pairs(self.pitStatic) do c[i] = col end
    return
  end
  if d.pitLimiter and pit.enabled then
    local n = cfg.count
    local pairs_ = math.ceil(n / 2)
    local over = d.speed > d.pitSpeedLimit + (pit.overKmh or 2)
    local k = math.saturate(1 - (d.pitSpeedLimit - d.speed) / pit.rampKmh)
    local lit = over and pairs_ or math.max(1, math.floor(k * (pairs_ - 1) + 0.5) + 1)
    if not over or blink(pit.overBlinkHz or 6, t) then
      for i = 1, lit do
        c[i] = self.base[i]
        c[n + 1 - i] = self.base[n + 1 - i]
      end
    end
    return
  end

  local gear = math.max(1, d.gear)
  local shift = perGearValue(cfg.shiftRpm, gear)
  self.shiftRpm = shift

  -- DRS on fixed LEDs, like VRC: one for available, one for open.
  local drs = cfg.drs
  if drs then
    if d.drsAvailable and drs.availableLed then c[drs.availableLed] = self.drsColor end
    if d.drsActive and drs.activeLed then c[drs.activeLed] = self.drsColor end
  end

  -- Driver presets like VRC: first LED on with preset 1 or 2, second LED with preset 2.
  local presets = cfg.presets
  if presets then
    if d.preset1 or d.preset2 then c[presets[1]] = self.base[presets[1]] end
    if d.preset2 then c[presets[2]] = self.base[presets[2]] end
  end

  if cfg.blocks then
    -- Block pattern: each block of LEDs comes on as a whole at its own RPM (per gear).
    if d.gear > 0 then
      for _, block in ipairs(cfg.blocks) do
        local rpm = perGearValue(block.rpm, gear)
        self.shiftRpm = rpm
        if d.rpm >= rpm then
          for _, led in ipairs(block.leds) do c[led] = self.base[led] end
        end
      end
    end
  elseif d.limiter and cfg.limiterFlash.enabled then
    if blink(cfg.limiterFlash.hz, t) then
      for _, led in ipairs(cfg.rpmLeds) do c[led] = self.limiterFlashColor end
    end
  elseif d.rpm >= shift and cfg.shiftFlash.enabled then
    if blink(cfg.shiftFlash.hz, t) then
      for _, led in ipairs(cfg.rpmLeds) do c[led] = self.shiftFlashColor end
    end
  elseif d.gear > 0 then
    for i, led in ipairs(cfg.rpmLeds) do
      if d.rpm >= self:stepRpm(i, gear) then c[led] = self.base[led] end
    end
  end

  -- Recharge mode: some LEDs lit on top of the RPM lights (blinking when `hz` is set).
  local recharge = cfg.recharge
  if recharge and d.recharge and (not recharge.hz or blink(recharge.hz, t)) then
    for _, led in ipairs(recharge.leds) do c[led] = self.rechargeColor end
  end

  -- Flag zone: some LEDs blink on top of the RPM lights.
  local flag = cfg.flag
  if flag and self.flagTypes[d.flag] and blink(flag.hz, t) then
    for _, led in ipairs(flag.leds) do c[led] = self.flagColor end
  end
end

return M
