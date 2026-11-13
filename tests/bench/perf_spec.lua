-- Performance budgets (Constitution IV / SC-003). Run: ./scripts/test.sh bench
-- Generate the benchmark notebook first: uv run scripts/make_fixtures.py --bench
local H = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = { post_case = H.wipe_all } })

local function ms(f)
  local t = vim.uv.hrtime()
  f()
  return (vim.uv.hrtime() - t) / 1e6
end

T["plugin/ sourcing costs < 1 ms"] = function()
  vim.g.loaded_cellbook = nil
  local t = ms(function()
    vim.cmd("runtime plugin/cellbook.lua")
  end)
  MiniTest.add_note(("plugin/cellbook.lua: %.3f ms"):format(t))
  eq(t < 1, true)
end

T["open 5 MB / 300-cell notebook < 200 ms"] = function()
  local src = H.root .. "/tests/fixtures/bench/bench_300_cells.ipynb"
  if not vim.uv.fs_stat(src) then
    MiniTest.skip("run `uv run scripts/make_fixtures.py --bench` first")
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/bench.ipynb"
  H.write(path, H.read(src))
  require("cellbook.buffer.attach") -- exclude first-require cost
  -- exclude Neovim's one-time python ftplugin/syntax loading (not plugin cost)
  vim.cmd("enew")
  vim.bo.filetype = "python"
  vim.cmd("enew")
  local t = ms(function()
    H.open(path)
  end)
  MiniTest.add_note(("open %.1f MB: %.1f ms"):format(vim.uv.fs_stat(path).size / 1e6, t))
  -- budget: 200 ms per 5 MB (the generated notebook is ~7 MB)
  eq(t < 200 * math.max(1, vim.uv.fs_stat(path).size / 5e6), true)
end

T["typing stays O(changed cells)"] = function()
  local src = H.root .. "/tests/fixtures/bench/bench_300_cells.ipynb"
  if not vim.uv.fs_stat(src) then
    MiniTest.skip("bench notebook missing")
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/bench.ipynb"
  H.write(path, H.read(src))
  local nb = H.open(path)
  local worst = 0
  for i = 1, 50 do
    local t = ms(function()
      vim.api.nvim_buf_set_lines(0, 100 + i, 100 + i, false, { "x = " .. i })
      require("cellbook.buffer.tracker").refresh(nb)
    end)
    worst = math.max(worst, t)
  end
  MiniTest.add_note(("worst edit+refresh: %.2f ms"):format(worst))
  eq(worst < 16, true)
end

T["save a modified 5 MB notebook"] = function()
  local src = H.root .. "/tests/fixtures/bench/bench_300_cells.ipynb"
  if not vim.uv.fs_stat(src) then
    MiniTest.skip("bench notebook missing")
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/bench.ipynb"
  H.write(path, H.read(src))
  H.open(path)
  vim.api.nvim_buf_set_lines(0, 3, 3, false, { "y = 1" })
  local t = ms(function()
    vim.cmd("silent write")
  end)
  MiniTest.add_note(("save: %.1f ms"):format(t))
  eq(t < 1000, true)
end

return T
