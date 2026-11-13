---Structural cell operations. Each operation edits buffer text with one
---`nvim_buf_set_lines` call (one undo step) and places fresh extmarks; the old
---marks are invalidated by the edit and restored by undo, which revives the
---original cell objects (with their outputs).
local api = vim.api
local percent = require("cellbook.format.percent")
local Cell = require("cellbook.model.cell")
local tracker = require("cellbook.buffer.tracker")

local M = {}

---@param nb cellbook.Notebook
---@param row integer 0-based
local function set_cursor(nb, row)
  local win = tracker.win_for(nb.bufnr)
  if win then
    row = math.max(0, math.min(row, api.nvim_buf_line_count(nb.bufnr) - 1))
    api.nvim_win_set_cursor(win, { row + 1, 0 })
  end
end

---@param nb cellbook.Notebook
local function finish(nb)
  local seq = api.nvim_buf_call(nb.bufnr, vim.fn.changenr)
  nb.last_seq = seq
  nb.max_seq = math.max(nb.max_seq or 0, seq)
  nb.dirty_span = nil
  local prev = nb.cells
  tracker.scan(nb)
  local present, removed = {}, {}
  for _, c in ipairs(nb.cells) do
    present[c] = true
  end
  for _, c in ipairs(prev) do
    if not present[c] then
      removed[#removed + 1] = c
    end
  end
  for _, r in ipairs(nb.ranges) do
    if r.stop >= r.start + 1 then
      r.cell.snapshot = table.concat(api.nvim_buf_get_lines(nb.bufnr, r.start + 1, r.stop + 1, false), "\n")
    else
      r.cell.snapshot = ""
    end
  end
  nb.refresh_pending = false
  tracker.after_refresh(nb, { structure = true, removed = removed })
end

---@param nb cellbook.Notebook
---@return boolean ok
local function editable(nb)
  if nb.readonly or not vim.bo[nb.bufnr].modifiable then
    vim.notify("cellbook: notebook is read-only", vim.log.levels.WARN)
    return false
  end
  return true
end

---Add a cell above/below the current one.
---@param nb cellbook.Notebook
---@param opts {where: "above"|"below"?, type: cellbook.CellType?, source: string?}?
---@return cellbook.Cell?
function M.add_cell(nb, opts)
  opts = opts or {}
  if not editable(nb) then
    return nil
  end
  local where = opts.where or "below"
  local t = opts.type or "code"
  local _, r = tracker.current(nb)
  local row
  if not r then
    row = api.nvim_buf_line_count(nb.bufnr)
    if row == 1 and api.nvim_buf_get_lines(nb.bufnr, 0, 1, false)[1] == "" then
      row = 0
    end
  elseif where == "above" then
    row = r.start
  else
    row = r.stop + 1
  end
  local cell = tracker.new_cell(nb, t)
  local lines = { percent.delimiter(t, nb.comment) }
  vim.list_extend(lines, percent.source_to_lines(t, opts.source or "", nb.comment))
  local replace_empty = not r and row == 0
  api.nvim_buf_set_lines(nb.bufnr, row, replace_empty and 1 or row, false, lines)
  tracker.place(nb, cell, row)
  finish(nb)
  set_cursor(nb, row + 1)
  return cell
end

---Delete the current cell.
---@param nb cellbook.Notebook
function M.delete_cell(nb)
  if not editable(nb) then
    return
  end
  local _, r = tracker.current(nb)
  if not r then
    return
  end
  local total = api.nvim_buf_line_count(nb.bufnr)
  if r.start == 0 and r.stop == total - 1 then
    api.nvim_buf_set_lines(nb.bufnr, 0, -1, false, { "" })
  else
    api.nvim_buf_set_lines(nb.bufnr, r.start, r.stop + 1, false, {})
  end
  finish(nb)
  set_cursor(nb, r.start)
end

---Swap the current cell with its neighbour.
---@param nb cellbook.Notebook
---@param delta integer -1 (up) or +1 (down)
function M.move_cell(nb, delta)
  if not editable(nb) then
    return
  end
  local idx, r = tracker.current(nb)
  if not idx or not r then
    return
  end
  local other = nb.ranges[idx + delta]
  if not other then
    return
  end
  local win = tracker.win_for(nb.bufnr)
  local offset = win and (api.nvim_win_get_cursor(win)[1] - 1 - r.start) or 1
  local a, b = delta < 0 and other or r, delta < 0 and r or other
  local lines_a = api.nvim_buf_get_lines(nb.bufnr, a.start, a.stop + 1, false)
  local lines_b = api.nvim_buf_get_lines(nb.bufnr, b.start, b.stop + 1, false)
  local new = vim.list_extend(vim.list_extend({}, lines_b), lines_a)
  api.nvim_buf_set_lines(nb.bufnr, a.start, b.stop + 1, false, new)
  tracker.place(nb, b.cell, a.start)
  tracker.place(nb, a.cell, a.start + #lines_b)
  finish(nb)
  local new_start = r.cell == a.cell and (a.start + #lines_b) or a.start
  set_cursor(nb, new_start + offset)
end

---Split the current cell at the cursor line (the cursor line starts the new cell).
---@param nb cellbook.Notebook
function M.split_cell(nb)
  if not editable(nb) then
    return
  end
  local _, r = tracker.current(nb)
  local win = tracker.win_for(nb.bufnr)
  if not r or not win then
    return
  end
  local row = api.nvim_win_get_cursor(win)[1] - 1
  if row <= r.start then
    row = r.start + 1
  end
  local t = tracker.display_type(r.cell)
  local cell = tracker.new_cell(nb, t)
  api.nvim_buf_set_lines(nb.bufnr, row, row, false, { percent.delimiter(t, nb.comment) })
  tracker.place(nb, cell, row)
  finish(nb)
  set_cursor(nb, row + 1)
end

---Merge the current cell with the one below/above (keeps the upper cell's outputs).
---@param nb cellbook.Notebook
---@param dir "below"|"above"
function M.merge_cell(nb, dir)
  if not editable(nb) then
    return
  end
  local idx, r = tracker.current(nb)
  if not idx or not r then
    return
  end
  local lower = dir == "above" and r or nb.ranges[idx + 1]
  local upper = dir == "above" and nb.ranges[idx - 1] or r
  if not lower or not upper then
    return
  end
  local ut, lt = tracker.display_type(upper.cell), tracker.display_type(lower.cell)
  local body = lower.stop >= lower.start + 1
      and api.nvim_buf_get_lines(nb.bufnr, lower.start + 1, lower.stop + 1, false)
    or {}
  if ut ~= lt then
    local src = percent.lines_to_source(lt, body, nb.comment)
    body = percent.source_to_lines(ut, src, nb.comment)
  end
  api.nvim_buf_set_lines(nb.bufnr, lower.start, lower.stop + 1, false, body)
  finish(nb)
  set_cursor(nb, lower.start)
end

---Change the type of the current cell. Converting code to markdown/raw drops outputs.
---@param nb cellbook.Notebook
---@param new_type cellbook.CellType
function M.set_cell_type(nb, new_type)
  if not editable(nb) then
    return
  end
  local _, r = tracker.current(nb)
  if not r then
    return
  end
  local old_t = tracker.display_type(r.cell)
  if old_t == new_type then
    return
  end
  local body = r.stop >= r.start + 1 and api.nvim_buf_get_lines(nb.bufnr, r.start + 1, r.stop + 1, false) or {}
  local src = percent.lines_to_source(old_t, body, nb.comment)
  local lines = { percent.delimiter(new_type, nb.comment) }
  vim.list_extend(lines, percent.source_to_lines(new_type, src, nb.comment))
  local win = tracker.win_for(nb.bufnr)
  local cursor = win and api.nvim_win_get_cursor(win)[1] - 1 or r.start
  api.nvim_buf_set_lines(nb.bufnr, r.start, r.stop + 1, false, lines)
  local cell = Cell.retyped(r.cell, new_type)
  tracker.place(nb, cell, r.start)
  finish(nb)
  set_cursor(nb, cursor)
end

---Jump relative to the current cell.
---@param nb cellbook.Notebook
---@param delta integer
---@return integer? new index
function M.goto_cell(nb, delta)
  local idx = tracker.current(nb)
  if not idx then
    return nil
  end
  local win = tracker.win_for(nb.bufnr)
  local row = win and api.nvim_win_get_cursor(win)[1] - 1 or 0
  local r = nb.ranges[idx]
  -- `[c` inside a cell body goes to the start of the current cell first
  if delta < 0 and r and row > r.start + 1 then
    delta = delta + 1
  end
  local target = math.max(1, math.min(#nb.ranges, idx + delta))
  local tr = nb.ranges[target]
  if not tr then
    return nil
  end
  set_cursor(nb, math.min(tr.start + 1, tr.stop))
  return target
end

return M
