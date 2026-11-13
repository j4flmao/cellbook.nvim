local json = require("cellbook.format.json")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function enc(v)
  return json.encode(v)
end

T["encode"] = MiniTest.new_set()

T["encode"]["sorts keys and indents by one space"] = function()
  local v = json.object({ b = 1, a = json.array({ 1, 2 }), c = json.object({}) })
  eq(enc(v), '{\n "a": [\n  1,\n  2\n ],\n "b": 1,\n "c": {}\n}')
end

T["encode"]["empty containers"] = function()
  eq(enc(json.array()), "[]")
  eq(enc(json.object()), "{}")
  eq(enc(json.object({ x = json.array() })), '{\n "x": []\n}')
end

T["encode"]["does not escape unicode (ensure_ascii=False)"] = function()
  eq(enc("tiếng Việt 🎉 ∑"), '"tiếng Việt 🎉 ∑"')
end

T["encode"]["escapes control characters like Python"] = function()
  eq(enc('a"b\\c\n\r\t\b\f'), '"a\\"b\\\\c\\n\\r\\t\\b\\f"')
  eq(enc("\0\1\27\31"), '"\\u0000\\u0001\\u001b\\u001f"')
  eq(enc("\127"), '"\127"')
  eq(enc("/"), '"/"')
end

T["encode"]["null, booleans"] = function()
  eq(enc(vim.NIL), "null")
  eq(enc(true), "true")
  eq(enc(false), "false")
end

T["encode"]["numbers: ints vs Python float repr"] = function()
  eq(enc(1), "1")
  eq(enc(-42), "-42")
  eq(enc(0.5), "0.5")
  eq(enc(1e-05), "1e-05")
  eq(enc(1.5e300), "1.5e+300")
  eq(enc(0.1), "0.1")
  eq(enc(1e16), "1e+16")
  eq(enc(123456.789), "123456.789")
  eq(json.float_repr(1.0), "1.0")
  eq(json.float_repr(100.0), "100.0")
  eq(json.float_repr(0.0001), "0.0001")
end

T["encode"]["compact mode"] = function()
  eq(json.encode(json.object({ b = json.array({ 1 }), a = "x" }), { indent = false }), '{"a":"x","b":[1]}')
end

T["decode"] = MiniTest.new_set()

T["decode"]["keeps object/array distinction when empty"] = function()
  local v = json.decode('{"a": {}, "b": []}')
  eq(json.is_object(v.a), true)
  eq(json.is_array(v.b), true)
  eq(enc(v), '{\n "a": {},\n "b": []\n}')
end

T["decode"]["preserves float literals and big ints"] = function()
  local text = '{\n "big": 12345678901234567890,\n "f": 1.0,\n "i": 3,\n "s": 1e-05\n}'
  local v = json.decode(text)
  eq(v.i, 3)
  eq(json.tonumber(v.f), 1)
  eq(enc(v), text)
end

T["decode"]["null becomes vim.NIL"] = function()
  eq(json.decode("[null]")[1], vim.NIL)
end

T["decode"]["unicode escapes and surrogate pairs"] = function()
  eq(json.decode('"\\u00e9\\ud83c\\udf89"'), "é🎉")
  -- lone surrogate survives a round-trip
  eq(enc(json.decode('"\\udc80"')), '"\\udc80"')
end

T["decode"]["errors report line and column"] = function()
  local v, err = json.pdecode('{\n "a": [1,}\n}')
  eq(v, nil)
  eq(err.line, 2)
  eq(type(err.col), "number")
end

T["decode"]["rejects trailing data"] = function()
  local _, err = json.pdecode("{} x")
  eq(err ~= nil, true)
end

return T
