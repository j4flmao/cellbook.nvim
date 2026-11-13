---Extmark-based cell boundary tracking.
---
---Each cell owns one extmark on its delimiter line (namespace `cellbook.cells`).
---Marks use `invalidate` + `undo_restore`, so deleting a delimiter hides its cell
---and undo brings the same cell object (with its outputs) back. Lines that merely
---look like delimiters but have no mark are ordinary content (a literal `# %%`
---inside a string never splits a cell), except after undo/redo, where unmarked
---delimiters are re-adopted (matching orphaned cells by type and text).
local api = vim.api
local percent = require("cellbook.format.percent")
local Cell = require("cellbook.model.cell")
local Notebook = require("cellbook.model.notebook")

local M = {}

M.ns = api.nvim_create_namespace("cellbook.cells")

local DEBOUNCE_MS = 30

---Effective display type ("code"|"markdown"|"raw") of a cell.
---@param cell cellbook.Cell
---@return "code"|"markdown"|"raw"
function M.display_type(cell)
  if cell.type == "code" or cell.type == "markdown" then
    return cell.type
  end
  return "raw"
end

---@param nb cellbook.Notebook
---@param cell cellbook.Cell
---@param row integer
---@return integer mark id
function M.place(nb, cell, row)
  local id = api.nvim_buf_set_extmark(nb.bufnr, M.ns, row, 0, {
    invalidate = true,
    undo_restore = true,
    right_gravity = true,
  })
  cell.mark = id
  nb.mark_to_cell[id] = cell
  return id
end

---@param nb cellbook.Notebook
---@return boolean
local function new_cells_get_ids(nb)
  return (nb.nbformat_minor or 0) >= 5
end

---Create a new cell (with an id when nbformat ≥ 4.5).
---@param nb cellbook.Notebook
---@param cell_type cellbook.CellType
---@return cellbook.Cell
function M.new_cell(nb, cell_type)
  local id = new_cells_get_ids(nb) and Cell.new_id(Notebook.ids(nb)) or nil
  return Cell.new(cell_type, { id = id })
end

---@param nb cellbook.Notebook
---@param start integer
---@param stop integer inclusive
---@return string
local function body_text(nb, start, stop)
  if stop < start + 1 then
    return ""
  end
  return table.concat(api.nvim_buf_get_lines(nb.bufnr, start + 1, stop + 1, false), "\n")
end

---Change a cell's type in place (delimiter text edited by hand / undo of a conversion).
---@param cell cellbook.Cell
---@param t "code"|"markdown"|"raw"
local function retype_in_place(cell, t)
  if cell.type == "code" and t ~= "code" then
    cell.stash = { outputs = cell.outputs, execution_count = cell.execution_count, outputs_dirty = cell.outputs_dirty }
    cell.outputs = {}
    cell.execution_count = vim.NIL
    cell.outputs_dirty = #cell.stash.outputs > 0 or cell.stash.outputs_dirty
  elseif t == "code" and cell.stash then
    cell.outputs = cell.stash.outputs
    cell.execution_count = cell.stash.execution_count
    cell.outputs_dirty = cell.stash.outputs_dirty
    cell.stash = nil
  end
  cell.type = t
end

