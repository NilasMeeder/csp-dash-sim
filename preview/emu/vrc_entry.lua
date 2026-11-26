-- vrc_entry.lua: runs VRC's original dashboard (display/styles/style_0) in the preview.
-- The VRC files come from the local car download (serve.js), never from this repo.
-- VRC's display.lua itself only does backlight/mesh work, so we call the style directly.
-- The shift lights come from VRC's own lights.lua: it sets the emissive color of the
-- LED meshes, which the shim records in __preview_meshes.

local controller = require('display.styles.style_0.controller')
local lights = require('lights')
local vrcLeds = require('vrc_leds')

return {
  leds = vrcLeds.colors,
  update = function(dt)
    if controller.update then controller:update(dt) end
    lights.update(dt)
    vrcLeds.update()
  end,
}
