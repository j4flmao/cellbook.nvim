local H = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
local ipynb = require("cellbook.format.ipynb")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function sources(nb)
  local s = {}
  for i, c in ipairs(nb.cells) do
    s[i] = c.source
  end
  return s
end

T["round-trip"] = MiniTest.new_set()

T["round-trip"]["every fixture is byte-identical when unmodified (SC-001)"] = function()
  local list = H.fixture_list()
  eq(#list > 20, true)
  for _, path in ipairs(list) do
    local text = H.read(path)
    local nb, err = ipynb.parse(text)
    if not nb then
      error(path .. ": " .. err.message)
    end
    local out = ipynb.serialize(nb, sources(nb))
    if out ~= text then
      error("not byte-identical: " .. path)
    end
  end
end

T["round-trip"]["re-encoding matches Python's json.dumps for canonical fixtures"] = function()
  for _, path in ipairs(H.fixture_list()) do
    if not path:find("noncanonical") then
      local text = H.read(path)
      local nb = assert(ipynb.parse(text))
      nb.meta_dirty = true
      local out = ipynb.serialize(nb, sources(nb))
      if out ~= text then
        error("re-encode differs: " .. path)
      end
    end
  end
end

T["serialize"] = MiniTest.new_set()

T["serialize"]["changed source only changes that cell"] = function()
  local text = H.read(H.fixtures .. "/jupyterlab_basic.ipynb")
  local nb = assert(ipynb.parse(text))
  local src = sources(nb)
  src[2] = "x = 10\ny = 2\nx + y"
  local out = ipynb.serialize(nb, src)
  local a, b = vim.json.decode(text), vim.json.decode(out)
  eq(b.cells[2].source, { "x = 10\n", "y = 2\n", "x + y" })
  eq(b.cells[2].outputs, a.cells[2].outputs)
  eq(b.cells[2].execution_count, a.cells[2].execution_count)
  for i = 1, #a.cells do
    if i ~= 2 then
      eq(b.cells[i], a.cells[i])
    end
  end
  eq(b.metadata, a.metadata)
end

T["serialize"]["string-form source stays a string"] = function()
  local text = H.read(H.fixtures .. "/string_source.ipynb")
  local nb = assert(ipynb.parse(text))
  local src = sources(nb)
  src[2] = "changed"
  local out = vim.json.decode((ipynb.serialize(nb, src)))
  eq(out.cells[2].source, "changed")
end

T["serialize"]["CRLF files keep CRLF when modified"] = function()
  local text = H.read(H.fixtures .. "/crlf_line_endings.ipynb")
  local nb = assert(ipynb.parse(text))
  local src = sources(nb)
  src[4] = "new"
  local out = ipynb.serialize(nb, src)
  eq(out:find("[^\r]\n") == nil, true)
end

T["serialize"]["new code cell gets nbformat fields"] = function()
  local text = H.read(H.fixtures .. "/jupyterlab_basic.ipynb")
  local nb = assert(ipynb.parse(text))
  local Cell = require("cellbook.model.cell")
  table.insert(nb.cells, 2, Cell.new("code", { id = "abcdefgh" }))
  local src = sources(nb)
  src[2] = "x = 42"
  local out = vim.json.decode((ipynb.serialize(nb, src)))
  eq(#out.cells, 5)
  eq(out.cells[2], {
    cell_type = "code",
    execution_count = vim.NIL,
    id = "abcdefgh",
    metadata = {},
    outputs = {},
    source = { "x = 42" },
  })
end

T["serialize"]["strip_outputs removes outputs and counts"] = function()
  local nb = assert(ipynb.parse(H.read(H.fixtures .. "/jupyterlab_basic.ipynb")))
  local out = vim.json.decode((ipynb.serialize(nb, sources(nb), { strip_outputs = true })))
  for _, c in ipairs(out.cells) do
    if c.cell_type == "code" then
      eq(#c.outputs, 0)
      eq(c.execution_count, vim.NIL)
    end
  end
end

T["serialize"]["converting code to markdown drops outputs"] = function()
  local nb = assert(ipynb.parse(H.read(H.fixtures .. "/jupyterlab_basic.ipynb")))
  local Cell = require("cellbook.model.cell")
  nb.cells[2] = Cell.retyped(nb.cells[2], "markdown")
  local out = vim.json.decode((ipynb.serialize(nb, sources(nb))))
  eq(out.cells[2].cell_type, "markdown")
  eq(out.cells[2].outputs, nil)
  eq(out.cells[2].execution_count, nil)
  eq(out.cells[2].id, vim.json.decode(H.read(H.fixtures .. "/jupyterlab_basic.ipynb")).cells[2].id)
end

T["parse"] = MiniTest.new_set()

T["parse"]["nbformat 3 is refused"] = function()
  local nb, err = ipynb.parse(H.read(H.root .. "/tests/fixtures/broken/nbformat3.ipynb"))
  eq(nb, nil)
  eq(err.kind, "unsupported_version")
  eq(err.message:find("nbconvert") ~= nil, true)
end

T["parse"]["invalid JSON reports position"] = function()
  local nb, err = ipynb.parse(H.read(H.root .. "/tests/fixtures/broken/invalid_json.ipynb"))
  eq(nb, nil)
  eq(err.kind, "invalid_json")
  eq(err.message:find("line 1") ~= nil, true)
end

T["parse"]["invalid UTF-8 is refused"] = function()
  local _, err = ipynb.parse(H.read(H.root .. "/tests/fixtures/broken/invalid_utf8.ipynb"))
  eq(err.kind, "invalid_utf8")
end

T["parse"]["language resolution"] = function()
  local nb = assert(ipynb.parse(H.read(H.fixtures .. "/r_kernel.ipynb")))
  eq(nb.language, "r")
  eq(nb.comment, "#")
  local nb2 = assert(ipynb.parse(H.read(H.fixtures .. "/no_kernelspec.ipynb")))
  eq(nb2.language, "python")
end

T["parse"]["old nbformat minor has no ids"] = function()
  local nb = assert(ipynb.parse(H.read(H.fixtures .. "/nbformat_4_2.ipynb")))
  eq(nb.nbformat_minor, 2)
  eq(nb.cells[1].id, nil)
end

return T
