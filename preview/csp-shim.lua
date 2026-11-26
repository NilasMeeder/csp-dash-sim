-- csp-shim.lua: emulated CSP scriptable-display API for the browser preview.
--
-- Runs inside Fengari (Lua 5.3) before the dashboard script. Signatures and default
-- values follow sdk/lib.lua and the CSP sources in sdk/acc-lua-sdk/. Drawing calls
-- are forwarded to JS through __js_draw(op, ...), which buffers them for the canvas.
--
-- Globals provided by bridge.js before this file runs:
--   __js_draw(op, ...)                 buffer a draw command
--   __js_measure(text, size, font)     -> width, height (DWrite text)
--   __js_imageSize(path)               -> width, height (0, 0 while loading)
--   __js_log(kind, text)               console output ('log', 'warn', 'error')
--   __js_debug(key, text)              ac.debug value
--   __js_clock()                       simulated seconds (pauses/slows with the preview)
--   __bundle                           { ['dash/x.lua'] = source, ... }
--   __DISPLAY_W, __DISPLAY_H           display texture resolution

local jsdraw, jslog = __js_draw, __js_log

-- ---------------------------------------------------------------------------------
-- Warnings (each message once)
-- ---------------------------------------------------------------------------------
local warned = {}
local function warnOnce(msg)
  if warned[msg] then return end
  warned[msg] = true
  jslog('warn', msg)
end
__preview_warnOnce = warnOnce

-- ---------------------------------------------------------------------------------
-- LuaJIT compatibility (AC runs LuaJIT 2.1, the preview runs Lua 5.3)
-- ---------------------------------------------------------------------------------
unpack = table.unpack
loadstring = load
table.getn = function(t) return #t end
math.pow = function(x, y) return x ^ y end
math.mod = math.fmod
math.atan2 = function(y, x) return math.atan(y, x) end
math.ldexp = math.ldexp or function(m, e) return m * 2.0 ^ e end

local function toint(x)
  if math.type(x) == 'integer' then return x end
  if x ~= x or x == math.huge or x == -math.huge then return 0 end
  return math.tointeger(x >= 0 and math.floor(x) or math.ceil(x)) or 0
end

-- LuaJIT truncates floats for %d/%x/%c instead of raising an error.
local rawformat = string.format
string.format = function(fmt, ...)
  local args = table.pack(...)
  local i = 0
  for spec in tostring(fmt):gmatch('%%[-+ #0]*%d*%.?%d*([%a%%])') do
    if spec ~= '%' then
      i = i + 1
      if (spec == 'd' or spec == 'i' or spec == 'x' or spec == 'X' or spec == 'c' or spec == 'o')
        and type(args[i]) == 'number' then
        args[i] = toint(args[i])
      end
    end
  end
  return rawformat(fmt, table.unpack(args, 1, args.n))
end

-- Note: Fengari integers are 32 bit, so bit.* works on floats first and converts at the end.
local function tobit(x)
  x = math.floor(x + 0.5) % 4294967296.0
  if x >= 2147483648.0 then x = x - 4294967296.0 end
  return math.tointeger(x)
end
local function shiftAmount(n) return math.tointeger(math.floor(n) % 32) end
bit = {
  tobit = tobit,
  band = function(a, ...) local r = tobit(a) for _, v in ipairs({...}) do r = r & tobit(v) end return r end,
  bor = function(a, ...) local r = tobit(a) for _, v in ipairs({...}) do r = r | tobit(v) end return r end,
  bxor = function(a, ...) local r = tobit(a) for _, v in ipairs({...}) do r = r ~ tobit(v) end return r end,
  bnot = function(a) return ~tobit(a) end,
  lshift = function(a, n) return tobit(tobit(a) * 2.0 ^ shiftAmount(n)) end,
  rshift = function(a, n)
    local u = tobit(a) + 0.0
    if u < 0 then u = u + 4294967296.0 end
    return tobit(math.floor(u / 2.0 ^ shiftAmount(n)))
  end,
  arshift = function(a, n) return tobit(math.floor(tobit(a) / 2.0 ^ shiftAmount(n))) end,
  tohex = function(a, n)
    local u = tobit(a) + 0.0
    if u < 0 then u = u + 4294967296.0 end
    local digits = {}
    for i = 1, 8 do
      local d = math.tointeger(u % 16)
      digits[9 - i] = ('0123456789abcdef'):sub(d + 1, d + 1)
      u = math.floor(u / 16)
    end
    return table.concat(digits):sub(9 - (n or 8))
  end,
}

local function notAvailable(name)
  return function() error(name .. ' is not available in the preview (and does not belong in a dashboard script)', 2) end
end
setfenv = notAvailable('setfenv')
getfenv = notAvailable('getfenv')
ffi = setmetatable({}, { __index = function(_, k) error('ffi.' .. tostring(k) .. ' is not available in the preview', 2) end })
jit = { version = 'LuaJIT 2.1 (preview)', os = 'Windows', arch = 'x64', on = function() end, off = function() end }

-- ---------------------------------------------------------------------------------
-- CSP string/table/math extensions
-- ---------------------------------------------------------------------------------
do
  local mt = getmetatable('')
  mt.__index = function(str, i) return type(i) == 'number' and string.sub(str, i, i) or string[i] end
  mt.__mod = function(str, i)
    return type(i) == 'table' and string.format(str, table.unpack(i)) or string.format(str, i)
  end
end

