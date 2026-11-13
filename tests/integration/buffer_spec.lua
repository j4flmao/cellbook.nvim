-- attach / save / tracker / ops / keymaps / render (US1, US3, US4)
local H = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
local cb = require("cellbook")
local tracker = require("cellbook.buffer.tracker")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      require("cellbook.config").setup({})
    end,
    post_case = function()
      H.wipe_all()
    end,
  },
})

T["attach"] = MiniTest.new_set()

T["attach"]["opens as percent-format text with the kernel filetype"] = function()
  local path = H.tmp_copy("jupyterlab_basic.ipynb")
  local nb = H.open(path)
  eq(nb ~= nil, true)
  eq(vim.bo.filetype, "python")
  eq(vim.bo.buftype, "acwrite")
  eq(vim.bo.modified, false)
  eq(H.lines(), {
    "# %% [markdown]",
    "# # Basic notebook",
    "#",
    "# Some *markdown* text.",
    "# %%",
    "x = 1",
    "y = 2",
    "x + y",
    "# %%",
    "print('hello')",
    "# %%",
    "",
  })
  eq(cb.cell_count(), 4)
end

T["attach"]["unmodified save is byte-identical for every fixture"] = function()
  for _, src in ipairs(H.fixture_list()) do
    local name = vim.fn.fnamemodify(src, ":t")
    local path = H.tmp_copy(name)
    H.open(path)
    vim.cmd("silent write")
    if H.read(path) ~= H.read(src) then
      error("round-trip through the buffer changed " .. name)
    end
    vim.cmd("bwipeout!")
  end
end

T["attach"]["notebook buffers never use a swap file (no E325 prompt, no bogus recovery)"] = function()
  H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  eq(vim.bo.swapfile, false)
  vim.api.nvim_buf_set_lines(0, 5, 6, false, { "x = 2" })
  eq(vim.fn.swapname("%"), "")
end

T["attach"]["R notebook uses filetype r"] = function()
  H.open(H.tmp_copy("r_kernel.ipynb"))
  eq(vim.bo.filetype, "r")
end

