---cellbook.nvim — Jupyter notebooks in Neovim.
---Public Lua API (`:h cellbook-api`). Everything here follows semantic versioning;
---modules under `cellbook.*` are internal.
local M = {}

local NOT_NOTEBOOK = "not a notebook buffer"

---@param bufnr integer?
---@param edit boolean? requires a writable notebook
---@return cellbook.Notebook? nb
---@return string? err
local function nb_of(bufnr, edit)
  local Notebook = require("cellbook.model.notebook")
  local nb = Notebook.get(bufnr or 0)
  if not nb then
    return nil, NOT_NOTEBOOK
  end
  if (edit or edit == nil) and nb.readonly then
    return nil, "notebook is read-only"
  end
  return nb, nil
end

---Optional. Merge user options with defaults and validate.
---@param opts cellbook.Config?
function M.setup(opts)
  local config = require("cellbook.config")
  config.setup(opts)
  require("cellbook.render.image").reset()
  for _, nb in ipairs(require("cellbook.model.notebook").all()) do
    if not nb.readonly then
      require("cellbook.keymaps").apply(nb)
    end
  end
end

---@param bufnr integer?
---@return boolean
function M.is_notebook(bufnr)
  return require("cellbook.model.notebook").get(bufnr or 0) ~= nil
end

-- Execution ----------------------------------------------------------------

