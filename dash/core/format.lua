-- core/format.lua: numbers to text. Always format explicitly (LuaJIT and the
-- preview print floats differently otherwise).

local format = {}

-- 75213 -> "1:15.213"; 0 or less -> "-:--.---"
function format.lapTime(ms)
  if not ms or ms <= 0 then return '-:--.---' end
  local total = math.floor(ms)
  local minutes = math.floor(total / 60000)
  local seconds = math.floor(total / 1000) % 60
  local millis = total % 1000
  return string.format('%d:%02d.%03d', minutes, seconds, millis)
end

-- -0.234 -> "-0.234", 1.5 -> "+1.500", large values get fewer decimals
function format.delta(s)
  if not s then return '+0.000' end
  if math.abs(s) >= 10 then return string.format('%+.1f', s) end
  return string.format('%+.3f', s)
end

-- 1.234 -> "+1.23" (two decimals, like most F1 wheels)
function format.delta2(s)
  if not s then return '+0.00' end
  if math.abs(s) >= 100 then return string.format('%+.0f', s) end
  return string.format('%+.2f', s)
end

-- 218000 -> "03:38" (minutes:seconds, for session clocks)
function format.clock(ms)
  if not ms or ms <= 0 then return '00:00' end
  local total = math.floor(ms / 1000)
  return string.format('%02d:%02d', math.floor(total / 60), total % 60)
end

function format.int(v) return string.format('%d', math.floor(v + 0.5)) end
function format.fixed(v, decimals) return string.format('%.' .. (decimals or 1) .. 'f', v) end

return format
