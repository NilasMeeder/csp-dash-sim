-- vrc_leds.lua: turns the LED colors VRC's lights.lua sets on the meshes (the shim records
-- them in __preview_meshes) into preview LEDs: 1..15 shift lights, 16..18 info LEDs left,
-- 19..21 info LEDs right.

local can = require('can')

local MESHES = {}
for i = 0, 14 do MESHES[#MESHES + 1] = '_LED_RPM_' .. i end
for i = 0, 2 do MESHES[#MESHES + 1] = '_LED_LOCK_L_' .. i end
for i = 0, 2 do MESHES[#MESHES + 1] = '_LED_LOCK_R_' .. i end

local M = { count = #MESHES, colors = {} }
local peak = {}
for i = 1, #MESHES do M.colors[i] = rgbm(0, 0, 0, 0) peak[i] = 0 end

-- Emissive values are HDR (~25..100); turn them into a color plus 0..1 brightness.
function M.update(from, to)
  local prefix = can.bus.steeringWheelStyle == 8 and 'WI' or 'AM'
  for i = from or 1, to or #MESHES do
    local e = __preview_meshes[prefix .. MESHES[i]]
    local m = e and math.max(e[1], e[2], e[3]) or 0
    -- Track the brightest value at 100% LED brightness, so the pit-menu setting stays visible.
    local full = m * 100 / math.max(1, can.bus.ledBrightness or 100)
    if full > peak[i] then peak[i] = full end
    if m > 0.001 then
      M.colors[i]:set(e[1] / m, e[2] / m, e[3] / m, math.min(1, m / peak[i]))
    else
      M.colors[i].mult = 0
    end
  end
end

return M