---Compute the current cell layout from extmarks.
---@param nb cellbook.Notebook
---@param opts {adopt: boolean?}?
---@return {cell: cellbook.Cell, start: integer, stop: integer}[] ranges
function M.scan(nb, opts)
  opts = opts or {}
  local buf = nb.bufnr
  local c = nb.comment
  local marks = api.nvim_buf_get_extmarks(buf, M.ns, 0, -1, { details = true })
  local entries = {}
  local seen_cells, seen_rows = {}, {}
  for _, m in ipairs(marks) do
    local id, row, details = m[1], m[2], m[4]
    if not details.invalid and not seen_rows[row] then
      local cell = nb.mark_to_cell[id]
      if cell and not seen_cells[cell] then
        local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
        if percent.is_delimiter(line, c) then
          seen_cells[cell] = true
          seen_rows[row] = true
          if cell.mark ~= id then
            cell.mark = id
          end
          entries[#entries + 1] = { cell = cell, start = row, line = line }
        end
      end
    end
  end

  if opts.adopt then
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local orphans = {}
    for _, cell in pairs(nb.mark_to_cell) do
      if not seen_cells[cell] and not orphans[cell] then
        orphans[cell] = true
      end
    end
    local delim_rows = {}
    for i, l in ipairs(lines) do
      if percent.is_delimiter(l, c) then
        delim_rows[#delim_rows + 1] = i - 1
      end
    end
    local added = false
    for k, row in ipairs(delim_rows) do
      if not seen_rows[row] then
        local stop = (delim_rows[k + 1] or #lines) - 1
        local text = table.concat(vim.list_slice(lines, row + 2, stop + 1), "\n")
        local t = percent.delimiter_type(lines[row + 1], c)
        local match
        for cell in pairs(orphans) do
          if M.display_type(cell) == t and (cell.snapshot or "") == text then
            match = cell
            break
          end
        end
        if match then
          orphans[match] = nil
        else
          match = M.new_cell(nb, t)
          match.snapshot = text
        end
        M.place(nb, match, row)
        seen_rows[row] = true
        entries[#entries + 1] = { cell = match, start = row, line = lines[row + 1] }
        added = true
      end
    end
    if added then
      table.sort(entries, function(a, b)
        return a.start < b.start
      end)
    end
  end

  local line_count = api.nvim_buf_line_count(buf)
  local cells = {}
  for i, e in ipairs(entries) do
    e.stop = (entries[i + 1] and entries[i + 1].start or line_count) - 1
    local t = percent.delimiter_type(e.line, c)
    if t ~= M.display_type(e.cell) then
      retype_in_place(e.cell, t)
    end
    e.line = nil
    cells[i] = e.cell
  end
  nb.cells = cells
  nb.ranges = entries
  return entries
end

---Lines before the first delimiter that contain text (they become a new code cell).
---@param nb cellbook.Notebook
---@return integer? last_row inclusive last orphan row
function M.leading_orphans(nb)
  local first = nb.ranges[1] and nb.ranges[1].start or api.nvim_buf_line_count(nb.bufnr)
  if first == 0 then
    return nil
  end
  local lines = api.nvim_buf_get_lines(nb.bufnr, 0, first, false)
  for _, l in ipairs(lines) do
    if l:find("%S") then
      return first - 1
    end
  end
  return nil
end

---Turn leading orphan lines into a code cell (inserts a delimiter at row 0).
---@param nb cellbook.Notebook
---@return boolean changed
function M.fix_leading_orphans(nb)
  if not M.leading_orphans(nb) then
    return false
  end
  pcall(vim.cmd.undojoin)
  local cell = M.new_cell(nb, "code")
  api.nvim_buf_set_lines(nb.bufnr, 0, 0, false, { percent.delimiter("code", nb.comment) })
  M.place(nb, cell, 0)
  M.scan(nb)
  return true
end

---Create cells for unmarked delimiter lines typed by the user (`:Cellbook sync`).
---@param nb cellbook.Notebook
function M.sync(nb)
  M.fix_leading_orphans(nb)
  M.scan(nb, { adopt = true })
  M.after_refresh(nb, { structure = true })
end

---@param nb cellbook.Notebook
---@param row integer 0-based
---@return integer? index
---@return {cell: cellbook.Cell, start: integer, stop: integer}? range
function M.index_at(nb, row)
  local ranges = nb.ranges
  local lo, hi = 1, #ranges
  local found
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if ranges[mid].start <= row then
      found = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  if found then
    return found, ranges[found]
  end
  return nil, nil
end

---Window showing the buffer (current window preferred).
---@param bufnr integer
---@return integer? win
function M.win_for(bufnr)
  local cur = api.nvim_get_current_win()
  if api.nvim_win_get_buf(cur) == bufnr then
    return cur
  end
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(w) == bufnr then
      return w
    end
  end
  return nil
end

---Range of the cell under the cursor (fresh layout).
---@param nb cellbook.Notebook
---@return integer? index
---@return {cell: cellbook.Cell, start: integer, stop: integer}? range
function M.current(nb)
  M.flush(nb)
  local win = M.win_for(nb.bufnr)
  local row = win and (api.nvim_win_get_cursor(win)[1] - 1) or 0
  local idx, r = M.index_at(nb, row)
  if not idx and nb.ranges[1] then
    return 1, nb.ranges[1]
  end
  return idx, r
end

---Current source text of every cell, aligned with nb.cells.
---@param nb cellbook.Notebook
---@return string[]
function M.sources(nb)
  local out = {}
  local lines = api.nvim_buf_get_lines(nb.bufnr, 0, -1, false)
  for i, r in ipairs(nb.ranges) do
    local body = vim.list_slice(lines, r.start + 2, r.stop + 1)
    out[i] = percent.lines_to_source(M.display_type(r.cell), body, nb.comment)
  end
  return out
end

---Source text of one cell.
---@param nb cellbook.Notebook
---@param r {cell: cellbook.Cell, start: integer, stop: integer}
---@return string
function M.source_of(nb, r)
  local body = r.stop >= r.start + 1 and api.nvim_buf_get_lines(nb.bufnr, r.start + 1, r.stop + 1, false) or {}
  return percent.lines_to_source(M.display_type(r.cell), body, nb.comment)
end

---Refresh layout, decorations and output anchors now.
---@param nb cellbook.Notebook
function M.refresh(nb)
  if nb.detached or not api.nvim_buf_is_valid(nb.bufnr) then
    return
  end
  nb.refresh_pending = false
  local prev_cells = nb.cells
  local prev_last_stop = nb.ranges[#nb.ranges] and nb.ranges[#nb.ranges].stop

  -- undo/redo detection: changenr moves without creating a new undo state
  local seq = api.nvim_buf_call(nb.bufnr, vim.fn.changenr)
  local undo_redo = seq ~= nb.last_seq and seq <= (nb.max_seq or 0)
  nb.last_seq = seq
  nb.max_seq = math.max(nb.max_seq or 0, seq)

  M.scan(nb, { adopt = undo_redo })
  local mode = api.nvim_get_mode().mode
  if not undo_redo and not mode:find("^i") and not mode:find("^R") then
    M.fix_leading_orphans(nb)
  end

  local structure = #prev_cells ~= #nb.cells
  if not structure then
    for i, c in ipairs(nb.cells) do
      if prev_cells[i] ~= c then
        structure = true
        break
      end
    end
  end
  local present = {}
  for _, c in ipairs(nb.cells) do
    present[c] = true
  end
  local removed = {}
  for _, c in ipairs(prev_cells) do
    if not present[c] then
      removed[#removed + 1] = c
    end
  end

  -- dirty cells: intersect the changed row span with the new layout
  local dirty = {}
  local span = nb.dirty_span
  nb.dirty_span = nil
  if span then
    local first = M.index_at(nb, span[1]) or 1
    local last = M.index_at(nb, span[2]) or #nb.ranges
    for i = first, math.min(last, #nb.ranges) do
      dirty[#dirty + 1] = nb.ranges[i]
    end
  end
  for _, r in ipairs(dirty) do
    r.cell.snapshot = body_text(nb, r.start, r.stop)
  end

  local last = nb.ranges[#nb.ranges]
  M.after_refresh(nb, {
    structure = structure,
    removed = removed,
    dirty = dirty,
    last_moved = last and last.stop ~= prev_last_stop,
  })
end

---Notify decorations/renderers after a layout change.
---@param nb cellbook.Notebook
---@param info {structure: boolean?, removed: cellbook.Cell[]?, dirty: table[]?, last_moved: boolean?}
function M.after_refresh(nb, info)
  local ok, err = pcall(function()
    require("cellbook.buffer.decor").on_refresh(nb, info)
    require("cellbook.render.text").on_refresh(nb, info)
    require("cellbook.render.image").on_refresh(nb, info)
  end)
  if not ok then
    require("cellbook.log").add("error", "refresh failed: " .. tostring(err))
  end
end

---Run a pending refresh immediately.
---@param nb cellbook.Notebook
function M.flush(nb)
  if nb.refresh_pending or nb.dirty_span then
    M.refresh(nb)
  end
end

---@param nb cellbook.Notebook
local function schedule(nb)
  if nb.refresh_pending then
    return
  end
  nb.refresh_pending = true
  vim.defer_fn(function()
    if nb.refresh_pending then
      M.refresh(nb)
    end
  end, DEBOUNCE_MS)
end
M.schedule = schedule

---Place marks for all cells (buffer text already set) and start tracking changes.
---@param nb cellbook.Notebook
---@param starts integer[] delimiter row per cell
function M.attach(nb, starts)
  api.nvim_buf_clear_namespace(nb.bufnr, M.ns, 0, -1)
  nb.mark_to_cell = {}
  for i, cell in ipairs(nb.cells) do
    M.place(nb, cell, starts[i])
  end
  M.scan(nb)
  for _, r in ipairs(nb.ranges) do
    r.cell.snapshot = body_text(nb, r.start, r.stop)
  end
  local seq = api.nvim_buf_call(nb.bufnr, vim.fn.changenr)
  nb.last_seq, nb.max_seq = seq, seq

  local token = {}
  nb.attach_token = token
  api.nvim_buf_attach(nb.bufnr, false, {
    on_lines = function(_, _, _, first, _, last_new)
      if nb.detached or nb.attach_token ~= token then
        return true
      end
      local span = nb.dirty_span
      if span then
        span[1] = math.min(span[1], first)
        span[2] = math.max(span[2], last_new)
      else
        nb.dirty_span = { first, last_new }
      end
      schedule(nb)
    end,
    on_reload = function()
      schedule(nb)
    end,
    on_detach = function()
      if nb.attach_token == token then
        nb.attach_token = nil
      end
    end,
  })
end

return M
