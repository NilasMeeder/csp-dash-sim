-- Preview stand-in for VRC's data_override/can.lua.
--
-- In AC, VRC's own can.lua fills can.bus from ac.load(carID .. "_CAN") and
-- ac.getCarPhysics(0).scriptControllerInputs, and can.stream from an ac.ReplayStream.
-- In the preview, bridge.js writes the same field names into __preview_can every
-- frame (driven by the control panel / sim.js), so dashboard code can simply do
-- `local can = require("can")` in both places.

local can = {
  key = 'vrc_formula_alpha_2025_csp_CAN',
  bus = __preview_can.bus,
  stream = __preview_can.stream,
  settings = {},
}

-- Per-wheel arrays (0-based, like VRC's ac.StructItem.array), filled from the simulated tyres.
can.stream.tyrePracticalTemperature = setmetatable({}, {
  __index = function(_, i) local w = car.wheels[i] return w and math.floor(w.tyreCoreTemperature + 0.5) or nil end,
})

function can:connect() end
function can.update(dt) end

return can
