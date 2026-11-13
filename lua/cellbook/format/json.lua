---Jupyter-compatible JSON decoder/encoder.
---
---The encoder reproduces Python's
---`json.dumps(obj, indent=1, sort_keys=True, ensure_ascii=False)` byte for byte,
---which is what nbformat uses when writing notebooks.
---
---The decoder keeps the information `vim.json.decode` loses:
--- * objects vs arrays (also when empty), via metatables
--- * float literals (`1.0`, `1e-05`) and big integers, via boxed numbers
--- * `null` → `vim.NIL`
---
---This module is pure Lua (no Neovim UI APIs) so it can be unit tested.
local M = {}

local byte, sub, find, char, gsub, format =
  string.byte, string.sub, string.find, string.char, string.gsub, string.format
local concat, sort = table.concat, table.sort
local floor, huge = math.floor, math.huge

local NIL = vim and vim.NIL or setmetatable({}, { __name = "json.null" })
M.null = NIL

M.object_mt = { __name = "cellbook.json.object" }
M.array_mt = { __name = "cellbook.json.array" }
M.number_mt = { __name = "cellbook.json.number" }

---Mark a table as a JSON object.
---@generic T: table
---@param t T?
---@return T
function M.object(t)
  return setmetatable(t or {}, M.object_mt)
end

---Mark a table as a JSON array.
---@generic T: table
---@param t T?
---@return T
function M.array(t)
  return setmetatable(t or {}, M.array_mt)
end

---Boxed number that keeps its literal text (floats, big integers).
---@param lit string
function M.number(lit)
  return setmetatable({ lit = lit, value = tonumber(lit) }, M.number_mt)
end

---@return boolean
function M.is_object(v)
  return type(v) == "table" and getmetatable(v) == M.object_mt
end

---@return boolean
function M.is_array(v)
  return type(v) == "table" and getmetatable(v) == M.array_mt
end

---Unbox a decoded number (boxed or plain); other values pass through.
function M.tonumber(v)
  if type(v) == "table" and getmetatable(v) == M.number_mt then
    return v.value
  end
  return v
end

-- ---------------------------------------------------------------------------
-- Decoder
-- ---------------------------------------------------------------------------

local escapes = {
  [34] = '"',
  [92] = "\\",
  [47] = "/",
  [98] = "\b",
  [102] = "\f",
  [110] = "\n",
  [114] = "\r",
  [116] = "\t",
}

