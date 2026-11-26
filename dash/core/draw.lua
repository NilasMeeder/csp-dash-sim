-- core/draw.lua: small drawing helpers on top of ui.*, in display pixels.
-- Positions are relative to the visible display area set with draw.setArea(),
-- so styles can use (0, 0) for its top-left corner.

local draw = { W = 1024, H = 576 }

local OX, OY = 0, 448
-- Reused vectors: never allocate in the per-frame path.
local p1, p2, p3, p4, sz = vec2(), vec2(), vec2(), vec2(), vec2()

function draw.setArea(area)
  OX, OY, draw.W, draw.H = area.x, area.y, area.w, area.h
end

function draw.rect(x, y, w, h, color, rounding, corners)
  ui.drawRectFilled(p1:set(OX + x, OY + y), p2:set(OX + x + w, OY + y + h), color, rounding or 0, corners)
end

function draw.outline(x, y, w, h, color, thickness, rounding)
  ui.drawRect(p1:set(OX + x, OY + y), p2:set(OX + x + w, OY + y + h), color, rounding or 0, nil, thickness or 2)
end

-- Filled quad through four corners (clockwise).
function draw.quad(x1, y1, x2, y2, x3, y3, x4, y4, color)
  ui.drawQuadFilled(p1:set(OX + x1, OY + y1), p2:set(OX + x2, OY + y2), p3:set(OX + x3, OY + y3), p4:set(OX + x4, OY + y4), color)
end

function draw.line(x1, y1, x2, y2, color, thickness)
  ui.drawLine(p1:set(OX + x1, OY + y1), p2:set(OX + x2, OY + y2), color, thickness or 2)
end

-- Text inside a box with alignment (ui.Alignment.Start/Center/End). `font` is a ui.DWriteFont.
function draw.text(str, size, x, y, w, h, color, font, hAlign, vAlign)
  ui.pushDWriteFont(font)
  ui.setCursor(p1:set(OX + x, OY + y))
  ui.dwriteTextAligned(str, size, hAlign or ui.Alignment.Center, vAlign or ui.Alignment.Center, sz:set(w, h), false, color)
  ui.popDWriteFont()
end

-- Width of a text in pixels.
function draw.textWidth(str, size, font)
  ui.pushDWriteFont(font)
  local w = ui.measureDWriteText(str, size).x
  ui.popDWriteFont()
  return w
end

-- Vertical bar filled from the bottom, `value` from 0 to 1.
function draw.vbar(x, y, w, h, value, color, background)
  if background then draw.rect(x, y, w, h, background) end
  local v = math.saturate(value)
  if v > 0 then draw.rect(x, y + h * (1 - v), w, h * v, color) end
end

function draw.blink(hz, t) return math.floor(t * hz * 2) % 2 == 0 end

return draw
