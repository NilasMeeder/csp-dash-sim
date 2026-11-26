-- core/lappopup.lua: lap summary after crossing the line. Styles decide how it looks.
--
--   local lapPopup = require('dash.core.lappopup').new(durationSeconds)
--   lapPopup:update(data)  -> lapPopup.active = true while it should be shown, with
--     .number (lap just finished), .timeMs, .isBest, .diff (s vs the previous best, nil on the
--     first timed lap), .fuelUsed (litres this lap, nil when unknown),
--     .ersDeploy / .ersRegen (0..1 of the per-lap limits, deployed / harvested that lap),
--     .aheadGain / .behindGain (seconds gained that lap on the car ahead / behind, negative = lost;
--     nil without such a car)
-- The duration is data.lapPopupTime (VRC's pit menu) when set, else `durationSeconds`;
-- with `fixed` = true always `durationSeconds`.

local M = {}
M.__index = M

function M.new(duration, fixed)
  return setmetatable({ duration = duration or 3, fixed = fixed, active = false, untilTime = 0 }, M)
end

function M:update(d)
  if self.lap and d.lap > self.lap and d.lastLapMs > 0 then
    local best = self.best or 0
    self.number = d.lap - 1
    self.timeMs = d.lastLapMs
    self.isBest = best <= 0 or d.lastLapMs < best
    self.diff = best > 0 and (d.lastLapMs - best) / 1000 or nil
    self.fuelUsed = self.fuelAtStart and self.fuelAtStart - d.fuel or nil
    if self.fuelUsed and self.fuelUsed < 0 then self.fuelUsed = nil end -- refuelled
    self.ersDeploy, self.ersRegen = self.lastDeploy or 0, self.lastRegen or 0 -- last frame of that lap
    self.aheadGain = (self.aheadAtStart and d.aheadGap) and self.aheadAtStart - d.aheadGap or nil
    self.behindGain = (self.behindAtStart and d.behindGap) and d.behindGap - self.behindAtStart or nil
    self.untilTime = d.clock + (not self.fixed and d.lapPopupTime or self.duration)
  end
  self.lastDeploy, self.lastRegen = d.ersDeployLap, d.ersRegenLap
  if not self.lap or d.lap ~= self.lap then
    self.fuelAtStart = d.fuel
    self.aheadAtStart, self.behindAtStart = d.aheadGap, d.behindGap
  end
  self.lap, self.best = d.lap, d.bestLapMs
  self.active = d.clock < self.untilTime
end

return M
