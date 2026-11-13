-- ansi, NDJSON framing, config validation, image adapter selection
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["ansi"] = MiniTest.new_set()

local ansi = require("cellbook.render.ansi")

local function text_of(chunks)
  local s = {}
  for _, c in ipairs(chunks) do
    s[#s + 1] = c[1]
  end
  return table.concat(s)
end

T["ansi"]["strips escapes and keeps text"] = function()
  local chunks = ansi.parse_line("\27[0;31mZeroDivisionError\27[0m: division by zero", {}, "Base")
  eq(text_of(chunks), "ZeroDivisionError: division by zero")
  eq(chunks[1][2]:find("^CellbookAnsi_") ~= nil, true)
  eq(chunks[2][2], "Base")
end

T["ansi"]["16, 256 and truecolor"] = function()
  local st = {}
  ansi.apply_sgr(st, "1;31")
  eq(st.bold, true)
  eq(st.fg ~= nil, true)
  ansi.apply_sgr(st, "38;5;241")
  eq(st.fg, ansi.color256(241))
  ansi.apply_sgr(st, "48;2;10;20;30")
  eq(st.bg, "#0a141e")
  ansi.apply_sgr(st, "0")
  eq(next(st), nil)
  eq(ansi.color256(16), "#000000")
  eq(ansi.color256(231), "#ffffff")
end

T["ansi"]["state carries across lines"] = function()
  local st = {}
  ansi.parse_line("\27[32mgreen", st, nil)
  local chunks = ansi.parse_line("still green\27[39m plain", st, "B")
  eq(chunks[1][2] ~= "B", true)
  eq(chunks[2][2], "B")
end

T["ansi"]["disabled mode strips colors"] = function()
  local chunks = ansi.parse_line("\27[31mred\27[0m", {}, "B", false)
  eq(text_of(chunks), "red")
  eq(chunks[1][2], "B")
end

T["framing"] = MiniTest.new_set()

local framing = require("cellbook.kernel.framing")

T["framing"]["reassembles partial lines"] = function()
  local f = framing.new()
  eq(f:feed('{"a":'), {})
  eq(f:feed('1}\n{"b"'), { '{"a":1}' })
  eq(f:feed(":2}\n\n{}\r\n"), { '{"b":2}', "{}" })
  eq(f:pending(), 0)
end

T["framing"]["large lines"] = function()
  local f = framing.new()
  local big = string.rep("x", 1024 * 1024 * 2)
  local out = {}
  for i = 1, #big, 65536 do
    vim.list_extend(out, f:feed(big:sub(i, i + 65535)))
  end
  vim.list_extend(out, f:feed("\nnext\n"))
  eq(#out, 2)
  eq(#out[1], #big)
  eq(out[2], "next")
end

T["config"] = MiniTest.new_set()

local config = require("cellbook.config")

T["config"]["defaults validate cleanly"] = function()
  local w, err = config.validate(vim.deepcopy(config.defaults))
  eq(err, nil)
  eq(w, {})
end

T["config"]["unknown keys warn with suggestions"] = function()
  local w, err = config.validate({ output = { max_line = 10 } })
  eq(err, nil)
  eq(#w, 1)
  eq(w[1]:find("output.max_lines", 1, true) ~= nil, true)
  local w2 = config.validate({ keymaps = { run_cel = "x" } })
  eq(w2[1]:find("run_cell", 1, true) ~= nil, true)
end

T["config"]["type errors are fatal"] = function()
  local _, err = config.validate({ output = { max_lines = "30" } })
  eq(err ~= nil, true)
  local _, err2 = config.validate({ image = { backend = "kitty" } })
  eq(err2 ~= nil, true)
end

T["config"]["setup merges and lists replace"] = function()
  local old = config.values
  config.setup({ output = { max_lines = 5, mime_priority = { "text/plain" } }, uv = false })
  eq(config.values.output.max_lines, 5)
  eq(config.values.output.mime_priority, { "text/plain" })
  eq(config.values.uv.enabled, false)
  eq(config.values.image.backend, "auto")
  config.values = old
end

T["image"] = MiniTest.new_set()

local image = require("cellbook.render.image")

T["image"]["none backend selects the placeholder"] = function()
  image.reset()
  local a, why = image.select("none")
  eq(a, false)
  eq(type(why), "string")
end

T["image"]["user adapters are tried first in auto"] = function()
  image.reset()
  image.register({
    name = "test-backend",
    available = function()
      return true
    end,
    supports = function(m)
      return m == "image/png"
    end,
    render = function()
      return {}
    end,
    clear = function() end,
  })
  eq(image.select("auto").name, "test-backend")
  eq(image.select("test-backend").name, "test-backend")
  image.user_adapters = {}
  image.reset()
end

T["image"]["cache files are content-addressed"] = function()
  local p1 = image.cache_path("AAAA", "image/png")
  eq(p1:find(vim.fn.sha256("AAAA"), 1, true) ~= nil, true)
  eq(p1:sub(-4), ".png")
  eq(image.cache_path("AAAA", "image/jpeg"):sub(-4), ".jpg")
end

T["image"]["unknown backend reports why"] = function()
  image.reset()
  local a, why = image.select("does-not-exist")
  eq(a, false)
  eq(why:find("unknown") ~= nil, true)
end

T["blocks"] = MiniTest.new_set()

T["blocks"]["merges runs of equal pixels into one chunk"] = function()
  local blocks = require("cellbook.render.blocks")
  local lines = blocks.build({ rows = { { { 0xff0000, 0x0000ff }, { 0xff0000, 0x0000ff }, { 0x00ff00, 0x00ff00 } } } })
  eq(#lines, 1)
  eq(#lines[1], 2)
  eq(lines[1][1][1], "▀▀")
  local hl = vim.api.nvim_get_hl(0, { name = lines[1][1][2] })
  eq(hl.fg ~= nil and hl.bg ~= nil, true)
end

T["blocks"]["sextant patterns map to the right characters"] = function()
  local b = require("cellbook.render.blocks")
  eq(b.sextant_char(0), " ")
  eq(b.sextant_char(63), "█")
  eq(b.sextant_char(21), "▌")
  eq(b.sextant_char(42), "▐")
  eq(b.sextant_char(1), vim.fn.nr2char(0x1FB00))
  eq(b.sextant_char(62), vim.fn.nr2char(0x1FB3B))
  local lines = b.build({ mode = "sextant", rows = { { { 3, 0x000000, 0xffffff }, { 0, 0, 0xffffff } } } })
  eq(lines[1][1][1], vim.fn.nr2char(0x1FB02))
end

T["tables"] = MiniTest.new_set()

T["tables"]["wide tables are split into column blocks repeating the index"] = function()
  local ht = require("cellbook.render.html_table")
  local cells = { "<th></th>" }
  local row = { "<th>0</th>" }
  for i = 1, 8 do
    cells[#cells + 1] = ("<th>column_%d</th>"):format(i)
    row[#row + 1] = ("<td>%d</td>"):format(i * 1000)
  end
  local html = "<table><thead><tr>"
    .. table.concat(cells)
    .. "</tr></thead><tbody><tr>"
    .. table.concat(row)
    .. "</tr></tbody></table>"
  local lines = ht.render(assert(ht.parse(html)), 40, 50)
  local text = {}
  for _, l in ipairs(lines) do
    local s = ""
    for _, ch in ipairs(l) do
      s = s .. ch[1]
    end
    text[#text + 1] = s
    eq(vim.api.nvim_strwidth(s) <= 50 or s:find("column blocks") ~= nil, true)
  end
  local joined = table.concat(text, "\n")
  for i = 1, 8 do
    eq(joined:find("column_" .. i, 1, true) ~= nil, true)
  end
  eq(joined:find("column blocks", 1, true) ~= nil, true)
  -- unlimited width: a single block
  local one = ht.render(assert(ht.parse(html)), 40, nil)
  eq(#one, 5)
end

return T