---Queue a list of layout ranges for execution.
---@param nb cellbook.Notebook
---@param ranges {cell: cellbook.Cell, start: integer, stop: integer}[]
---@param opts {stop_on_error: boolean?}?
---@return boolean
local function run_ranges(nb, ranges, opts)
  local tracker = require("cellbook.buffer.tracker")
  local items = {}
  for _, r in ipairs(ranges) do
    if r.cell.type == "code" then
      local code = tracker.source_of(nb, r)
      if code:find("%S") then
        items[#items + 1] = { cell = r.cell, code = code }
      elseif #r.cell.outputs > 0 or r.cell.execution_count ~= vim.NIL then
        r.cell.outputs = {}
        r.cell.execution_count = vim.NIL
        r.cell.outputs_dirty = true
        r.cell.run_state = "idle"
        require("cellbook.render.text").render_now(nb, r.cell)
        require("cellbook.buffer.decor").update_cell(nb, r.cell)
      end
    end
  end
  if #items == 0 then
    return true
  end
  require("cellbook.kernel.session").get_or_create(nb):enqueue(items, opts)
  return true
end

---Run the cell under the cursor (or the cell at `cell_index`, 1-based).
---@param bufnr integer?
---@param cell_index integer?
function M.run_cell(bufnr, cell_index)
  local nb, err = nb_of(bufnr)
  if not nb then
    return nil, err
  end
  local tracker = require("cellbook.buffer.tracker")
  local idx = cell_index
  if not idx then
    idx = tracker.current(nb)
  else
    tracker.flush(nb)
  end
  local r = idx and nb.ranges[idx]
  if not r then
    return nil, "no cell"
  end
  return run_ranges(nb, { r }, { stop_on_error = true })
end

---Run the current cell and move to the next one (creating a cell at the end).
---@param bufnr integer?
function M.run_cell_and_next(bufnr)
  local nb, err = nb_of(bufnr)
  if not nb then
    return nil, err
  end
  local tracker = require("cellbook.buffer.tracker")
  local idx = tracker.current(nb)
  if not idx then
    return nil, "no cell"
  end
  run_ranges(nb, { nb.ranges[idx] }, { stop_on_error = true })
  if idx >= #nb.ranges then
    require("cellbook.buffer.ops").add_cell(nb, { where = "below", type = "code" })
  else
    require("cellbook.buffer.ops").goto_cell(nb, 1)
  end
  return true
end

---Run all cells.
---@param bufnr integer?
function M.run_all(bufnr)
  local nb, err = nb_of(bufnr)
  if not nb then
    return nil, err
  end
  require("cellbook.buffer.tracker").flush(nb)
  return run_ranges(nb, vim.list_slice(nb.ranges, 1), nil)
end

---Run cells above the current one (exclusive).
---@param bufnr integer?
function M.run_above(bufnr)
  local nb, err = nb_of(bufnr)
  if not nb then
    return nil, err
  end
  local idx = require("cellbook.buffer.tracker").current(nb)
  if not idx then
    return nil, "no cell"
  end
  return run_ranges(nb, vim.list_slice(nb.ranges, 1, idx - 1), nil)
end

---Run the current cell and all following cells.
---@param bufnr integer?
function M.run_below(bufnr)
  local nb, err = nb_of(bufnr)
  if not nb then
    return nil, err
  end
  local idx = require("cellbook.buffer.tracker").current(nb)
  if not idx then
    return nil, "no cell"
  end
  return run_ranges(nb, vim.list_slice(nb.ranges, idx), nil)
end

---Run selected lines (1-based, inclusive) as one request; outputs go to the
---cell containing `end_row`.
---@param bufnr integer?
---@param start_row integer
---@param end_row integer
function M.run_range(bufnr, start_row, end_row)
  local nb, err = nb_of(bufnr)
  if not nb then
    return nil, err
  end
  local tracker = require("cellbook.buffer.tracker")
  tracker.flush(nb)
  if start_row > end_row then
    start_row, end_row = end_row, start_row
  end
  local _, r = tracker.index_at(nb, end_row - 1)
  if not r then
    return nil, "no cell"
  end
  local lines = vim.api.nvim_buf_get_lines(nb.bufnr, start_row - 1, end_row, false)
  local code = {}
  local marked = {}
  for _, rr in ipairs(nb.ranges) do
    marked[rr.start] = true
  end
  for i, l in ipairs(lines) do
    if not marked[start_row - 2 + i] then
      code[#code + 1] = l
    end
  end
  local text = table.concat(code, "\n")
  if r.cell.type ~= "code" or not text:find("%S") then
    return true
  end
  require("cellbook.kernel.session")
    .get_or_create(nb)
    :enqueue({ { cell = r.cell, code = text } }, { stop_on_error = true })
  return true
end

---Interrupt the kernel.
---@param bufnr integer?
function M.interrupt(bufnr)
  local nb, err = nb_of(bufnr, false)
  if not nb then
    return nil, err
  end
  if nb.session then
    nb.session:interrupt()
  end
  return true
end

---Restart the kernel.
---@param bufnr integer?
---@param opts {run_all: boolean?}?
function M.restart(bufnr, opts)
  local nb, err = nb_of(bufnr, false)
  if not nb then
    return nil, err
  end
  opts = opts or {}
  local s = require("cellbook.kernel.session").get_or_create(nb)
  local b = nb.bufnr
  s:restart({
    on_ready = opts.run_all and function()
      M.run_all(b)
    end or nil,
  })
  return true
end

---Shut down the kernel.
---@param bufnr integer?
function M.shutdown(bufnr)
  local nb, err = nb_of(bufnr, false)
  if not nb then
    return nil, err
  end
  if nb.session then
    nb.session:shutdown()
  end
  return true
end

-- Cells ----------------------------------------------------------------------

---@param bufnr integer?
---@param opts {where: "below"|"above"?, type: "code"|"markdown"|"raw"?}?
function M.add_cell(bufnr, opts)
  local nb, err = nb_of(bufnr)
  if not nb then
    return nil, err
  end
  return require("cellbook.buffer.ops").add_cell(nb, opts) ~= nil
end

---@param bufnr integer?
function M.delete_cell(bufnr)
  local nb, err = nb_of(bufnr)
  if not nb then
    return nil, err
  end
  require("cellbook.buffer.ops").delete_cell(nb)
  return true
end

---@param bufnr integer?
---@param delta integer -1 up, +1 down
function M.move_cell(bufnr, delta)
  local nb, err = nb_of(bufnr)
  if not nb then
    return nil, err
  end
  require("cellbook.buffer.ops").move_cell(nb, delta)
  return true
end

---@param bufnr integer?
function M.split_cell(bufnr)
  local nb, err = nb_of(bufnr)
  if not nb then
    return nil, err
  end
  require("cellbook.buffer.ops").split_cell(nb)
  return true
end

---@param bufnr integer?
---@param dir "below"|"above"?
function M.merge_cell(bufnr, dir)
  local nb, err = nb_of(bufnr)
  if not nb then
    return nil, err
  end
  require("cellbook.buffer.ops").merge_cell(nb, dir or "below")
  return true
end

---@param bufnr integer?
---@param cell_type "code"|"markdown"|"raw"
function M.set_cell_type(bufnr, cell_type)
  local nb, err = nb_of(bufnr)
  if not nb then
    return nil, err
  end
  if not vim.tbl_contains({ "code", "markdown", "raw" }, cell_type) then
    return nil, "invalid cell type: " .. tostring(cell_type)
  end
  require("cellbook.buffer.ops").set_cell_type(nb, cell_type)
  return true
end

---Toggle code ↔ markdown.
---@param bufnr integer?
function M.toggle_cell_type(bufnr)
  local nb, err = nb_of(bufnr)
  if not nb then
    return nil, err
  end
  local _, r = require("cellbook.buffer.tracker").current(nb)
  if not r then
    return nil, "no cell"
  end
  return M.set_cell_type(nb.bufnr, r.cell.type == "code" and "markdown" or "code")
end

---Relative jump; returns the new index.
---@param bufnr integer?
---@param delta integer
function M.goto_cell(bufnr, delta)
  local nb, err = nb_of(bufnr, false)
  if not nb then
    return nil, err
  end
  return require("cellbook.buffer.ops").goto_cell(nb, delta)
end

---@param bufnr integer?
---@param opts {all: boolean?}?
function M.clear_output(bufnr, opts)
  local nb, err = nb_of(bufnr)
  if not nb then
    return nil, err
  end
  opts = opts or {}
  local tracker = require("cellbook.buffer.tracker")
  local cells
  if opts.all then
    tracker.flush(nb)
    cells = nb.cells
  else
    local _, r = tracker.current(nb)
    cells = r and { r.cell } or {}
  end
  local changed = false
  for _, c in ipairs(cells) do
    if c.type == "code" and (#c.outputs > 0 or c.execution_count ~= vim.NIL) then
      c.outputs = {}
      c.execution_count = vim.NIL
      c.outputs_dirty = true
      if c.run_state ~= "running" and c.run_state ~= "queued" then
        c.run_state = "idle"
      end
      require("cellbook.render.text").render_now(nb, c)
      require("cellbook.buffer.decor").update_cell(nb, c)
      changed = true
    end
  end
  if changed then
    vim.bo[nb.bufnr].modified = true
  end
  return true
end

---Hide/show outputs.
---@param bufnr integer?
---@param opts {all: boolean?}?
function M.toggle_output(bufnr, opts)
  local nb, err = nb_of(bufnr, false)
  if not nb then
    return nil, err
  end
  opts = opts or {}
  local tracker = require("cellbook.buffer.tracker")
  local cells
  if opts.all then
    tracker.flush(nb)
    cells = nb.cells
    local any_shown = false
    for _, c in ipairs(cells) do
      if not c.collapsed_output and #c.outputs > 0 then
        any_shown = true
      end
    end
    for _, c in ipairs(cells) do
      c.collapsed_output = any_shown
    end
  else
    local _, r = tracker.current(nb)
    cells = r and { r.cell } or {}
    for _, c in ipairs(cells) do
      c.collapsed_output = not c.collapsed_output
    end
  end
  for _, c in ipairs(cells) do
    require("cellbook.render.text").render_now(nb, c)
    require("cellbook.buffer.decor").update_cell(nb, c)
  end
  return true
end

---Full output in a scratch split; images in the system viewer.
---@param bufnr integer?
function M.open_output(bufnr)
  local nb, err = nb_of(bufnr, false)
  if not nb then
    return nil, err
  end
  local _, r = require("cellbook.buffer.tracker").current(nb)
  if not r then
    return nil, "no cell"
  end
  local image = require("cellbook.render.image")
  local cell = r.cell
  local has_text, has_unrendered_image = false, false
  local cfg = require("cellbook.config").get(nb.bufnr)
  for _, o in ipairs(cell.outputs) do
    local mime = o.data
      and require("cellbook.model.outputs").select_mime(o, cfg.output.mime_priority, function(m)
        return image.supports(nb, m)
      end)
    if mime and mime:sub(1, 6) == "image/" then
      if not image.renders(nb, mime) then
        has_unrendered_image = true
      end
    else
      has_text = true
    end
  end
  if #cell.outputs == 0 then
    vim.notify("cellbook: cell has no output", vim.log.levels.INFO)
    return true
  end
  if has_unrendered_image or not has_text then
    image.open_external(nb, cell)
  end
  if has_text then
    require("cellbook.render.text").open_full(nb, cell)
  end
  return true
end

-- Kernel ---------------------------------------------------------------------

---@param bufnr integer?
---@param callback fun(spec: table?)?
function M.select_kernel(bufnr, callback)
  local nb, err = nb_of(bufnr)
  if not nb then
    return nil, err
  end
  require("cellbook.kernel.session").select_kernel(nb, callback)
  return true
end

---@param bufnr integer?
---@return {name: string?, display_name: string?, state: string, python: string?}?
function M.kernel_info(bufnr)
  local nb = nb_of(bufnr, false)
  if not nb or not nb.session then
    return nil
  end
  return nb.session:info()
end

-- Introspection ----------------------------------------------------------------

---@param bufnr integer?
---@return {index: integer, id: string?, type: string, run_state: string, execution_count: integer?}?
function M.current_cell(bufnr)
  local nb = nb_of(bufnr, false)
  if not nb or nb.readonly then
    return nil
  end
  local idx, r = require("cellbook.buffer.tracker").current(nb)
  if not idx or not r then
    return nil
  end
  local ec = r.cell.execution_count
  return {
    index = idx,
    id = r.cell.id,
    type = r.cell.type,
    run_state = r.cell.run_state,
    execution_count = ec ~= vim.NIL and ec or nil,
  }
end

---@param bufnr integer?
---@return integer
function M.cell_count(bufnr)
  local nb = nb_of(bufnr, false)
  if not nb then
    return 0
  end
  require("cellbook.buffer.tracker").flush(nb)
  return #nb.cells
end

-- UI -----------------------------------------------------------------------------

---Statusline/winbar component, e.g. " python3 ● idle  [3/12]".
---@param bufnr integer?
---@return string
function M.statusline(bufnr)
  return require("cellbook.status").statusline(bufnr)
end

---Register an image renderer adapter (tried before built-ins with backend "auto").
---@param adapter cellbook.RendererAdapter
function M.register_renderer(adapter)
  require("cellbook.render.image").register(adapter)
end

return M
