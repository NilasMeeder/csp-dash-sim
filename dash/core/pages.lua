-- core/pages.lua: page choice with VRC's page switch. Styles decide what a page looks like.
--
--   local pager = require('dash.core.pages').new({ 'race', 'quali', 'home' })
--   local page = pager:update(data)   -- every frame while the ignition is on
--   pager:ignitionOff()               -- while the ignition is off
--
-- VRC's page switch has 3 positions (can.bus.displayPage 1..3): every change counts as a step
-- forward or back through the list, so the list can be longer than 3.
-- With a 'home' page in the list: ignition on -> home; engine stops -> home; driving off
-- (standing still -> moving) on the home page -> race page. Without one: starts on the first page.

local M = {}
M.__index = M

function M.new(pages)
  return setmetatable({ pages = pages, index = 1 }, M)
end

function M:find(name)
  for i, n in ipairs(self.pages) do if n == name then return i end end
  return nil
end

function M:go(i) self.index = (i - 1) % #self.pages + 1 end

function M:ignitionOff()
  if self.ignition then self.ignition = false end
end

function M:update(d)
  local home, race = self:find('home'), self:find('race') or 1
  if self.ignition == nil then self:go(home and not d.engineRunning and home or race)
  elseif not self.ignition and home then self:go(home) end
  self.ignition = true
  if d.vrcPage and self.vrcPage and d.vrcPage ~= self.vrcPage then
    local step = (d.vrcPage - self.vrcPage) % 3 == 1 and 1 or -1
    self:go(self.index + step)
  end
  self.vrcPage = d.vrcPage
  if home then
    if self.running and not d.engineRunning then self:go(home) end
    -- Only at the moment of driving off, so browsing to the home page while driving stays there.
    local moving = d.engineRunning and d.gear > 0 and d.speed > 5
    if moving and self.moving == false and self.index == home then self:go(race) end
    self.moving = moving
  end
  self.running = d.engineRunning
  return self.pages[self.index]
end

return M