---Encode a code point as UTF-8 (lone surrogates become 3-byte WTF-8 sequences,
---which the encoder turns back into `\udXXX` escapes).
local function utf8_char(cp)
  if cp < 0x80 then
    return char(cp)
  elseif cp < 0x800 then
    return char(0xC0 + floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return char(0xE0 + floor(cp / 0x1000), 0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  else
    return char(
      0xF0 + floor(cp / 0x40000),
      0x80 + floor(cp / 0x1000) % 0x40,
      0x80 + floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40
    )
  end
end
M._utf8_char = utf8_char

---@class cellbook.json.DecodeError
---@field message string
---@field line integer
---@field col integer
---@field pos integer

---Decode a JSON document.
---@param str string
---@return any value
function M.decode(str)
  local pos = 1
  local len = #str

  local function fail(msg)
    local line, last_nl = 1, 0
    local i = 1
    while true do
      local nl = find(str, "\n", i, true)
      if not nl or nl >= pos then
        break
      end
      line = line + 1
      last_nl = nl
      i = nl + 1
    end
    error({ message = msg, line = line, col = pos - last_nl, pos = pos }, 0)
  end

  local function skip_ws()
    pos = find(str, "[^ \t\r\n]", pos) or len + 1
  end

  local parse_value

  local function parse_string()
    local start = pos + 1
    local s = find(str, '["\\]', start)
    if not s then
      fail("unterminated string")
    end
    if byte(str, s) == 34 then
      pos = s + 1
      return sub(str, start, s - 1)
    end
    local parts, n = {}, 0
    local i = start
    while true do
      s = find(str, '["\\]', i)
      if not s then
        pos = i
        fail("unterminated string")
      end
      if s > i then
        n = n + 1
        parts[n] = sub(str, i, s - 1)
      end
      if byte(str, s) == 34 then
        pos = s + 1
        return concat(parts)
      end
      local c = byte(str, s + 1)
      if c == 117 then -- \uXXXX
        local hex = sub(str, s + 2, s + 5)
        local cp = #hex == 4 and hex:match("^%x%x%x%x$") and tonumber(hex, 16)
        if not cp then
          pos = s
          fail("invalid \\u escape")
        end
        i = s + 6
        if cp >= 0xD800 and cp <= 0xDBFF and sub(str, i, i + 1) == "\\u" then
          local lo_hex = sub(str, i + 2, i + 5)
          local lo = lo_hex:match("^%x%x%x%x$") and tonumber(lo_hex, 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            i = i + 6
          end
        end
        n = n + 1
        parts[n] = utf8_char(cp)
      else
        local e = escapes[c]
        if not e then
          pos = s
          fail("invalid escape")
        end
        n = n + 1
        parts[n] = e
        i = s + 2
      end
    end
  end

  local function parse_number()
    local s, e = find(str, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not s then
      fail("invalid number")
    end
    local lit = sub(str, s, e)
    local value = tonumber(lit)
    if not value then
      fail("invalid number")
    end
    pos = e + 1
    if find(lit, "[.eE]") or value >= 9007199254740992 or value <= -9007199254740992 then
      return setmetatable({ lit = lit, value = value }, M.number_mt)
    end
    return value
  end

  local function parse_array()
    pos = pos + 1
    local arr = setmetatable({}, M.array_mt)
    skip_ws()
    if byte(str, pos) == 93 then
      pos = pos + 1
      return arr
    end
    local n = 0
    while true do
      n = n + 1
      arr[n] = parse_value()
      skip_ws()
      local c = byte(str, pos)
      if c == 44 then
        pos = pos + 1
      elseif c == 93 then
        pos = pos + 1
        return arr
      else
        fail("expected ',' or ']'")
      end
    end
  end

  local function parse_object()
    pos = pos + 1
    local obj = setmetatable({}, M.object_mt)
    skip_ws()
    if byte(str, pos) == 125 then
      pos = pos + 1
      return obj
    end
    while true do
      skip_ws()
      if byte(str, pos) ~= 34 then
        fail("expected string key")
      end
      local key = parse_string()
      skip_ws()
      if byte(str, pos) ~= 58 then
        fail("expected ':'")
      end
      pos = pos + 1
      obj[key] = parse_value()
      skip_ws()
      local c = byte(str, pos)
      if c == 44 then
        pos = pos + 1
      elseif c == 125 then
        pos = pos + 1
        return obj
      else
        fail("expected ',' or '}'")
      end
    end
  end

  local literals = {
    { "true", true },
    { "false", false },
    { "null", NIL },
  }
  local specials = { "NaN", "Infinity", "-Infinity" }

  parse_value = function()
    skip_ws()
    local c = byte(str, pos)
    if c == 34 then
      return parse_string()
    elseif c == 123 then
      return parse_object()
    elseif c == 91 then
      return parse_array()
    elseif c == 45 or (c and c >= 48 and c <= 57) then
      for _, lit in ipairs(specials) do
        if sub(str, pos, pos + #lit - 1) == lit then
          pos = pos + #lit
          return setmetatable(
            { lit = lit, value = lit == "NaN" and 0 / 0 or (lit == "Infinity" and huge or -huge) },
            M.number_mt
          )
        end
      end
      return parse_number()
    elseif c == nil then
      fail("unexpected end of input")
    end
    for _, l in ipairs(literals) do
      if sub(str, pos, pos + #l[1] - 1) == l[1] then
        pos = pos + #l[1]
        return l[2]
      end
    end
    for _, lit in ipairs(specials) do
      if sub(str, pos, pos + #lit - 1) == lit then
        pos = pos + #lit
        return setmetatable({ lit = lit, value = lit == "NaN" and 0 / 0 or huge }, M.number_mt)
      end
    end
    fail("unexpected character")
  end

  local value = parse_value()
  skip_ws()
  if pos <= len then
    fail("trailing data after JSON value")
  end
  return value
end

---Protected decode.
---@param str string
---@return any value, cellbook.json.DecodeError? err
function M.pdecode(str)
  local ok, res = pcall(M.decode, str)
  if ok then
    return res, nil
  end
  if type(res) == "table" then
    return nil, res
  end
  return nil, { message = tostring(res), line = 0, col = 0, pos = 0 }
end

-- ---------------------------------------------------------------------------
-- Encoder
-- ---------------------------------------------------------------------------

local escape_map = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function escape_char(c)
  local e = escape_map[c]
  if e then
    return e
  end
  local b = byte(c)
  if b == 127 then
    return c -- Python does not escape DEL
  end
  return format("\\u%04x", b)
end

local function escape_surrogate(b2, b3)
  local cp = 0xD000 + (byte(b2) - 0x80) * 0x40 + (byte(b3) - 0x80)
  return format("\\u%04x", cp)
end

---@param s string
---@return string
local function encode_string(s)
  if not find(s, '[%c"\\\237]') then
    return '"' .. s .. '"'
  end
  s = gsub(s, '[%c"\\]', escape_char)
  if find(s, "\237[\160-\191]") then
    s = gsub(s, "\237([\160-\191])([\128-\191])", escape_surrogate)
  end
  return '"' .. s .. '"'
end
M.encode_string = encode_string

---Python `repr(float)` for a Lua number.
---@param n number
---@return string
local function float_repr(n)
  if n ~= n then
    return "NaN"
  elseif n == huge then
    return "Infinity"
  elseif n == -huge then
    return "-Infinity"
  elseif n == 0 then
    return (1 / n < 0) and "-0.0" or "0.0"
  end
  local s
  for p = 1, 17 do
    s = format("%." .. (p - 1) .. "e", n)
    if tonumber(s) == n then
      break
    end
  end
  local sign, int, frac, exp = s:match("^(-?)(%d)%.?(%d*)e([-+]%d+)$")
  local digits = (int .. frac):gsub("0+$", "")
  if digits == "" then
    digits = "0"
  end
  local e = tonumber(exp)
  local out
  if e >= -4 and e < 16 then
    if e >= 0 then
      if #digits <= e + 1 then
        out = digits .. string.rep("0", e + 1 - #digits) .. ".0"
      else
        out = digits:sub(1, e + 1) .. "." .. digits:sub(e + 2)
      end
    else
      out = "0." .. string.rep("0", -e - 1) .. digits
    end
  else
    local mant = digits:sub(1, 1)
    if #digits > 1 then
      mant = mant .. "." .. digits:sub(2)
    end
    local esign = e < 0 and "-" or "+"
    out = mant .. "e" .. esign .. format("%02d", math.abs(e))
  end
  return sign .. out
end
M.float_repr = float_repr

local function encode_number(n)
  if n == floor(n) and n > -9007199254740992 and n < 9007199254740992 then
    return format("%d", n)
  end
  return float_repr(n)
end

local indent_cache = setmetatable({}, {
  __index = function(t, k)
    local v = string.rep(" ", k)
    rawset(t, k, v)
    return v
  end,
})

---@param t table
---@return boolean
local function table_is_array(t)
  local mt = getmetatable(t)
  if mt == M.array_mt then
    return true
  elseif mt == M.object_mt then
    return false
  end
  if next(t) == nil then
    return false
  end
  return t[1] ~= nil
end

---@class cellbook.json.EncodeOpts
---@field indent integer? default 1 (nil/false → compact `separators=(",", ":")`)
---@field newline string? default "\n"

---Encode a value with Jupyter formatting (no trailing newline).
---@param value any
---@param opts cellbook.json.EncodeOpts?
---@return string
function M.encode(value, opts)
  opts = opts or {}
  local step = opts.indent
  if step == nil then
    step = 1
  end
  local nl = opts.newline or "\n"
  local buf, n = {}, 0

  local function emit(s)
    n = n + 1
    buf[n] = s
  end

  local function enc(v, depth)
    local tv = type(v)
    if tv == "string" then
      emit(encode_string(v))
    elseif tv == "number" then
      emit(encode_number(v))
    elseif tv == "boolean" then
      emit(v and "true" or "false")
    elseif v == nil or v == NIL then
      emit("null")
    elseif tv == "table" then
      local mt = getmetatable(v)
      if mt == M.number_mt then
        emit(v.lit)
        return
      end
      if table_is_array(v) then
        local count = #v
        if count == 0 then
          emit("[]")
          return
        end
        if step then
          local inner = nl .. indent_cache[(depth + 1) * step]
          emit("[")
          for i = 1, count do
            emit(i == 1 and inner or ("," .. inner))
            enc(v[i], depth + 1)
          end
          emit(nl .. indent_cache[depth * step] .. "]")
        else
          emit("[")
          for i = 1, count do
            if i > 1 then
              emit(",")
            end
            enc(v[i], depth + 1)
          end
          emit("]")
        end
      else
        local keys, k = {}, 0
        for key in pairs(v) do
          if type(key) ~= "string" then
            error("cellbook.json: object keys must be strings, got " .. type(key))
          end
          k = k + 1
          keys[k] = key
        end
        if k == 0 then
          emit("{}")
          return
        end
        sort(keys)
        if step then
          local inner = nl .. indent_cache[(depth + 1) * step]
          emit("{")
          for i = 1, k do
            local key = keys[i]
            emit(i == 1 and inner or ("," .. inner))
            emit(encode_string(key))
            emit(": ")
            enc(v[key], depth + 1)
          end
          emit(nl .. indent_cache[depth * step] .. "}")
        else
          emit("{")
          for i = 1, k do
            local key = keys[i]
            if i > 1 then
              emit(",")
            end
            emit(encode_string(key))
            emit(":")
            enc(v[key], depth + 1)
          end
          emit("}")
        end
      end
    else
      error("cellbook.json: cannot encode value of type " .. tv)
    end
  end

  enc(value, 0)
  return concat(buf)
end

---Deep copy preserving JSON metatables.
function M.deepcopy(v)
  if type(v) ~= "table" then
    return v
  end
  local mt = getmetatable(v)
  if mt == M.number_mt then
    return v -- immutable
  end
  local out = {}
  for k, val in pairs(v) do
    out[k] = M.deepcopy(val)
  end
  return setmetatable(out, mt)
end

return M
