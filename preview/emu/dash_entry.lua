-- dash_entry.lua: runs one of our dashboards the way it runs in AC (see tools/build.js):
-- the dashboard draws the screen and owns the 15 shift lights, while VRC's lights.lua
-- keeps driving the info LEDs left and right. serve.js generates a tiny entry per dashboard
-- that calls this with the dashboard's module name.

local lights = require('lights')
local vrcLeds = require('vrc_leds')

return function(moduleName)
  local dash = require(moduleName)
  local leds = {}
  for i = 1, vrcLeds.count do leds[i] = vrcLeds.colors[i] end
  return {
    leds = leds,
    update = function(dt)
      lights.update(dt)
      vrcLeds.update(16, vrcLeds.count)
      dash.update(dt)
      for i = 1, 15 do leds[i] = dash.leds[i] end
    end,
  }
end
