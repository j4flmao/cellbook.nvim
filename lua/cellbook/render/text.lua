---Text output rendering with `virt_lines` (never buffer text).
---
---Outputs of cell i are anchored *above the delimiter of cell i+1*, so they always
---follow the cell's last line while the user types; the last cell's outputs are
---anchored below the last buffer line and re-anchored when it moves.
local api = vim.api
local config = require("cellbook.config")
local outputs = require("cellbook.model.outputs")
local ansi = require("cellbook.render.ansi")
local html_table = require("cellbook.render.html_table")

local M = {}

M.ns = api.nvim_create_namespace("cellbook.outputs")

local THROTTLE_MS = 30

---@param s string
---@return string[]
local function split_lines(s)
  s = s:gsub("\r\n", "\n")
  local lines = vim.split(s, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    lines[#lines] = nil
  end
  for i, l in ipairs(lines) do
    -- leftover carriage returns (progress bars): keep the last segment
    if l:find("\r", 1, true) then
      local segs = vim.split(l, "\r", { plain = true })
      local keep = ""
      for k = #segs, 1, -1 do
        if segs[k] ~= "" then
          keep = segs[k]
          break
        end
      end
      lines[i] = keep
    end
  end
  return lines
end
M.split_lines = split_lines

---Placeholder text for an image output.
---@param out cellbook.Output
---@param mime string
---@return string
function M.image_placeholder(out, mime)
  if out.size_cache == nil then
    out.size_cache = false
    local w, h
    local md = type(out.metadata) == "table" and out.metadata[mime]
    if type(md) == "table" and md.width and md.height then
      w, h = require("cellbook.format.json").tonumber(md.width), require("cellbook.format.json").tonumber(md.height)
    elseif mime == "image/png" then
      local data = outputs.get(out, mime)
      if type(data) == "string" then
        local ok, bytes = pcall(vim.base64.decode, (data:sub(1, 64):gsub("%s", "")))
        if ok then
          w, h = outputs.png_size(bytes)
        end
      end
    end
    if w and h then
      out.size_cache = ("%d×%d"):format(w, h)
    end
  end
  local size = out.size_cache and (" " .. out.size_cache) or ""
  return ("[%s%s — open with <localleader>o]"):format(mime, size)
end

---Lines (as chunk lists) for one output.
---@param nb cellbook.Notebook
---@param out cellbook.Output
---@param cfg cellbook.Config
---@param full boolean? ignore truncation
---@param cell cellbook.Cell? owning cell (enables async block images)
---@return table[] lines
---@return integer total line count before truncation
function M.output_lines(nb, out, cfg, full, cell)
  local image = require("cellbook.render.image")
  local base = "CellbookOutput"
  local text
  local raw_text = false
  if out.type == "stream" then
    if out.name == "stderr" then
      if not cfg.output.show_stderr then
        return {}, 0
      end
      base = "CellbookOutputStderr"
    end
    text = out.text or ""
  elseif out.type == "error" then
    text = table.concat(out.traceback or {}, "\n")
    if text == "" then
      text = ("%s: %s"):format(out.ename or "Error", out.evalue or "")
    end
    base = "CellbookOutputError"
  elseif out.type == "execute_result" or out.type == "display_data" then
    local data = out.data or {}
    if data["application/vnd.jupyter.widget-view+json"] ~= nil then
      return { { { "[widget — not supported]", "CellbookOutputTruncated" } } }, 1
    end
    local mime = outputs.select_mime(out, cfg.output.mime_priority, function(m)
      return image.supports(nb, m)
    end)
    -- DataFrames & other HTML tables → box-drawn table (unless an image is preferred)
    if cfg.output.html_tables and data["text/html"] ~= nil and not (mime and mime:sub(1, 6) == "image/") then
      if out.table_cache == nil then
        local html = outputs.get(out, "text/html")
        out.table_cache = type(html) == "string" and html:find("<table") and html_table.parse(html) or false
      end
      if out.table_cache then
        local max_width
        if not full then
          local win = require("cellbook.buffer.tracker").win_for(nb.bufnr)
          local tw = win and api.nvim_win_get_width(win) or 100
          local textoff = win and (vim.fn.getwininfo(win)[1] or {}).textoff or 6
          max_width = math.max(30, tw - textoff - (cfg.ui.cell_padding or 0) - 1)
        end
        local lines = html_table.render(out.table_cache, full and 80 or 40, max_width)
        local total = #lines
        local limit = full and math.huge or cfg.output.max_lines
        if total > limit then
          lines = vim.list_slice(lines, 1, limit)
          lines[#lines + 1] = {
            { ("… %d more lines — <localleader>o to open"):format(total - limit), "CellbookOutputTruncated" },
          }
        end
        return lines, total
      end
    end
    if not mime then
      local kinds = vim.tbl_keys(data)
      table.sort(kinds)
      return { { { ("[%s — not supported]"):format(table.concat(kinds, ", ")), "CellbookOutputTruncated" } } }, 1
    end
    if mime:sub(1, 6) == "image/" then
      if image.renders(nb, mime) and not full then
        return {}, 0 -- drawn by the image adapter
      end
      if cfg.image.blocks and cell and not full then
        local win = require("cellbook.buffer.tracker").win_for(nb.bufnr)
        local width = win and api.nvim_win_get_width(win) or 80
        local textoff = win and (vim.fn.getwininfo(win)[1] or {}).textoff or 6
        local avail = width - textoff - (cfg.ui.cell_padding or 0) - 2
        local cols = math.max(16, math.min(cfg.image.max_width or avail, avail))
        local mode = cfg.image.blocks == "half" and "half" or "sextant"
        local lines, st = require("cellbook.render.blocks").lines(nb, cell, out, mime, cols, cfg.image.max_height, mode)
        if lines then
          return lines, #lines
        elseif st and st.pending then
          return { { { ("[rendering %s …]"):format(mime), "CellbookOutputTruncated" } } }, 1
        end
      end
      return { { { M.image_placeholder(out, mime), "CellbookOutputTruncated" } } }, 1
    end
    text = outputs.get(out, mime)
    if type(text) ~= "string" then
      text = vim.inspect(text)
    end
    if mime == "text/markdown" then
      base = "CellbookMarkdown"
      raw_text = true
    end
  else
    return { { { ("[unknown output type %s]"):format(tostring(out.type)), "CellbookOutputTruncated" } } }, 1
  end

  local lines = split_lines(text)
  local total = #lines
  local limit = full and math.huge or cfg.output.max_lines
  local result = {}
  local st = {}
  for i = 1, math.min(total, limit) do
    if raw_text then
      result[i] = { { (lines[i]:gsub("\t", "    ")), base } }
    else
      result[i] = ansi.parse_line(lines[i], st, base, cfg.output.ansi)
    end
  end
  if total > limit then
    result[#result + 1] = {
      {
        ("… %d more line%s — <localleader>o to open"):format(total - limit, total - limit == 1 and "" or "s"),
        "CellbookOutputTruncated",
      },
    }
  end
  return result, total
end

---All virtual lines of a cell.
---@param nb cellbook.Notebook
---@param cell cellbook.Cell
---@return table[]
function M.cell_lines(nb, cell)
  local cfg = config.get(nb.bufnr)
  if cell.type ~= "code" then
    return {}
  end
  local out = {}
  if not cell.collapsed_output then
    local padding = cfg.ui.cell_padding or 0
    local gutter = cfg.ui.output_gutter or ""
    local lead
    if padding > 0 then
      lead = gutter ~= "" and (gutter .. string.rep(" ", math.max(0, padding - vim.api.nvim_strwidth(gutter))))
        or string.rep(" ", padding)
    end
    for _, o in ipairs(cell.outputs) do
      local group = o.type == "error" and "CellbookOutputGutterError" or "CellbookOutputGutter"
      for _, chunks in ipairs(M.output_lines(nb, o, cfg, false, cell)) do
        local line = lead and { { lead, group } } or {}
        vim.list_extend(line, chunks) -- copy: cached lines must not be mutated
        out[#out + 1] = line
      end
    end
  end
  if cfg.ui.cell_header then
    out[#out + 1] = { { "", "CellbookOutput" } } -- spacer below the cell
  end
  return out
end

---Where the output block of a cell is anchored.
---@param nb cellbook.Notebook
---@param cell cellbook.Cell
---@return integer? row, boolean above
local function anchor(nb, cell)
  for i, r in ipairs(nb.ranges) do
    if r.cell == cell then
      local nxt = nb.ranges[i + 1]
      if nxt then
        return nxt.start, true
      end
      return r.stop, false
    end
  end
  return nil, false
end

---Place (or move) the virt_lines extmark of a cell.
---@param nb cellbook.Notebook
---@param cell cellbook.Cell
function M.place(nb, cell)
  local view = cell.view
  if not view then
    return
  end
  local row, above = anchor(nb, cell)
  if not row or not view.lines or #view.lines == 0 then
    if view.mark then
      pcall(api.nvim_buf_del_extmark, nb.bufnr, M.ns, view.mark)
      view.mark = nil
    end
    return
  end
  local cfg = config.get(nb.bufnr)
  local ok, id = pcall(api.nvim_buf_set_extmark, nb.bufnr, M.ns, row, 0, {
    id = view.mark,
    virt_lines = view.lines,
    virt_lines_above = above,
    virt_lines_leftcol = cfg.output.virt_lines_leftcol,
    priority = 100,
  })
  if ok then
    view.mark = id
  end
end

---Rebuild and draw a cell's text outputs now.
---@param nb cellbook.Notebook
---@param cell cellbook.Cell
function M.render_now(nb, cell)
  if not api.nvim_buf_is_valid(nb.bufnr) then
    return
  end
  cell.view = cell.view or {}
  cell.view.pending = false
  cell.view.lines = M.cell_lines(nb, cell)
  M.place(nb, cell)
  require("cellbook.render.image").render_cell(nb, cell)
end

---Schedule a (throttled) re-render of a cell's outputs.
---@param nb cellbook.Notebook
---@param cell cellbook.Cell
function M.render(nb, cell)
  cell.view = cell.view or {}
  if cell.view.pending then
    return
  end
  cell.view.pending = true
  vim.defer_fn(function()
    if cell.view and cell.view.pending then
      M.render_now(nb, cell)
    end
  end, THROTTLE_MS)
end

---Remove a cell's output marks (cell deleted).
---@param nb cellbook.Notebook
---@param cell cellbook.Cell
function M.clear(nb, cell)
  if cell.view and cell.view.mark then
    pcall(api.nvim_buf_del_extmark, nb.bufnr, M.ns, cell.view.mark)
    cell.view.mark = nil
  end
  require("cellbook.render.image").clear_cell(nb, cell)
end

---Render outputs of every cell.
---@param nb cellbook.Notebook
function M.render_all(nb)
  api.nvim_buf_clear_namespace(nb.bufnr, M.ns, 0, -1)
  for _, c in ipairs(nb.cells) do
    if c.view then
      c.view.mark = nil
    end
    if c.type == "code" then
      M.render_now(nb, c)
    end
  end
end

---@param nb cellbook.Notebook
---@param info table
function M.on_refresh(nb, info)
  for _, c in ipairs(info.removed or {}) do
    M.clear(nb, c)
  end
  if info.structure then
    for _, c in ipairs(nb.cells) do
      if c.view and c.view.lines then
        M.place(nb, c)
      elseif c.type == "code" then
        M.render_now(nb, c)
      end
    end
  elseif info.last_moved then
    local last = nb.cells[#nb.cells]
    if last and last.view then
      M.place(nb, last)
    end
  end
end

---Open the full output of a cell in a scratch split.
---@param nb cellbook.Notebook
---@param cell cellbook.Cell
function M.open_full(nb, cell)
  local cfg = config.get(nb.bufnr)
  local lines, hls = {}, {}
  for k, o in ipairs(cell.outputs) do
    if k > 1 then
      lines[#lines + 1] = ""
    end
    local ls = M.output_lines(nb, o, cfg, true)
    for _, chunks in ipairs(ls) do
      local text, col = {}, 0
      local row = #lines
      for _, ch in ipairs(chunks) do
        text[#text + 1] = ch[1]
        if ch[2] and #ch[1] > 0 then
          hls[#hls + 1] = { row, col, col + #ch[1], ch[2] }
        end
        col = col + #ch[1]
      end
      lines[#lines + 1] = table.concat(text)
    end
  end
  if #lines == 0 then
    lines = { "(no output)" }
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, h in ipairs(hls) do
    pcall(api.nvim_buf_set_extmark, buf, M.ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "cellbook_output"
  pcall(api.nvim_buf_set_name, buf, ("cellbook://output/%d/%s"):format(nb.bufnr, cell.id or tostring(cell.mark)))
  vim.cmd("botright split")
  api.nvim_win_set_buf(0, buf)
  -- wide tables / long lines: scroll horizontally instead of wrapping
  vim.wo[0][0].wrap = false
  vim.wo[0][0].number = false
  vim.wo[0][0].relativenumber = false
end

return M
