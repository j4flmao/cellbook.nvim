---Render HTML tables (pandas DataFrame `text/html`) as box-drawn text tables.
---Pure string processing; returns nil when the HTML is not a simple table.
local M = {}

local entities = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

---@param s string
---@return string
local function text_of(s)
  s = s:gsub("<br%s*/?>", " "):gsub("<[^>]->", "")
  s = s:gsub("&(#?)(%w+);", function(hash, name)
    if hash == "#" then
      local n = name:sub(1, 1) == "x" and tonumber(name:sub(2), 16) or tonumber(name)
      return n and vim.fn.nr2char(n) or ""
    end
    return entities[name] or ("&" .. name .. ";")
  end)
  s = s:gsub("%s+", " ")
  return vim.trim(s)
end

---@class cellbook.HtmlTable
---@field header string[][]   header rows
---@field body {cells: string[], index: integer}[]  body rows (index = number of leading <th>)
---@field caption string?

---Parse the first <table> of an HTML string.
---@param html string
---@return cellbook.HtmlTable?
function M.parse(html)
  local tbl = html:match("<table.->(.-)</table>")
  if not tbl then
    return nil
  end
  local thead = tbl:match("<thead.->(.-)</thead>") or ""
  local tbody = tbl:match("<tbody.->(.-)</tbody>") or tbl:gsub("<thead.-</thead>", "")
  local function rows(chunk)
    local out = {}
    for tr in chunk:gmatch("<tr.->(.-)</tr>") do
      local cells, index = {}, 0
      local leading = true
      for tag, attrs, inner in tr:gmatch("<(t[hd])([^>]*)>(.-)</t[hd]>") do
        local span = tonumber(attrs:match('colspan="?(%d+)'))
        cells[#cells + 1] = text_of(inner)
        for _ = 2, span or 1 do
          cells[#cells + 1] = ""
        end
        if tag == "th" and leading then
          index = index + 1
        else
          leading = false
        end
      end
      if #cells > 0 then
        out[#out + 1] = { cells = cells, index = index }
      end
    end
    return out
  end
  local header = {}
  for _, r in ipairs(rows(thead)) do
    header[#header + 1] = r.cells
  end
  local body = rows(tbody)
  -- no <thead>: leading rows made only of <th> are the header
  while #header == 0 and body[1] and body[1].index == #body[1].cells and #body > 1 do
    header[#header + 1] = table.remove(body, 1).cells
  end
  if #header == 0 and #body == 0 then
    return nil
  end
  local caption = html:match("</table>%s*<p>(.-)</p>")
  return { header = header, body = body, caption = caption and text_of(caption) or nil }
end

---@param s string
---@return boolean
local function numeric(s)
  return s:match("^[-+]?[%d,]*%.?%d+[eE]?[-+]?%d*%%?$") ~= nil or s == "NaN" or s == "..." or s == "…"
end

---@param s string
---@param w integer
---@param right boolean
---@return string
local function fit(s, w, right)
  local sw = vim.api.nvim_strwidth(s)
  if sw > w then
    s = vim.fn.strcharpart(s, 0, w - 1) .. "…"
    sw = vim.api.nvim_strwidth(s)
  end
  local pad = string.rep(" ", math.max(0, w - sw))
  return right and (pad .. s) or (s .. pad)
end

---Render a parsed table to virtual-line chunks. Tables wider than `max_width`
---are split into several blocks of columns (index columns repeated in each),
---like pandas does when printing wide frames.
---@param t cellbook.HtmlTable
---@param max_cell integer max column width
---@param max_width integer? available display width (nil = unlimited)
---@return table[] lines
function M.render(t, max_cell, max_width)
  local ncol = 0
  for _, r in ipairs(t.header) do
    ncol = math.max(ncol, #r)
  end
  local nindex = 0
  for _, r in ipairs(t.body) do
    ncol = math.max(ncol, #r.cells)
    nindex = math.max(nindex, r.index)
  end
  local widths = {}
  for c = 1, ncol do
    widths[c] = 1
  end
  local function measure(cells)
    for c = 1, ncol do
      widths[c] = math.min(max_cell, math.max(widths[c], vim.api.nvim_strwidth(cells[c] or "")))
    end
  end
  for _, r in ipairs(t.header) do
    measure(r)
  end
  for _, r in ipairs(t.body) do
    measure(r.cells)
  end

  -- group columns into blocks that fit the width
  local blocks = {}
  local index_cols, data_cols = {}, {}
  for c = 1, ncol do
    if c <= nindex then
      index_cols[#index_cols + 1] = c
    else
      data_cols[#data_cols + 1] = c
    end
  end
  local function width_of(cols)
    local w = 1
    for _, c in ipairs(cols) do
      w = w + widths[c] + 3
    end
    return w
  end
  if not max_width or width_of(vim.list_extend(vim.list_extend({}, index_cols), data_cols)) <= max_width then
    blocks[1] = vim.list_extend(vim.list_extend({}, index_cols), data_cols)
  else
    local cur = vim.list_extend({}, index_cols)
    for _, c in ipairs(data_cols) do
      local trial = vim.list_extend(vim.list_extend({}, cur), { c })
      if width_of(trial) > max_width and #cur > #index_cols then
        blocks[#blocks + 1] = cur
        cur = vim.list_extend(vim.list_extend({}, index_cols), { c })
      else
        cur = trial
      end
    end
    blocks[#blocks + 1] = cur
  end

  local B = "CellbookTableBorder"
  local lines = {}
  for bi, cols in ipairs(blocks) do
    local function rule(l, m, r)
      local parts = {}
      for k, c in ipairs(cols) do
        parts[k] = string.rep("─", widths[c] + 2)
      end
      return { { l .. table.concat(parts, m) .. r, B } }
    end
    local function row(cells, group_of)
      local chunks = { { "│", B } }
      for _, c in ipairs(cols) do
        local s = cells[c] or ""
        chunks[#chunks + 1] = { " " .. fit(s, widths[c], numeric(s)) .. " ", group_of(c, s) }
        chunks[#chunks + 1] = { "│", B }
      end
      return chunks
    end
    if bi > 1 then
      lines[#lines + 1] = { { "", B } }
    end
    lines[#lines + 1] = rule("┌", "┬", "┐")
    for _, h in ipairs(t.header) do
      lines[#lines + 1] = row(h, function()
        return "CellbookTableHeader"
      end)
    end
    if #t.header > 0 then
      lines[#lines + 1] = rule("├", "┼", "┤")
    end
    for _, r in ipairs(t.body) do
      lines[#lines + 1] = row(r.cells, function(c)
        return c <= r.index and "CellbookTableIndex" or "CellbookOutput"
      end)
    end
    lines[#lines + 1] = rule("└", "┴", "┘")
  end
  local caption = t.caption
  if #blocks > 1 then
    caption = (caption and caption ~= "" and (caption .. " · ") or "")
      .. ("%d column blocks — <localleader>o for the full table"):format(#blocks)
  end
  if caption and caption ~= "" then
    lines[#lines + 1] = { { caption, "CellbookOutputTruncated" } }
  end
  return lines
end

return M