T["attach"]["malformed JSON opens read-only and is never overwritten"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/bad.ipynb"
  local orig = H.read(H.root .. "/tests/fixtures/broken/invalid_json.ipynb")
  H.write(path, orig)
  local nb = H.open(path)
  eq(nb.readonly, true)
  eq(vim.bo.modifiable, false)
  pcall(vim.cmd, "silent write!")
  eq(H.read(path), orig)
end

T["attach"]["nbformat 3 opens read-only"] = function()
  local nb = H.open(H.root .. "/tests/fixtures/broken/nbformat3.ipynb")
  eq(nb.readonly, true)
end

T["attach"]["new file creates an empty notebook"] = function()
  local path = vim.fn.tempname() .. ".ipynb"
  H.open(path)
  eq(cb.cell_count(), 1)
  vim.api.nvim_buf_set_lines(0, 1, 2, false, { "print(1)" })
  vim.cmd("silent write")
  local doc = H.json(path)
  eq(doc.nbformat, 4)
  eq(doc.cells[1].source, { "print(1)" })
end

T["attach"]["writing to a .py target writes plain text"] = function()
  H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  local out = vim.fn.tempname() .. ".py"
  vim.cmd("silent write " .. vim.fn.fnameescape(out))
  eq(vim.split(H.read(out), "\n")[1], "# %% [markdown]")
end

T["save"] = MiniTest.new_set()

T["save"]["editing a cell changes only its source"] = function()
  local path = H.tmp_copy("jupyterlab_basic.ipynb")
  local before = H.json(path)
  H.open(path)
  vim.api.nvim_buf_set_lines(0, 5, 6, false, { "x = 100" })
  eq(vim.bo.modified, true)
  vim.cmd("silent write")
  eq(vim.bo.modified, false)
  local after = H.json(path)
  eq(after.cells[2].source, { "x = 100\n", "y = 2\n", "x + y" })
  eq(after.cells[2].outputs, before.cells[2].outputs)
  eq(after.cells[1], before.cells[1])
  eq(after.cells[3], before.cells[3])
  eq(after.metadata, before.metadata)
end

T["save"]["markdown prefixes are stripped"] = function()
  local path = H.tmp_copy("jupyterlab_basic.ipynb")
  H.open(path)
  vim.api.nvim_buf_set_lines(0, 3, 4, false, { "# Changed **text**", "a line typed without prefix" })
  vim.cmd("silent write")
  eq(H.json(path).cells[1].source, { "# Basic notebook\n", "\n", "Changed **text**\n", "a line typed without prefix" })
end

T["save"]["added cell gets an id (nbformat 4.5) at the right index"] = function()
  local path = H.tmp_copy("jupyterlab_basic.ipynb")
  H.open(path)
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  cb.add_cell(0, { where = "below" })
  vim.api.nvim_buf_set_lines(0, vim.fn.line(".") - 1, vim.fn.line("."), false, { "z = 3" })
  vim.cmd("silent write")
  local doc = H.json(path)
  eq(#doc.cells, 5)
  eq(doc.cells[3].source, { "z = 3" })
  eq(type(doc.cells[3].id), "string")
  eq(doc.cells[3].id:match("^[%w_-]+$") ~= nil, true)
end

T["save"]["cells added to nbformat 4.2 notebooks get no id"] = function()
  local path = H.tmp_copy("nbformat_4_2.ipynb")
  H.open(path)
  cb.add_cell(0, { where = "below" })
  vim.cmd("silent write")
  for _, c in ipairs(H.json(path).cells) do
    eq(c.id, nil)
  end
end

T["save"]["deleting a cell removes it"] = function()
  local path = H.tmp_copy("jupyterlab_basic.ipynb")
  H.open(path)
  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  cb.delete_cell(0)
  vim.cmd("silent write")
  local doc = H.json(path)
  eq(#doc.cells, 3)
  eq(doc.cells[3].source, {})
end

T["save"]["strip_outputs option"] = function()
  require("cellbook.config").setup({ save = { strip_outputs = true } })
  local path = H.tmp_copy("jupyterlab_basic.ipynb")
  H.open(path)
  vim.api.nvim_buf_set_lines(0, 5, 6, false, { "x = 5" })
  vim.cmd("silent write")
  for _, c in ipairs(H.json(path).cells) do
    if c.cell_type == "code" then
      eq(#c.outputs, 0)
      eq(c.execution_count, vim.NIL)
    end
  end
end

T["save"]["writes valid nbformat (nbformat.validate)"] = function()
  if vim.fn.executable("uv") == 0 then
    MiniTest.skip("uv not available")
  end
  local path = H.tmp_copy("raw_and_delimiters.ipynb")
  H.open(path)
  cb.add_cell(0, { where = "below", type = "markdown" })
  cb.add_cell(0, { where = "above", type = "raw" })
  vim.cmd("silent write")
  local res = vim
    .system({
      "uv",
      "run",
      "--quiet",
      "--with",
      "nbformat",
      "python",
      "-c",
      "import nbformat,sys; nbformat.validate(nbformat.read(sys.argv[1], 4)); print('ok')",
      path,
    }, { text = true })
    :wait(120000)
  eq(vim.trim(res.stdout or ""), "ok")
end

T["tracker"] = MiniTest.new_set()

T["tracker"]["typing a delimiter line does not split cells until sync"] = function()
  local path = H.tmp_copy("jupyterlab_basic.ipynb")
  local nb = H.open(path)
  vim.api.nvim_buf_set_lines(0, 6, 6, false, { "# %%" })
  H.refresh(nb)
  eq(#nb.cells, 4)
  vim.cmd("silent write")
  eq(H.json(path).cells[2].source, { "x = 1\n", "# %%\n", "y = 2\n", "x + y" })
  vim.cmd("Cellbook sync")
  eq(#nb.cells, 5)
end

T["tracker"]["deleting a delimiter merges and undo restores the cell with outputs"] = function()
  local nb = H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  H.undo_break()
  vim.api.nvim_win_set_cursor(0, { 9, 0 })
  vim.cmd("normal! dd")
  H.undo_break()
  H.refresh(nb)
  eq(#nb.cells, 3)
  vim.cmd("silent normal! u")
  H.refresh(nb)
  eq(#nb.cells, 4)
  eq(#nb.cells[3].outputs, 1)
end

T["tracker"]["two windows on the same buffer"] = function()
  local nb = H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  vim.cmd("split")
  vim.api.nvim_buf_set_lines(0, 5, 5, false, { "a = 0" })
  H.refresh(nb)
  eq(#nb.cells, 4)
  eq(#vim.api.nvim_list_wins() >= 2, true)
  vim.cmd("only")
end

T["ops"] = MiniTest.new_set()

T["ops"]["dac deletes a cell; undo restores it including outputs"] = function()
  local nb = H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  H.undo_break()
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  vim.cmd("normal dac")
  H.undo_break()
  H.refresh(nb)
  eq(#nb.cells, 3)
  vim.cmd("silent normal! u")
  H.refresh(nb)
  eq(#nb.cells, 4)
  eq(#nb.cells[2].outputs, 1)
  eq(tracker.source_of(nb, nb.ranges[2]), "x = 1\ny = 2\nx + y")
end

T["ops"]["vic selects the cell body"] = function()
  H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  vim.api.nvim_win_set_cursor(0, { 7, 0 })
  vim.cmd("normal yic")
  eq(vim.fn.getreg('"'), "x = 1\ny = 2\nx + y\n")
end

T["ops"]["move, undo and redo keep outputs"] = function()
  local nb = H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  H.undo_break()
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  cb.move_cell(0, 1)
  H.undo_break()
  eq(cb.current_cell().index, 3)
  eq(nb.cells[3].outputs[1].type, "execute_result")
  vim.cmd("silent normal! u")
  H.refresh(nb)
  eq(nb.cells[2].outputs[1].type, "execute_result")
  vim.cmd("silent normal! \18")
  H.refresh(nb)
  eq(tracker.source_of(nb, nb.ranges[3]), "x = 1\ny = 2\nx + y")
  eq(nb.cells[3].outputs[1].type, "execute_result")
end

T["ops"]["split and merge"] = function()
  local path = H.tmp_copy("jupyterlab_basic.ipynb")
  local nb = H.open(path)
  vim.api.nvim_win_set_cursor(0, { 7, 0 })
  cb.split_cell(0)
  eq(#nb.cells, 5)
  eq(tracker.source_of(nb, nb.ranges[2]), "x = 1")
  eq(tracker.source_of(nb, nb.ranges[3]), "y = 2\nx + y")
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  cb.merge_cell(0, "below")
  eq(#nb.cells, 4)
  eq(tracker.source_of(nb, nb.ranges[2]), "x = 1\ny = 2\nx + y")
end

T["ops"]["convert to markdown drops outputs; undo restores them"] = function()
  local path = H.tmp_copy("jupyterlab_basic.ipynb")
  local nb = H.open(path)
  H.undo_break()
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  cb.set_cell_type(0, "markdown")
  H.undo_break()
  eq(nb.cells[2].type, "markdown")
  eq(H.lines()[6], "# x = 1")
  vim.cmd("silent write")
  local doc = H.json(path)
  eq(doc.cells[2].cell_type, "markdown")
  eq(doc.cells[2].outputs, nil)
  vim.cmd("silent normal! u")
  H.refresh(nb)
  eq(nb.cells[2].type, "code")
  eq(#nb.cells[2].outputs, 1)
end

T["keymaps"] = MiniTest.new_set()

T["keymaps"]["]c and [c move between cells"] = function()
  H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  vim.cmd("normal ]c")
  eq(vim.fn.line("."), 10)
  vim.cmd("normal [c")
  eq(vim.fn.line("."), 6)
  vim.cmd("normal 2]c")
  eq(vim.fn.line("."), 12)
end

T["keymaps"]["are buffer-local and can be disabled or remapped"] = function()
  H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  eq(vim.fn.maparg("]c", "n") ~= "", true)
  eq(vim.fn.maparg("<localleader>r", "n") ~= "", true)
  vim.cmd("enew")
  eq(vim.fn.maparg("]c", "n"), "")
  require("cellbook.config").setup({ keymaps = { run_cell = "<leader>jr", run_all = false } })
  H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  eq(vim.fn.maparg("<leader>jr", "n") ~= "", true)
  eq(vim.fn.maparg("<localleader>R", "n"), "")
  require("cellbook.config").setup({ keymaps = false })
  H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  eq(vim.fn.maparg("]c", "n"), "")
end

T["render"] = MiniTest.new_set()

T["render"]["text outputs are virtual lines, never buffer text"] = function()
  local nb = H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  eq(H.view_text(nb.cells[2]), { "3" })
  eq(H.view_text(nb.cells[3]), { "hello" })
  local marks = vim.api.nvim_buf_get_extmarks(0, require("cellbook.render.text").ns, 0, -1, { details = true })
  eq(#marks, 3) -- one output block per code cell (the empty cell only has its spacer)
  eq(marks[1][4].virt_lines ~= nil, true)
  eq(H.lines()[6], "x = 1") -- buffer text untouched
end

T["render"]["code cells are cards, markdown is rendered"] = function()
  local nb = H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  local decor = require("cellbook.buffer.decor")
  -- header of code cell 2 sits on its delimiter mark with the card background
  local m = vim.api.nvim_buf_get_extmark_by_id(0, tracker.ns, nb.cells[2].mark, { details = true })
  eq(m[3].line_hl_group, "CellbookCellBg")
  local text = ""
  for _, ch in ipairs(m[3].virt_text) do
    text = text .. ch[1]
  end
  eq(vim.trim(text), "▶ [1]") -- count from the file; not run in this session yet
  -- markdown heading marks are concealed: "# # Basic notebook" → prefix + "# " hidden
  local md = vim.api.nvim_buf_get_extmarks(0, decor.ns_md, { 1, 0 }, { 1, -1 }, { details = true })
  local conceals = 0
  for _, x in ipairs(md) do
    if x[4].conceal == "" then
      conceals = conceals + 1
    end
  end
  eq(conceals, 2)
  -- inline `code` and **bold** markers are concealed too
  vim.api.nvim_buf_set_lines(0, 3, 4, false, { "# Some **bold** and `code`." })
  H.refresh(nb)
  md = vim.api.nvim_buf_get_extmarks(0, decor.ns_md, { 3, 0 }, { 3, -1 }, { details = true })
  conceals = 0
  for _, x in ipairs(md) do
    if x[4].conceal == "" then
      conceals = conceals + 1
    end
  end
  eq(conceals, 5) -- prefix + 2 bold markers + 2 backticks
end

T["render"]["toolbar shows actions and the kernel"] = function()
  H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  eq(vim.wo.winbar:find("cellbook.toolbar", 1, true) ~= nil, true)
  vim.g.statusline_winid = vim.api.nvim_get_current_win()
  local bar = require("cellbook.toolbar").render()
  eq(bar:find("%3@v:lua.CellbookToolbarClick@", 1, true) ~= nil, true) -- Run All button
  eq(bar:find("CellbookToolbarClick", 1, true) ~= nil, true)
  eq(bar:find("Python 3 (ipykernel)", 1, true) ~= nil, true)
  vim.cmd("enew")
  vim.g.statusline_winid = vim.api.nvim_get_current_win()
  eq(require("cellbook.toolbar").render(), "")
end

T["render"]["long output is truncated with a marker"] = function()
  local nb = H.open(H.tmp_copy("long_stream.ipynb"))
  local lines = H.view_text(nb.cells[1])
  eq(#lines, 31)
  eq(lines[31]:find("1970 more lines") ~= nil, true)
end

T["render"]["image without backend shows a placeholder"] = function()
  require("cellbook.config").setup({ image = { backend = "none" } })
  require("cellbook.render.image").reset()
  local nb = H.open(H.tmp_copy("image_output.ipynb"))
  local lines = H.view_text(nb.cells[1])
  eq(lines[2], "[image/png 64×48 — open with <localleader>o]")
end

T["render"]["DataFrames render as tables; widgets show a placeholder"] = function()
  local nb = H.open(H.tmp_copy("dataframe_html.ipynb"))
  eq(H.view_text(nb.cells[1]), { "┌───┐", "│ a │", "├───┤", "│ 1 │", "└───┘" })
  vim.cmd("bwipeout!")
  require("cellbook.config").setup({ output = { html_tables = false } })
  nb = H.open(H.tmp_copy("dataframe_html.ipynb"))
  eq(H.view_text(nb.cells[1]), { "   a", "0  1" })
  vim.cmd("bwipeout!")
  nb = H.open(H.tmp_copy("widgets.ipynb"))
  eq(H.view_text(nb.cells[1]), { "[widget — not supported]" })
end

T["render"]["tracebacks keep text, drop ANSI codes"] = function()
  local nb = H.open(H.tmp_copy("error_traceback.ipynb"))
  local lines = H.view_text(nb.cells[1])
  eq(lines[#lines], "ZeroDivisionError: division by zero")
end

T["render"]["toggle and clear outputs"] = function()
  local nb = H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  cb.toggle_output(0)
  eq(H.view_text(nb.cells[2]), {})
  cb.toggle_output(0)
  eq(H.view_text(nb.cells[2]), { "3" })
  cb.clear_output(0, { all = true })
  eq(H.view_text(nb.cells[3]), {})
  eq(vim.bo.modified, true)
end

T["render"]["open_output shows the full output in a split"] = function()
  H.open(H.tmp_copy("long_stream.ipynb"))
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  cb.open_output(0)
  eq(vim.bo.filetype, "cellbook_output")
  eq(vim.api.nvim_buf_line_count(0), 2000)
end

T["render"]["pandas-style tables: index column, numbers right-aligned, caption"] = function()
  local ht = require("cellbook.render.html_table")
  local t = ht.parse([[<div><table border="1" class="dataframe">
  <thead><tr style="text-align: right;"><th></th><th>city</th><th>temp</th></tr></thead>
  <tbody><tr><th>0</th><td>Hanoi</td><td>24.5</td></tr><tr><th>1</th><td>Huế &amp; co</td><td>7</td></tr></tbody>
</table><p>2 rows × 2 columns</p></div>]])
  local lines = {}
  for _, l in ipairs(ht.render(t, 40)) do
    local s = ""
    for _, ch in ipairs(l) do
      s = s .. ch[1]
    end
    lines[#lines + 1] = s
  end
  eq(lines, {
    "┌───┬──────────┬──────┐",
    "│   │ city     │ temp │",
    "├───┼──────────┼──────┤",
    "│ 0 │ Hanoi    │ 24.5 │",
    "│ 1 │ Huế & co │    7 │",
    "└───┴──────────┴──────┘",
    "2 rows × 2 columns",
  })
end

T["render"]["sixel adapter reserves space and encodes with ImageMagick"] = function()
  if vim.fn.executable("magick") == 0 then
    MiniTest.skip("ImageMagick not installed")
  end
  local nb = H.open(H.tmp_copy("image_output.ipynb"))
  local sixel = require("cellbook.render.adapters.sixel")
  local file = vim.fn.tempname() .. ".png"
  local data = require("cellbook.model.outputs").get(nb.cells[1].outputs[2], "image/png")
  H.write(file, vim.base64.decode((data:gsub("%s", ""))))
  local p = sixel.render(nb.bufnr, 1, file, { width = 40, height = 10, win = 0 })
  eq(p ~= nil, true)
  eq(p.rows >= 1 and p.rows <= 10, true)
  eq(p.cols >= 1 and p.cols <= 40, true)
  local marks = vim.api.nvim_buf_get_extmarks(0, sixel.ns, 0, -1, { details = true })
  eq(#marks[1][4].virt_lines, p.rows)
  vim.wait(10000, function()
    return p.img ~= nil
  end, 20)
  local img = p.img
  eq(img.width > 0 and img.height > 0, true)
  eq(#img.bands, math.ceil(img.height / 6))
  eq(img.header:find("#0;2;", 1, true) ~= nil, true)
  -- terminal rows 2..3 with 16 px cells = pixels 16..48: variant with 4 px chopped,
  -- bands 3..7 of it start exactly at pixel 16
  eq({ sixel.band_range(2, 3, 16) }, { 4, 3, 7 })
  eq({ sixel.band_range(1, 2, 20) }, { 0, 1, 6 })
  -- a slice is a valid sixel image that ImageMagick can decode, with the right height
  local seq = sixel.slice(img, 1, 3)
  local E = string.char(27)
  eq(seq:sub(1, 2), E .. "P")
  eq(seq:sub(-2), E .. "\\")
  local six = vim.fn.tempname() .. ".six"
  H.write(six, seq)
  local res = vim.system({ "magick", "identify", "-format", "%w %h", "sixel:" .. six }, { text = true }):wait(10000)
  eq(vim.trim(res.stdout or ""), ("%d 18"):format(img.width))
  eq(#sixel.split("x" .. E .. "Pabc" .. E .. "\\y" .. E .. "Pdef" .. E .. "\\"), 2)
  sixel.clear(p)
  eq(#vim.api.nvim_buf_get_extmarks(0, sixel.ns, 0, -1, {}), 0)
end

T["api"] = MiniTest.new_set()

T["api"]["non-notebook buffers return nil + message"] = function()
  vim.cmd("enew")
  local ok, err = cb.run_cell()
  eq(ok, nil)
  eq(err, "not a notebook buffer")
  eq(cb.is_notebook(), false)
  eq(cb.statusline(), "")
end

T["api"]["statusline and current_cell"] = function()
  H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  eq(cb.current_cell().index, 2)
  eq(cb.current_cell().execution_count, 1)
  eq(cb.statusline(), " python3 ○ no kernel  [2/4]")
end

T["api"]["CellbookAttached and CellbookSaved events"] = function()
  local seen = {}
  local id = vim.api.nvim_create_autocmd("User", {
    pattern = { "CellbookAttached", "CellbookSaved" },
    callback = function(ev)
      seen[#seen + 1] = ev.match
    end,
  })
  H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  vim.cmd("silent write")
  vim.wait(200, function()
    return #seen >= 2
  end)
  vim.api.nvim_del_autocmd(id)
  eq(seen, { "CellbookAttached", "CellbookSaved" })
end

T["api"]["command completion"] = function()
  local c = require("cellbook.commands")
  eq(vim.tbl_contains(c.complete("ru", "Cellbook ru"), "run_all"), true)
  eq(c.complete("", "Cellbook move "), { "up", "down" })
end

return T