local function escapePattern(s) return (s:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0')) end

function string.split(self, separator, limit, trimResult, skipEmpty, splitByAnyChar)
  separator = separator or ' '
  if skipEmpty == nil then skipEmpty = true end
  local out, rest = {}, self
  if separator == '' then
    for c in self:gmatch('.') do out[#out + 1] = c end
    return out
  end
  local pattern = splitByAnyChar and ('[' .. escapePattern(separator) .. ']') or escapePattern(separator)
  while true do
    if limit and #out == limit - 1 then break end
    local s, e = rest:find(pattern)
    if not s then break end
    local piece = rest:sub(1, s - 1)
    if trimResult then piece = piece:match('^%s*(.-)%s*$') end
    if not (skipEmpty and piece == '') then out[#out + 1] = piece end
    rest = rest:sub(e + 1)
  end
  if trimResult then rest = rest:match('^%s*(.-)%s*$') end
  if not (skipEmpty and rest == '') then out[#out + 1] = rest end
  return out
end

function string.trim(self, characters, direction)
  local set = characters and ('[' .. escapePattern(characters) .. ']') or '%s'
  direction = direction or 0
  local s = self
  if direction <= 0 then s = s:gsub('^' .. set .. '+', '') end
  if direction >= 0 then s = s:gsub(set .. '+$', '') end
  return s
end

function string.startsWith(self, another, offset)
  offset = offset or 0
  return self:sub(1 + offset, offset + #another) == another
end

function string.endsWith(self, another, offset)
  offset = offset or 0
  local e = #self - offset
  return self:sub(e - #another + 1, e) == another
end

function string.replace(self, replacee, replacer, limit, ignoreCase)
  return (self:gsub(escapePattern(replacee), (replacer or ''):gsub('%%', '%%%%'), limit))
end

function string.numbers(self, limit)
  local out = {}
  for n in self:gmatch('[-+]?%d*%.?%d+') do
    out[#out + 1] = tonumber(n)
    if limit and #out >= limit then break end
  end
  return table.unpack(out)
end

function table.clear(t) for k in pairs(t) do t[k] = nil end end
function table.contains(t, item) for _, v in pairs(t) do if v == item then return true end end return false end
function table.indexOf(t, item) for k, v in pairs(t) do if v == item then return k end end return nil end
function table.nkeys(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
function table.clone(t, deep)
  local r = {}
  for k, v in pairs(t) do r[k] = (deep and type(v) == 'table') and table.clone(v, true) or v end
  return r
end
function table.assign(target, ...)
  for _, src in ipairs({...}) do for k, v in pairs(src) do target[k] = v end end
  return target
end
function table.map(t, callback, callbackData)
  local r = {}
  for k, v in pairs(t) do
    local nv, nk = callback(v, k, callbackData)
    if nk ~= nil then r[nk] = nv else r[#r + 1] = nv end
  end
  return r
end
function table.filter(t, callback, callbackData)
  local r = {}
  for k, v in pairs(t) do if callback(v, k, callbackData) then r[#r + 1] = v end end
  return r
end
function table.forEach(t, callback, callbackData) for k, v in pairs(t) do callback(v, k, callbackData) end return t end
function table.reverse(t) local r = {} for i = #t, 1, -1 do r[#r + 1] = t[i] end return r end
function table.slice(t, from, to, step)
  local r = {}
  for i = from or 1, to or #t, step or 1 do r[#r + 1] = t[i] end
  return r
end
function table.join(t, itemsJoin) local r = {} for _, v in ipairs(t) do r[#r + 1] = tostring(v) end return table.concat(r, itemsJoin or ',') end
function table.isArray(t) return t[1] ~= nil or next(t) == nil end

local function clampN(x, a, b) if x < a then return a elseif x > b then return b end return x end
math.clampN = clampN
math.saturateN = function(x) return clampN(x, 0, 1) end
math.sign = function(x) if x > 0 then return 1 elseif x < 0 then return -1 else return 0 end end
math.lerp = function(x, y, mix) return x * (1 - mix) + y * mix end
math.remap = function(value, oldA, oldB, newA, newB) return (value - oldA) / (oldB - oldA) * (newB - newA) + newA end
math.smoothstep = function(x) return x * x * (3 - 2 * x) end
math.smootherstep = function(x) return x * x * x * (x * (x * 6 - 15) + 10) end
math.isnan = function(x) return not (x >= 0 or x <= 1) end
math.isinf = function(x) return x == math.huge or x == -math.huge end
math.isfinite = function(x) x = tonumber(x) return x ~= nil and not math.isnan(x) and not math.isinf(x) end
math.isNaN = function(x) return x ~= x end
math.nan = 0 / 0
math.NaN = 0 / 0
math.radians = math.rad
math.degress = math.deg
math.round = function(number, decimals)
  if decimals then
    local scale = 10 ^ decimals
    return math.floor(number * scale + 0.5) / scale
  end
  -- LuaJIT returns a float here; keep it a float but integral (tostring gives "5" thanks to FLOATSTRING)
  return math.floor(number + 0.5) + 0.0
end
math.lagMult = function(lag, dt) return 1 - lag ^ (dt * 60) end

-- ---------------------------------------------------------------------------------
-- class() (subset of CSP's class library)
-- ---------------------------------------------------------------------------------
class = setmetatable({ NoInitialize = {}, Pool = {}, Minimal = {} }, {
  __call = function(_, name, ...)
    local parent, ctor
    for _, v in ipairs({...}) do
      if type(v) == 'table' and v ~= class.NoInitialize and v ~= class.Pool and v ~= class.Minimal then parent = v
      elseif type(v) == 'function' then ctor = v end
    end
    local cls = {}
    cls.__index = cls
    cls.__name = name
    if parent then setmetatable(cls, { __index = parent, __call = function(c, ...) return c.allocate(...) end }) end
    function cls.allocate(...)
      local obj = ctor and ctor(...) or {}
      setmetatable(obj, cls)
      if cls.initialize then obj:initialize(...) end
      return obj
    end
    function cls.isInstance(o) return getmetatable(o) == cls end
    if not parent then setmetatable(cls, { __call = function(c, ...) return c.allocate(...) end }) end
    return cls
  end,
})

-- ---------------------------------------------------------------------------------
-- vec2 / vec3 / rgb / rgbm
-- ---------------------------------------------------------------------------------
local function makeVector(name, keys)
  local V = {}
  V.__index = V
  local n = #keys
  local k1, k2, k3, k4 = keys[1], keys[2], keys[3], keys[4]

  local function new(...)
    local args = {...}
    local o = {}
    for i = 1, n do o[keys[i]] = args[i] or 0 end
    return setmetatable(o, V)
  end
  V.__new = new

  local function is(x) return getmetatable(x) == V end
  V['is' .. name] = is

  local function binop(f)
    return function(a, b)
      local o = {}
      if type(a) == 'number' then for i = 1, n do o[keys[i]] = f(a, b[keys[i]]) end
      elseif type(b) == 'number' then for i = 1, n do o[keys[i]] = f(a[keys[i]], b) end
      else for i = 1, n do o[keys[i]] = f(a[keys[i]], b[keys[i]]) end end
      return setmetatable(o, V)
    end
  end
  V.__add = binop(function(a, b) return a + b end)
  V.__sub = binop(function(a, b) return a - b end)
  V.__mul = binop(function(a, b) return a * b end)
  V.__div = binop(function(a, b) return a / b end)
  V.__pow = binop(function(a, b) return a ^ b end)
  V.__unm = function(a) local o = {} for i = 1, n do o[keys[i]] = -a[keys[i]] end return setmetatable(o, V) end
  V.__eq = function(a, b)
    for i = 1, n do if a[keys[i]] ~= b[keys[i]] then return false end end
    return true
  end
  V.__len = function(a) return V.length(a) end
  V.__tostring = function(a)
    local parts = {}
    for i = 1, n do parts[i] = tostring(a[keys[i]]) end
    return '(' .. table.concat(parts, ', ') .. ')'
  end

  function V.new(x, ...)
    if is(x) then return V.clone(x) end
    if type(x) == 'table' then
      local o = {}
      for i = 1, n do o[keys[i]] = tonumber(x[i] or x[keys[i]]) or 0 end
      return setmetatable(o, V)
    end
    local rest = {...}
    if type(x) ~= 'number' then x = 0 end
    if rest[1] == nil then
      local o = {}
      for i = 1, n do o[keys[i]] = x end
      return setmetatable(o, V)
    end
    return new(x, ...)
  end

  local tmpv = new()
  function V.tmp() return tmpv end
  function V.type() return V end
  function V.clone(v) local o = {} for i = 1, n do o[keys[i]] = v[keys[i]] end return setmetatable(o, V) end
  function V.unpack(v) return v[k1], v[k2], k3 and v[k3], k4 and v[k4] end
  function V.table(v) local t = {} for i = 1, n do t[i] = v[keys[i]] end return t end
  function V.set(v, x, ...)
    if is(x) then for i = 1, n do v[keys[i]] = x[keys[i]] end return v end
    local rest = {...}
    if rest[1] == nil then for i = 1, n do v[keys[i]] = x end return v end
    v[k1] = x
    for i = 2, n do v[keys[i]] = rest[i - 1] end
    return v
  end
  function V.copyTo(v, out) for i = 1, n do out[keys[i]] = v[keys[i]] end return out end
  local function inplace(f)
    return function(v, u, out)
      out = out or v
      if type(u) == 'number' then for i = 1, n do out[keys[i]] = f(v[keys[i]], u) end
      else for i = 1, n do out[keys[i]] = f(v[keys[i]], u[keys[i]]) end end
      return out
    end
  end
  V.add = inplace(function(a, b) return a + b end)
  V.sub = inplace(function(a, b) return a - b end)
  V.mul = inplace(function(a, b) return a * b end)
  V.div = inplace(function(a, b) return a / b end)
  V.pow = inplace(function(a, b) return a ^ b end)
  V.min = inplace(math.min)
  V.max = inplace(math.max)
  function V.scale(v, s, out) out = out or v for i = 1, n do out[keys[i]] = v[keys[i]] * s end return out end
  function V.addScaled(v, u, s, out) out = out or v for i = 1, n do out[keys[i]] = v[keys[i]] + u[keys[i]] * s end return out end
  function V.setScaled(v, u, s) for i = 1, n do v[keys[i]] = u[keys[i]] * s end return v end
  function V.setLerp(v, a, b, k) for i = 1, n do v[keys[i]] = a[keys[i]] + (b[keys[i]] - a[keys[i]]) * k end return v end
  function V.lerp(v, u, k, out) out = out or v for i = 1, n do out[keys[i]] = v[keys[i]] + (u[keys[i]] - v[keys[i]]) * k end return out end
  function V.saturate(v, out) out = out or v for i = 1, n do out[keys[i]] = clampN(v[keys[i]], 0, 1) end return out end
  function V.clamp(v, a, b, out)
    out = out or v
    for i = 1, n do
      local lo = type(a) == 'number' and a or a[keys[i]]
      local hi = type(b) == 'number' and b or b[keys[i]]
      out[keys[i]] = clampN(v[keys[i]], lo, hi)
    end
    return out
  end
  function V.lengthSquared(v) local s = 0 for i = 1, n do s = s + v[keys[i]] ^ 2 end return s end
  function V.length(v) return math.sqrt(V.lengthSquared(v)) end
  function V.distanceSquared(v, u) local s = 0 for i = 1, n do s = s + (v[keys[i]] - u[keys[i]]) ^ 2 end return s end
  function V.distance(v, u) return math.sqrt(V.distanceSquared(v, u)) end
  function V.dot(v, u) local s = 0 for i = 1, n do s = s + v[keys[i]] * u[keys[i]] end return s end
  function V.normalize(v, out)
    out = out or v
    local l = V.length(v)
    if l > 0 then for i = 1, n do out[keys[i]] = v[keys[i]] / l end end
    return out
  end

  return setmetatable(V, { __call = function(_, ...) return new(...) end })
end

vec2 = makeVector('vec2', { 'x', 'y' })
vec3 = makeVector('vec3', { 'x', 'y', 'z' })
vec4 = makeVector('vec4', { 'x', 'y', 'z', 'w' })
rgb = makeVector('rgb', { 'r', 'g', 'b' })
rgbm = makeVector('rgbm', { 'r', 'g', 'b', 'mult' })

function vec2.angle(v, u) return math.acos(clampN(vec2.dot(v, u) / (vec2.length(v) * vec2.length(u)), -1, 1)) end
function vec3.cross(v, u, out)
  out = out or vec3()
  local x, y, z = v.y * u.z - v.z * u.y, v.z * u.x - v.x * u.z, v.x * u.y - v.y * u.x
  out.x, out.y, out.z = x, y, z
  return out
end

-- rgbm.new(r, g, b) sets mult to 1 (rgbm(r, g, b) leaves it at 0).
function rgbm.new(r, g, b, m)
  if rgbm.isrgbm(r) then return rgbm.clone(r) end
  if rgb.isrgb(r) then return rgbm(r.r, r.g, r.b, g or 1) end
  if vec3.isvec3(r) then return rgbm(r.x, r.y, r.z, 1) end
  if type(r) == 'table' then return rgbm(tonumber(r[1]) or 0, tonumber(r[2]) or 0, tonumber(r[3]) or 0, tonumber(r[4]) or 0) end
  if type(r) ~= 'number' then return rgbm(0, 0, 0, 1) end
  if type(g) ~= 'number' then return rgbm(r, r, r, 1) end
  if type(b) ~= 'number' then return rgbm(r, r, r, g) end
  return rgbm(r, g, b, m or 1)
end
function rgbm.from0255(r, g, b, a)
  if type(r) ~= 'number' then r = 0 end
  if type(g) ~= 'number' then g = r end
  if type(b) ~= 'number' then b = g end
  return rgbm(r / 255, g / 255, b / 255, a or 1)
end
function rgb.new(r, g, b)
  if type(r) ~= 'number' then r = 0 end
  if type(g) ~= 'number' then return rgb(r, r, r) end
  return rgb(r, g, b)
end
function rgbm.value(c) return (c.r + c.g + c.b) / 3 * c.mult end

rgbm.colors = {
  transparent = rgbm(0, 0, 0, 0), black = rgbm(0, 0, 0, 1), silver = rgbm(0.75, 0.75, 0.75, 1),
  gray = rgbm(0.5, 0.5, 0.5, 1), white = rgbm(1, 1, 1, 1), maroon = rgbm(0.5, 0, 0, 1), red = rgbm(1, 0, 0, 1),
  purple = rgbm(0.5, 0, 0.5, 1), fuchsia = rgbm(1, 0, 1, 1), green = rgbm(0, 0.5, 0, 1), lime = rgbm(0, 1, 0, 1),
  olive = rgbm(0.5, 0.5, 0, 1), yellow = rgbm(1, 1, 0, 1), orange = rgbm(1, 0.5, 0, 1), navy = rgbm(0, 0, 0.5, 1),
  blue = rgbm(0, 0, 1, 1), teal = rgbm(0, 0.5, 0.5, 1), cyan = rgbm(0, 0.5, 1, 1), aqua = rgbm(0, 1, 1, 1),
}
rgb.colors = {}
for k, v in pairs(rgbm.colors) do rgb.colors[k] = rgb(v.r, v.g, v.b) end

-- math.clamp/saturate/applyLag work on numbers and vectors (universal versions).
math.clamp = function(x, a, b)
  if type(x) == 'number' then return clampN(x, a, b) end
  return getmetatable(x).clamp(getmetatable(x).clone(x), a, b)
end
math.saturate = function(x)
  if type(x) == 'number' then return clampN(x, 0, 1) end
  return getmetatable(x).saturate(getmetatable(x).clone(x))
end
math.lerpInvSat = function(value, min, max) return clampN((value - min) / (max - min), 0, 1) end
math.applyLag = function(value, target, lag, dt)
  if lag <= 0 then return target end
  local k = math.lagMult(lag, dt)
  if type(value) == 'number' then return value + (target - value) * k end
  return getmetatable(value).lerp(value, target, k, value)
end
math.dot = function(x, y) return getmetatable(x).dot(x, y) end
math.normalize = function(x) return getmetatable(x).normalize(getmetatable(x).clone(x)) end
math.distance = function(x, y) return getmetatable(x).distance(x, y) end
math.cross = function(x, y) return vec3.cross(x, y) end

-- ---------------------------------------------------------------------------------
-- Unknown-function catcher: warns once, returns nil, never crashes
-- ---------------------------------------------------------------------------------
local function guarded(name, t)
  return setmetatable(t, {
    __index = function(_, k)
      local full = name .. '.' .. tostring(k)
      warnOnce('not emulated: ' .. full)
      return function() return nil end
    end,
  })
end

-- ---------------------------------------------------------------------------------
-- ui.*
-- ---------------------------------------------------------------------------------
ui = {}

ui.Alignment = { Start = -1, Center = 0, End = 1 }
ui.CornerFlags = { None = 0, TopLeft = 1, TopRight = 2, BottomLeft = 4, BottomRight = 8, Top = 3, Bottom = 12, Left = 5, Right = 10, All = 15 }
ui.BlendMode = { Default = 0 }

local W, H = __DISPLAY_W, __DISPLAY_H
local white = rgbm.colors.white
local function col(c) c = c or white return c.r, c.g, c.b, c.mult end
-- Shapes without a color: CSP passes an all-zero rgbm (transparent), not white.
local function shapeCol(c) if c == nil then return 0, 0, 0, 0 end return c.r, c.g, c.b, c.mult end

-- Cursor
local cursor = { x = 0, y = 0 }
function ui.getCursor() return vec2(cursor.x, cursor.y) end
function ui.setCursor(v) if type(v) == 'number' then cursor.x, cursor.y = v, v else cursor.x, cursor.y = v.x, v.y end end
function ui.offsetCursor(v) cursor.x, cursor.y = cursor.x + v.x, cursor.y + v.y end
function ui.getCursorX() return cursor.x end
function ui.getCursorY() return cursor.y end
function ui.setCursorX(v) cursor.x = v end
function ui.setCursorY(v) cursor.y = v end
function ui.offsetCursorX(v) cursor.x = cursor.x + v end
function ui.offsetCursorY(v) cursor.y = cursor.y + v end
function ui.windowSize() return vec2(W, H) end
function ui.windowWidth() return W end
function ui.windowHeight() return H end
function ui.windowPos() return vec2(0, 0) end
function ui.availableSpace() return vec2(W - cursor.x, H - cursor.y) end
function ui.availableSpaceX() return W - cursor.x end
function ui.availableSpaceY() return H - cursor.y end
function ui.sameLine() end
function ui.newLine() end
function ui.dummy(size) cursor.y = cursor.y + size.y end

-- Shapes
function ui.drawRect(p1, p2, color, rounding, roundingFlags, thickness)
  local r, g, b, a = shapeCol(color)
  jsdraw('rect', p1.x, p1.y, p2.x, p2.y, r, g, b, a, rounding or 0, roundingFlags or 15, thickness or 1)
end
function ui.drawRectFilled(p1, p2, color, rounding, roundingFlags)
  local r, g, b, a = shapeCol(color)
  jsdraw('rectF', p1.x, p1.y, p2.x, p2.y, r, g, b, a, rounding or 0, roundingFlags or 15)
end
function ui.drawRectFilledMultiColor(p1, p2, c1, c2, c3, c4)
  jsdraw('rectGrad', p1.x, p1.y, p2.x, p2.y,
    c1.r, c1.g, c1.b, c1.mult, c2.r, c2.g, c2.b, c2.mult, c3.r, c3.g, c3.b, c3.mult, c4.r, c4.g, c4.b, c4.mult)
end
function ui.drawLine(p1, p2, color, thickness)
  local r, g, b, a = shapeCol(color)
  jsdraw('line', p1.x, p1.y, p2.x, p2.y, r, g, b, a, thickness or 1)
end
function ui.drawCircle(p, radius, color, numSegments, thickness)
  local r, g, b, a = shapeCol(color)
  jsdraw('circle', p.x, p.y, radius, radius, r, g, b, a, numSegments or 12, thickness or 1)
end
function ui.drawCircleFilled(p, radius, color, numSegments)
  local r, g, b, a = shapeCol(color)
  jsdraw('circleF', p.x, p.y, radius, radius, r, g, b, a, numSegments or 12)
end
function ui.drawEllipseFilled(p, radius, color, numSegments)
  local r, g, b, a = shapeCol(color)
  jsdraw('circleF', p.x, p.y, radius.x, radius.y, r, g, b, a, numSegments or 12)
end
function ui.drawTriangle(p1, p2, p3, color, thickness)
  local r, g, b, a = shapeCol(color)
  jsdraw('poly', r, g, b, a, thickness or 1, 1, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y)
end
function ui.drawTriangleFilled(p1, p2, p3, color)
  local r, g, b, a = shapeCol(color)
  jsdraw('polyF', r, g, b, a, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y)
end
function ui.drawQuad(p1, p2, p3, p4, color, thickness)
  local r, g, b, a = shapeCol(color)
  jsdraw('poly', r, g, b, a, thickness or 1, 1, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y, p4.x, p4.y)
end
function ui.drawQuadFilled(p1, p2, p3, p4, color)
  local r, g, b, a = shapeCol(color)
  jsdraw('polyF', r, g, b, a, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y, p4.x, p4.y)
end
function ui.drawBezierCurve(p1, p2, p3, p4, color, thickness)
  local r, g, b, a = shapeCol(color)
  jsdraw('bezier', p1.x, p1.y, p2.x, p2.y, p3.x, p3.y, p4.x, p4.y, r, g, b, a, thickness or 1)
end

-- Paths (points are accumulated on the Lua side, then sent as one polyline)
local path = {}
function ui.pathClear() path = {} end
function ui.pathLineTo(p) path[#path + 1] = p.x path[#path + 1] = p.y end
function ui.pathLineToMergeDuplicate(p)
  local n = #path
  if n >= 2 and path[n - 1] == p.x and path[n] == p.y then return end
  ui.pathLineTo(p)
end
function ui.pathArcTo(center, radius, angleFrom, angleTo, numSegments)
  numSegments = numSegments or 10
  for i = 0, numSegments do
    local a = angleFrom + (angleTo - angleFrom) * i / numSegments
    path[#path + 1] = center.x + math.cos(a) * radius
    path[#path + 1] = center.y + math.sin(a) * radius
  end
end
function ui.pathVariableArcTo(center, radiusFrom, radiusTo, angleFrom, angleTo, numSegments)
  numSegments = numSegments or 10
  for i = 0, numSegments do
    local k = i / numSegments
    local a = angleFrom + (angleTo - angleFrom) * k
    local rr = radiusFrom + (radiusTo - radiusFrom) * k
    path[#path + 1] = center.x + math.cos(a) * rr
    path[#path + 1] = center.y + math.sin(a) * rr
  end
end
function ui.pathArcToFast(center, radius, aMin12, aMax12)
  ui.pathArcTo(center, radius, aMin12 * math.pi * 2 / 12, aMax12 * math.pi * 2 / 12, math.max(1, aMax12 - aMin12))
end
function ui.pathStroke(color, closed, thickness)
  local r, g, b, a = shapeCol(color)
  if #path >= 4 then jsdraw('poly', r, g, b, a, thickness or 1, closed and 1 or 0, table.unpack(path)) end
  path = {}
end
function ui.pathFillConvex(color)
  local r, g, b, a = shapeCol(color)
  if #path >= 6 then jsdraw('polyF', r, g, b, a, table.unpack(path)) end
  path = {}
end

-- Clipping and transforms
function ui.pushClipRect(p1, p2, intersectWithExisting)
  jsdraw('clip', p1.x, p1.y, p2.x, p2.y, intersectWithExisting == false and 0 or 1)
end
function ui.pushClipRectFullScreen() jsdraw('clip', 0, 0, W, H, 0) end
function ui.popClipRect() jsdraw('unclip') end
function ui.beginRotation() jsdraw('beginT') end
function ui.endRotation(deg, offset)
  jsdraw('endRot', deg, offset and offset.x or 0, offset and offset.y or 0)
end
function ui.endPivotRotation(deg, pivot, offset)
  jsdraw('endPivotRot', deg, pivot.x, pivot.y, offset and offset.x or 0, offset and offset.y or 0)
end
function ui.beginScale() jsdraw('beginT') end
function ui.endScale(scale)
  if type(scale) == 'number' then jsdraw('endScale', scale, scale)
  else jsdraw('endScale', scale.x, scale.y) end
end

-- Images (paths relative to the script folder, i.e. the repo root in the preview)
local function imgArgs(color, uv1, uv2)
  local r, g, b, a = col(color)
  return r, g, b, a, uv1 and uv1.x or 0, uv1 and uv1.y or 0, uv2 and uv2.x or 1, uv2 and uv2.y or 1
end
function ui.drawImage(filename, p1, p2, color, uv1, uv2, keepAspectRatio)
  if type(color) == 'boolean' then keepAspectRatio, color = color, nil end
  if vec2.isvec2(color) then uv1, uv2, keepAspectRatio, color = color, uv1, uv2, nil end
  local r, g, b, a, u1, v1, u2, v2 = imgArgs(color, uv1, uv2)
  jsdraw('image', tostring(filename), p1.x, p1.y, p2.x, p2.y, r, g, b, a, u1, v1, u2, v2, keepAspectRatio and 1 or 0)
end
function ui.drawImageRounded(filename, p1, p2, color, uv1, uv2, rounding, corners)
  ui.drawImage(filename, p1, p2, color, uv1, uv2)
end
function ui.drawImageQuad(filename, p1, p2, p3, p4, color)
  local r, g, b, a = col(color)
  jsdraw('imageQuad', tostring(filename), p1.x, p1.y, p2.x, p2.y, p3.x, p3.y, p4.x, p4.y, r, g, b, a)
end
function ui.image(filename, size, color, borderColor, uv1, uv2)
  if type(color) == 'boolean' then color = nil end
  ui.drawImage(filename, vec2(cursor.x, cursor.y), vec2(cursor.x + size.x, cursor.y + size.y), color, uv1, uv2)
  cursor.y = cursor.y + size.y
end
function ui.imageSize(filename)
  local w, h = __js_imageSize(tostring(filename))
  return vec2(w, h)
end
function ui.isImageReady(filename) local w = __js_imageSize(tostring(filename)) return w > 0 end
function ui.unloadImage() end

-- DWrite text. The font stack holds CSP font strings ('Name:path;Weight=Bold').
ui.DWriteFont = class('ui.DWriteFont', function(name, dir)
  local fullName = dir and string.format('%s:%s', name, dir) or name
  return { _baseName = fullName }
end, class.NoInitialize)
ui.DWriteFont.Weight = { Thin = 'Thin', UltraLight = 'UltraLight', Light = 'Light', SemiLight = 'SemiLight', Regular = 'Regular', Medium = 'Medium', SemiBold = 'SemiBold', Bold = 'Bold', UltraBold = 'UltraBold', Black = 'Black', UltraBlack = 'UltraBlack' }
ui.DWriteFont.Style = { Normal = 'Normal', Italic = 'Italic', Oblique = 'Oblique' }
ui.DWriteFont.Stretch = { UltraCondensed = 'UltraCondensed', ExtraCondensed = 'ExtraCondensed', Condensed = 'Condensed', SemiCondensed = 'SemiCondensed', Medium = 'Medium', SemiExpanded = 'SemiExpanded', Expanded = 'Expanded', ExtraExpanded = 'ExtraExpanded', UltraExpanded = 'UltraExpanded' }
function ui.DWriteFont:weight(v) self._weight = v return self end
function ui.DWriteFont:style(v) self._style = v return self end
function ui.DWriteFont:stretch(v) self._stretch = v return self end
function ui.DWriteFont:axis() return self end
function ui.DWriteFont:allowRealSizes() return self end
function ui.DWriteFont:allowEmoji() return self end
function ui.DWriteFont:spacing(leading, trailing, minimumAdvanceWidth)
  self._spacing = string.format(';Spacing=%f,%f,%f', leading or 0, trailing or 0, math.max(minimumAdvanceWidth or 0, 0))
  return self
end
function ui.DWriteFont:__tostring()
  local s = self._baseName
  if self._weight then s = s .. ';Weight=' .. self._weight end
  if self._style then s = s .. ';Style=' .. self._style end
  if self._stretch then s = s .. ';Stretch=' .. self._stretch end
  if self._spacing then s = s .. self._spacing end
  return s
end

local fontStack = {}
local function currentFont() return fontStack[#fontStack] or 'Segoe UI' end
function ui.pushDWriteFont(name) fontStack[#fontStack + 1] = tostring(name or 'Segoe UI') end
function ui.popDWriteFont()
  if #fontStack == 0 then warnOnce('ui.popDWriteFont() without a matching pushDWriteFont()') return end
  fontStack[#fontStack] = nil
end
function ui.measureDWriteText(text, fontSize, wrapWidth)
  local w, h = __js_measure(tostring(text), fontSize or 14, currentFont())
  return vec2(w, h)
end
function ui.dwriteDrawText(text, fontSize, pos, color)
  local r, g, b, a = col(color)
  jsdraw('text', tostring(text), fontSize, currentFont(), pos.x, pos.y, r, g, b, a)
end
function ui.dwriteText(text, fontSize, color)
  fontSize = fontSize or 14
  text = tostring(text)
  local r, g, b, a = col(color)
  jsdraw('text', text, fontSize, currentFont(), cursor.x, cursor.y, r, g, b, a)
  local _, h = __js_measure(text, fontSize, currentFont())
  cursor.y = cursor.y + h
end
ui.dwriteTextWrapped = ui.dwriteText
function ui.dwriteTextAligned(text, fontSize, horizontalAligment, verticalAlignment, size, allowWordWrapping, color)
  fontSize = fontSize or 14
  text = tostring(text)
  local avail = ui.availableSpace()
  local bw, bh = size and size.x or 0, size and size.y or 0
  if bw <= 0 then bw = avail.x + bw end
  if bh <= 0 then bh = avail.y + bh end
  local tw, th = __js_measure(text, fontSize, currentFont())
  local ha = horizontalAligment or 0
  local va = verticalAlignment or 0
  local x = cursor.x + (bw - tw) * (ha + 1) / 2
  local y = cursor.y + (bh - th) * (va + 1) / 2
  local r, g, b, a = col(color)
  jsdraw('text', text, fontSize, currentFont(), x, y, r, g, b, a)
  cursor.y = cursor.y + bh
end
function ui.dwriteTextHyperlink(text, fontSize, color) ui.dwriteText(text, fontSize, color) return false end

-- ImGui default-font text and AC bitmap fonts (approximated with a monospace font)
function ui.text(text)
  text = tostring(text)
  jsdraw('text', text, 14, 'Segoe UI', cursor.x, cursor.y, 1, 1, 1, 1)
  cursor.y = cursor.y + 17
end
ui.textWrapped = ui.text
function ui.textColored(text, color)
  local r, g, b, a = col(color)
  jsdraw('text', tostring(text), 14, 'Segoe UI', cursor.x, cursor.y, r, g, b, a)
  cursor.y = cursor.y + 17
end
function ui.measureText(text) local w, h = __js_measure(tostring(text), 14, 'Segoe UI') return vec2(w, h) end
function ui.drawText(text, pos, color)
  local r, g, b, a = col(color)
  jsdraw('text', tostring(text), 14, 'Segoe UI', pos.x, pos.y, r, g, b, a)
end
local acFontStack = {}
function ui.pushACFont(name) acFontStack[#acFontStack + 1] = tostring(name) end
function ui.popACFont() acFontStack[#acFontStack] = nil end
function ui.acText(text, letter, marginOffset, color, lineSpace, monospace)
  local r, g, b, a = col(color)
  jsdraw('acText', tostring(text), acFontStack[#acFontStack] or 'aria', cursor.x, cursor.y, letter.x, letter.y,
    marginOffset or 0, r, g, b, a)
  cursor.y = cursor.y + letter.y + (lineSpace or 0)
end
function ui.calculateACTextSize(text, letter, marginOffset)
  local n = #tostring(text)
  return vec2(n * letter.x + math.max(n - 1, 0) * (marginOffset or 0), letter.y)
end

-- Style helpers that matter little for a display texture
function ui.pushStyleVar() end
function ui.popStyleVar() end
function ui.pushStyleColor() end
function ui.popStyleColor() end
function ui.beginOutline() jsdraw('beginT') end
function ui.endOutline() jsdraw('endNoop') end

guarded('ui', ui)

-- ---------------------------------------------------------------------------------
-- display.* (straight port of sdk/acc-lua-sdk/common/ac_display.lua)
-- ---------------------------------------------------------------------------------
display = {}
function display.rect(params)
  local pos, size = params.pos, params.size
  ui.drawRectFilled(pos, pos + size, params.color or white)
end
function display.image(params)
  local pos = params.pos
  ui.drawImage(params.image, pos, pos + params.size, params.color, params.uvStart, params.uvEnd)
end
function display.text(params)
  local text = tostring(params.text)
  local pos = params.pos
  local letter = params.letter or vec2(20, 40)
  local font = params.font
  local width = params.width or 0
  local alignment = params.alignment or 0
  local spacing = params.spacing or 0
  local textLen = #text
  if textLen == 0 then return end
  local actualWidth = letter.x * textLen + (textLen > 0 and spacing * (textLen - 1) or 0)
  if width > actualWidth and pos then
    pos = vec2(pos.x + (width - actualWidth) * alignment, pos.y)
  end
  if font ~= nil then ui.pushACFont(font) end
  if pos ~= nil then ui.setCursor(pos) end
  ui.acText(text, letter, spacing, params.color)
  if font ~= nil then ui.popACFont() end
end
function display.horizontalBar(params)
  local pos = params.pos
  local size = params.size or vec2(200, 40)
  local delta = params.delta or 8
  local total = params.total or 12
  local active = params.active or 8
  local itemSize = (size.x - delta * (total - 1)) / total
  for i = 1, total do
    ui.drawRectFilled(pos, pos + vec2(itemSize, size.y),
      i <= active and (params.activeColor or white) or (params.inactiveColor or rgbm.colors.transparent))
    pos = pos + vec2(itemSize + delta, 0)
  end
end
guarded('display', display)

-- ---------------------------------------------------------------------------------
-- ac.*
-- ---------------------------------------------------------------------------------
ac = {}

ac.FlagType = { None = 0, Start = 1, Caution = 2, Slippery = 3, PitLaneClosed = 4, Stop = 5, SlowVehicle = 6, Ambulance = 7, ReturnToPits = 8, MechanicalFailure = 9, Unsportsmanlike = 10, StopCancel = 11, FasterCar = 12, Finished = 13, OneLapLeft = 14, SessionSuspended = 15, Code60 = 16 }
ac.SessionType = { Undefined = 0, Practice = 1, Qualify = 2, Race = 3, Hotlap = 4, TimeAttack = 5, Drift = 6, Drag = 7 }

local function fmtValue(v)
  if type(v) == 'number' then
    if math.type(v) == 'integer' or v == math.floor(v) then return tostring(v) end
    return string.format('%.4g', v)
  end
  return tostring(v)
end

function ac.log(...)
  local parts = {}
  for i = 1, select('#', ...) do parts[#parts + 1] = fmtValue((select(i, ...))) end
  jslog('log', table.concat(parts, ' '))
end
ac.warn = function(...) local p = {} for i = 1, select('#', ...) do p[#p + 1] = tostring((select(i, ...))) end jslog('warn', table.concat(p, ' ')) end
ac.error = function(...) local p = {} for i = 1, select('#', ...) do p[#p + 1] = tostring((select(i, ...))) end jslog('error', table.concat(p, ' ')) end
function ac.debug(key, value) __js_debug(tostring(key), fmtValue(value)) end

-- Other cars (preview only): a field of rivals around the own car (sim.carsCount cars). Each
-- rival is the own car's state (metatable fallback) with its own index, position, name and
-- progress; the gaps to the cars right ahead and behind drift slowly over the laps.
local RIVAL_NAMES = {
  -- Made-up names (three-letter codes come from the surname).
  'Marco Velden', 'Lukas Noorman', 'Owen Pike', 'Gabe Rusk', 'Hugo Hale',
  'Kai Andersen', 'Felix Alvaro', 'Leo Stern', 'Pim Garnier', 'Emil Okoro',
  'Adam Bell', 'Carlos Saro', 'Niko Haller', 'Gil Barros', 'Yuto Tanabe',
  'Ian Hadley', 'Liam Lowe', 'Ollie Brand', 'Felipe Cortez',
}
local rivals = {}
local function rivalPosition(i)
  local mine = math.max(1, car.racePosition or 1)
  return i < mine and i or i + 1
end
-- Seconds the car at position p is ahead of the own car (negative = behind).
local function gapToPosition(p)
  local mine = math.max(1, car.racePosition or 1)
  if p == mine then return 0 end
  local prog = (car.lapCount or 0) + (car.splinePosition or 0)
  local ahead = 1.5 + 0.9 * math.sin(prog * 0.9)
  local behind = 0.9 + 0.6 * math.sin(prog * 0.7 + 1)
  if p < mine then return ahead + (mine - 1 - p) * 2.3 end
  return -(behind + (p - mine - 1) * 2.1)
end
function ac.getCar(index)
  if index == 0 or index == nil then return car end
  if index < 0 or index >= (sim.carsCount or 1) then return nil end
  local r = rivals[index]
  if not r then
    r = setmetatable({ index = index }, { __index = function(_, k) return car[k] end })
    rivals[index] = r
  end
  r.racePosition = rivalPosition(index)
  local prog = (car.lapCount or 0) + (car.splinePosition or 0) + gapToPosition(r.racePosition) / 90
  r.lapCount = math.floor(prog)
  r.splinePosition = prog - math.floor(prog)
  return r
end
function ac.getDriverName(index)
  if index == 0 then return 'Sam Player' end
  if index < 0 or index >= (sim.carsCount or 1) then return nil end
  return RIVAL_NAMES[(index - 1) % #RIVAL_NAMES + 1]
end
-- Positive when the comparing car is ahead of the main car (CSP: negative when main is ahead).
function ac.getGapBetweenCars(main, other)
  local function gap(i) return (i == nil or i == 0) and 0 or gapToPosition(rivalPosition(i)) end
  return gap(other) - gap(main)
end
function ac.getSim() return sim end
function ac.getSession(i) return { laps = 0, type = ac.SessionType.Race, isTimedRace = false, durationMinutes = 0 } end
function ac.getUI() return { useImperialUnits = false, isInMainMenu = false, uiScale = 1 } end
function ac.getCarID() return 'vrc_formula_alpha_2025_csp' end
function ac.getCarName() return 'VRC Formula Alpha 2025' end
function ac.getScriptDeltaT() return __preview_dt or 0 end
function ac.getTyresName() return 'Soft' end
function ac.getTyresLongName() return 'Soft (C4)' end
function ac.getPatchVersionCode() return 3500 end
function ac.getLastError() return nil end
function ac.getCarConfig(carIndex, section, key, defaultValue) return defaultValue end
function ac.configValues(layout)
  local out = {}
  for k, v in pairs(layout) do out[k] = v end
  return out
end
function ac.lapTimeToString(time, allowHours)
  time = math.max(0, toint(time))
  local ms = time % 1000
  local s = (time // 1000) % 60
  local m = time // 60000
  if allowHours and m >= 60 then
    return rawformat('%d:%02d:%02d.%03d', m // 60, m % 60, s, ms)
  end
  return rawformat('%d:%02d.%03d', m, s, ms)
end
-- Files: paths are relative to the script folder (data_override/ in AC). Images inside a
-- zip become 'zip:<zip>|<name>' tokens that the preview loads via /api/zip.
local function relPath(p) return (tostring(p):gsub('\\', '/'):gsub('^%./', '')) end
io = io or {}

-- Data LUTs (.lut 'x|y' lines, .2dlut tab table: first row = x, first column = y), linear
-- interpolation with clamping at the ends.
local function lutFile(path)
  local key = relPath(path):gsub('^/', '')
  local src = __bundle_data and __bundle_data[key]
  if not src then warnOnce('LUT not found: ' .. key) end
  return src or ''
end
local function interp(xs, ys, x)
  local n = #xs
  if n == 0 then return 0 end
  if x <= xs[1] then return ys[1] end
  if x >= xs[n] then return ys[n] end
  for i = 2, n do
    if x <= xs[i] then
      local t = (x - xs[i - 1]) / (xs[i] - xs[i - 1])
      return ys[i - 1] + (ys[i] - ys[i - 1]) * t
    end
  end
end
ac.DataLUT11 = {
  load = function(path)
    local xs, ys = {}, {}
    for a, b in lutFile(path):gmatch('([%-%d%.]+)%s*|%s*([%-%d%.]+)') do xs[#xs + 1], ys[#ys + 1] = tonumber(a), tonumber(b) end
    return { get = function(self, x) return interp(xs, ys, x) end }
  end,
}
ac.DataLUT21 = {
  load = function(path)
    local cols, rows, cells = nil, {}, {}
    for line in lutFile(path):gmatch('[^\r\n]+') do
      local nums = {}
      for v in line:gmatch('[%-%d%.]+') do nums[#nums + 1] = tonumber(v) end
      if not cols then cols = nums
      elseif #nums > 0 then rows[#rows + 1] = table.remove(nums, 1) cells[#cells + 1] = nums end
    end
    cols = cols or {}
    return {
      get = function(self, p)
        local x, y = p.x, p.y
        local col = {}
        for r = 1, #rows do col[r] = interp(cols, cells[r], x) end
        return interp(rows, col, y)
      end,
    }
  end,
}
function ac.getPpFilter() return 'default' end

function ac.findFile(p) return relPath(p) end
ac.FolderID = setmetatable({}, { __index = function(_, k) return k end })
function ac.getFolder(id) return '' end
function io.loadFromZip(zip, name) return 'zip:' .. relPath(zip) .. '|' .. tostring(name) end
function ui.decodeImage(data) return data end
function io.dirExists(p) p = relPath(p):gsub('^/', '') .. '/' for k in pairs(__bundle) do if k:sub(1, #p) == p then return true end end return false end
function io.fileExists(p) p = relPath(p):gsub('^/', '') return __bundle[p] ~= nil or (__bundle_data and __bundle_data[p] ~= nil) end
function io.scanDir(dir, mask, cb, data)
  dir = relPath(dir):gsub('^/', '') .. '/'
  local seen, list = {}, {}
  for k in pairs(__bundle) do
    if k:sub(1, #dir) == dir then
      local name = k:sub(#dir + 1):match('^[^/]+')
      if name and not seen[name] then seen[name] = true list[#list + 1] = name end
    end
  end
  table.sort(list)
  for _, name in ipairs(list) do if cb then cb(name, {}, data) end end
  return list
end

-- car.ini values the VRC scripts ask for.
local carIni = { INFO = { SCREEN_NAME = 'VRC Formula Alpha 2025 - CSP - V1.1' } }
local videoIni = { POST_PROCESS = { GLARE = 3 } }
ac.INIConfig = {
  videoConfig = function()
    return { get = function(self, section, key, default) local s = videoIni[section] return s and s[key] or default end }
  end,
  carData = function()
    return { get = function(self, section, key, default) local s = carIni[section] return s and s[key] or default end }
  end,
}

-- Scene: meshes only remember their emissive color, so the preview can show
-- VRC's LEDs (lights.lua sets them with setMaterialProperty('ksEmissive', ...)).
__preview_meshes = {}
local MeshList = {}
MeshList.__index = MeshList
function MeshList:ensureUniqueMaterials() return self end
function MeshList:setMaterialProperty(prop, value)
  if prop == 'ksEmissive' and self.name then
    local e = __preview_meshes[self.name] or { 0, 0, 0 }
    if type(value) == 'number' then e[1], e[2], e[3] = value, value, value
    elseif value then e[1], e[2], e[3] = value.x or value.r or 0, value.y or value.g or 0, value.z or value.b or 0 end
    __preview_meshes[self.name] = e
  end
  return self
end
setmetatable(MeshList, { __index = function(_, k) return function(self) return self end end })
local SceneRef = { findMeshes = function(_, name) return setmetatable({ name = name }, MeshList) end }
SceneRef.findNodes = SceneRef.findMeshes
SceneRef.__index = SceneRef
function ac.findNodes() return setmetatable({}, SceneRef) end

-- Simple persistence stubs (in-memory)
local stored = {}
function ac.store(key, value) stored[key] = value end
function ac.load(key) return stored[key] end
function ac.storage(key, default)
  if type(key) == 'table' then return key end
  local v = default
  return { get = function() return v end, set = function(_, nv) v = nv end }
end

guarded('ac', ac)

os.clock = function() return __js_clock() end
os.preciseClock = os.clock

-- ---------------------------------------------------------------------------------
-- require() from the preloaded bundle (paths relative to the script folder)
-- ---------------------------------------------------------------------------------
package.path = ''
package.cpath = ''
table.insert(package.searchers, 2, function(name)
  local base = name:gsub('%.', '/')
  for _, candidate in ipairs({ base .. '.lua', base .. '/init.lua' }) do
    local src = __bundle[candidate]
    if src then
      local fn, err = load(src, '@' .. candidate)
      if not fn then error(err, 0) end
      return fn, candidate
    end
  end
  return '\n\tnot found in dash/ or preview/emu/: ' .. base .. '.lua'
end)

-- ---------------------------------------------------------------------------------
-- Car and sim state containers. bridge.js fills these every frame from the control
-- panel / simulation; unknown fields warn once so typos are caught early.
-- ---------------------------------------------------------------------------------
-- __preview_known (set by bridge.js) lists every field from sdk/lib.lua per class.
local function stateTable(name, class)
  return setmetatable({}, {
    __index = function(_, k)
      local known = __preview_known and __preview_known[class]
      if known and known[k] then
        warnOnce('field ' .. name .. '.' .. tostring(k) .. ' exists, but is not emulated in the preview (yet)')
      else
        warnOnce('unknown field ' .. name .. '.' .. tostring(k) .. ' (not in sdk/lib.lua)')
      end
      return nil
    end,
  })
end

car = stateTable('car', 'car')
sim = stateTable('sim', 'sim')
rawset(car, 'wheels', {})
for i = 0, 3 do car.wheels[i] = stateTable('car.wheels[' .. i .. ']', 'wheel') end
rawset(car, 'distanceToCamera', 1) -- preview camera sits in the cockpit
rawset(car, 'damage', { [0] = 0, 0, 0, 0, 0 })
rawset(car, 'justJumped', false)
for _, k in ipairs({ 'extraG', 'extraH', 'extraI', 'extraJ' }) do rawset(car, k, false) end -- newer CSP, not in sdk/lib.lua
rawset(car, 'index', 0)

-- ---------------------------------------------------------------------------------
-- Entry point handling: the dashboard may be a module returning { update = fn },
-- or a script defining script.update / a global update (both supported by CSP).
-- ---------------------------------------------------------------------------------
script = {}
local entryModule

function __preview_load(entry)
  local fn, err = load(__bundle[entry], '@' .. entry)
  if not fn then error(err, 0) end
  local name = entry:gsub('%.lua$', ''):gsub('/', '.')
  local result = fn(name)
  package.loaded[name] = result or true
  entryModule = type(result) == 'table' and result or nil
end

function __preview_frame(dt)
  __preview_dt = dt
  path = {}
  cursor.x, cursor.y = 0, 0
  fontStack = {}
  local update = entryModule and entryModule.update or script.update or rawget(_G, 'update')
  if not update then error('No update function found: return { update = function(dt) ... end } or define script.update(dt)', 0) end
  update(dt)
  if #fontStack > 0 then warnOnce('ui.pushDWriteFont() without ui.popDWriteFont() at the end of the frame') end

  -- LED state (shift lights on the wheel), exposed by the dashboard module as .leds
  local leds = entryModule and entryModule.leds
  if type(leds) == 'table' then
    local n = 0
    for i = 1, #leds do
      local c = leds[i]
      n = n + 1
      if c then
        jsdraw('led', i, c.r, c.g, c.b, c.mult)
      else
        jsdraw('led', i, 0, 0, 0, 0)
      end
    end
  end
end
