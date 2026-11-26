-- core/popups.lua: shows a pop-up when a driver setting changes.
-- Watches values in `data`; styles decide how a pop-up looks.
--
--   local popups = require('dash.core.popups').new(watchList, durationSeconds)
--   popups:update(dt, data)  -> popups.active = { label, text, key } or nil
-- The duration is data.popupTime (VRC's pit menu) when set, else `durationSeconds`.
-- watchList entries: { key = 'brakeBias', label = 'BBAL', fmt = '%.1f' } (key in data);
-- optional `names` = { [value] = 'TEXT' } shows a name instead of the number.

local M = {}
M.__index = M

function M.new(watch, duration)
  return setmetatable({ watch = watch, duration = duration or 1.5, active = nil, last = {}, first = true }, M)
end

function M:update(dt, d)
  for _, w in ipairs(self.watch) do
    local v = d[w.key]
    if v ~= nil then
      if not self.first and self.last[w.key] ~= nil and v ~= self.last[w.key] then
        local text = w.names and w.names[v] or string.format(w.fmt, v)
        self.active = { label = w.label, text = text, key = w.key, untilTime = d.clock + (d.popupTime or self.duration) }
      end
      self.last[w.key] = v
    end
  end
  self.first = false
  if self.active and d.clock > self.active.untilTime then self.active = nil end
end

return M
