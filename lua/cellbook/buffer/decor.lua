---Cell decorations (VS Code-like):
--- * code cells are "cards": a tinted background over the delimiter line and the
---   code, a header `▶ [3]  …  0.4s  Python` drawn over the delimiter text;
--- * markdown cells are rendered (heading marks, emphasis markers, backticks and
---   link targets concealed, bullets drawn) unless the cursor is inside the cell,
---   which shows the raw markdown for editing;
--- * magic lines highlighted; spinner for running cells.
local api = vim.api
local config = require("cellbook.config")
local tracker = require("cellbook.buffer.tracker")

local M = {}

M.ns_md = api.nvim_create_namespace("cellbook.markdown")
M.ns_hdr = api.nvim_create_namespace("cellbook.header")

-- highlights ------------------------------------------------------------------------

---@param name string
---@return table
local function hl(name)
  local ok, v = pcall(api.nvim_get_hl, 0, { name = name, link = false })
  return ok and v or {}
end

---Blend two 0xRRGGBB colours (`t` = weight of `b`).
---@param a integer
---@param b integer
---@param t number
---@return integer
function M.blend(a, b, t)
  local function ch(c, s)
    return math.floor(c / s) % 256
  end
  local r = math.floor(ch(a, 65536) * (1 - t) + ch(b, 65536) * t + 0.5)
  local g = math.floor(ch(a, 256) * (1 - t) + ch(b, 256) * t + 0.5)
  local bl = math.floor(ch(a, 1) * (1 - t) + ch(b, 1) * t + 0.5)
  return r * 65536 + g * 256 + bl
end

---Groups that link to existing ones (users/colorschemes may override).
M.links = {
  CellbookOutput = "Normal",
  CellbookOutputStderr = "DiagnosticWarn",
  CellbookOutputError = "DiagnosticError",
  CellbookOutputTruncated = "NonText",
  CellbookMagic = "PreProc",
  CellbookRaw = "Comment",
  CellbookCellBorder = "WinSeparator",
  CellbookCellHeaderMarkdown = "Title",
}

---Computed groups (derived from the colorscheme; recomputed on :colorscheme).
---@return table<string, table>
function M.computed()
  local normal = hl("Normal")
  local fg = normal.fg or hl("NormalFloat").fg or 0xc0caf5
  local bg = normal.bg
    or hl("NormalFloat").bg
    or hl("Pmenu").bg
    or (vim.o.background == "light" and 0xffffff or 0x1a1b26)
  local card = M.blend(bg, fg, 0.06)
  local code_bg = M.blend(bg, fg, 0.12)
  local dim = hl("Comment").fg or M.blend(bg, fg, 0.45)
  local function c(name, fallback)
    return hl(name).fg or fallback
  end
  local ok_c = c("DiagnosticOk", 0x9ece6a)
  local warn_c = c("DiagnosticWarn", 0xe0af68)
  local err_c = c("DiagnosticError", 0xf7768e)
  local info_c = c("DiagnosticInfo", 0x7dcfff)
  local title = c("Title", c("Function", info_c))
  local h2 = c("Function", title)
  local h3 = c("Type", h2)
  local link = c("Underlined", info_c)
  local str = c("String", ok_c)
  local special = c("Special", info_c)
  local wb = hl("WinBar")
  local wbg = wb.bg or bg
  return {
    CellbookCellBg = { bg = card },
    CellbookCellPad = { bg = card },
    CellbookCellHeader = { fg = dim, bg = card },
    CellbookCellCount = { fg = dim, bg = card, bold = true },
    CellbookRunIcon = { fg = info_c, bg = card },
    CellbookLang = { fg = dim, bg = card, italic = true },
    CellbookRunning = { fg = warn_c, bg = card },
    CellbookDone = { fg = ok_c, bg = card },
    CellbookError = { fg = err_c, bg = card },
    CellbookStale = { fg = dim, bg = card, italic = true },
    CellbookMarkdown = { fg = fg, nocombine = true },
    CellbookMdH1 = { fg = title, bold = true, nocombine = true },
    CellbookMdH2 = { fg = h2, bold = true, nocombine = true },
    CellbookMdH3 = { fg = h3, bold = true, nocombine = true },
    CellbookMdRule = { fg = M.blend(bg, title, 0.5) },
    CellbookMdCode = { fg = str, bg = code_bg, nocombine = true },
    CellbookMdCodeBlock = { bg = code_bg },
    CellbookMdBold = { bold = true },
    CellbookMdItalic = { italic = true },
    CellbookMdLink = { fg = link, underline = true },
    CellbookMdBullet = { fg = special, bold = true },
    CellbookMdQuote = { fg = dim, italic = true },
    CellbookOutputGutter = { fg = M.blend(bg, fg, 0.25) },
    CellbookOutputGutterError = { fg = err_c },
    CellbookTableBorder = { fg = M.blend(bg, fg, 0.30) },
    CellbookTableHeader = { fg = fg, bold = true },
    CellbookTableIndex = { fg = dim, bold = true },
    CellbookToolbar = { fg = dim, bg = wbg },
    CellbookToolbarButton = { fg = fg, bg = wbg },
    CellbookToolbarIcon = { fg = info_c, bg = wbg },
    CellbookToolbarSep = { fg = M.blend(wbg, fg, 0.25), bg = wbg },
    CellbookToolbarKernel = { fg = fg, bg = M.blend(wbg, fg, 0.10), bold = true },
    CellbookToolbarIdle = { fg = ok_c, bg = M.blend(wbg, fg, 0.10) },
    CellbookToolbarBusy = { fg = warn_c, bg = M.blend(wbg, fg, 0.10) },
    CellbookToolbarDead = { fg = err_c, bg = M.blend(wbg, fg, 0.10) },
  }
end

---@type table<string, table>
local applied = {}

function M.setup_highlights()
  for name, target in pairs(M.links) do
    api.nvim_set_hl(0, name, { link = target, default = true })
  end
  for name, spec in pairs(M.computed()) do
    -- keep user/colorscheme overrides: only (re)define groups we own
    local cur = hl(name)
    if vim.tbl_isempty(cur) or vim.deep_equal(cur, applied[name]) then
      api.nvim_set_hl(0, name, spec)
      applied[name] = hl(name)
    end
  end
end

-- header --------------------------------------------------------------------------

---@param ms number
---@return string
local function fmt_duration(ms)
  if ms < 1000 then
    return ("%dms"):format(ms)
  elseif ms < 60000 then
    return ("%.1fs"):format(ms / 1000)
  end
  return ("%dm%02ds"):format(math.floor(ms / 60000), math.floor(ms / 1000) % 60)
end
M.fmt_duration = fmt_duration

local spinner_frame = 1

---@param cell cellbook.Cell
local function is_stale(cell)
  return cell.run_source ~= nil and cell.snapshot ~= nil and cell.run_source ~= cell.snapshot
end

local lang_names = {
  python = "Python",
  r = "R",
  julia = "Julia",
  javascript = "JavaScript",
  typescript = "TypeScript",
  rust = "Rust",
  go = "Go",
  lua = "Lua",
  cpp = "C++",
  c = "C",
  sh = "Bash",
}

---Left and right header chunks of a code cell.
---@param nb cellbook.Notebook
---@param cell cellbook.Cell
---@return table[] left, table[] right
function M.code_header(nb, cell)
  local ui = config.get(nb.bufnr).ui
  local icons = ui.icons
  local left, right = { { " ", "CellbookCellHeader" } }, {}
  local state = cell.run_state
  local ec = cell.execution_count
  local count = (ec ~= nil and ec ~= vim.NIL) and ("[" .. tostring(ec) .. "]") or "[ ]"
  local elapsed
  if state == "running" then
    left[#left + 1] = { (ui.spinner[spinner_frame] or icons.running), "CellbookRunning" }
    left[#left + 1] = { " " .. count, "CellbookCellCount" }
    left[#left + 1] = { "  Running…", "CellbookRunning" }
    elapsed = cell.run_started_at and (vim.uv.hrtime() - cell.run_started_at) / 1e6 or 0
  elseif state == "queued" then
    left[#left + 1] = { icons.queued, "CellbookRunning" }
    left[#left + 1] = { " " .. count, "CellbookCellCount" }
    left[#left + 1] = { "  Queued", "CellbookRunning" }
  else
    local icon, group = "▶", "CellbookRunIcon"
    if state == "done" then
      icon, group = icons.done, "CellbookDone"
    elseif state == "error" then
      icon, group = icons.error, "CellbookError"
    elseif state == "interrupted" or state == "cancelled" then
      icon, group = icons.interrupted, "CellbookStale"
    end
    left[#left + 1] = { icon, group }
    left[#left + 1] = { " " .. count, "CellbookCellCount" }
    if state == "error" then
      left[#left + 1] = { "  Error", "CellbookError" }
    elseif state == "interrupted" then
      left[#left + 1] = { "  Interrupted", "CellbookStale" }
    elseif state == "cancelled" then
      left[#left + 1] = { "  Cancelled", "CellbookStale" }
    end
    if (state == "done" or state == "error") and is_stale(cell) then
      left[#left + 1] = { "  • edited", "CellbookStale" }
    end
    elapsed = (state == "done" or state == "error") and cell.run_duration_ms or nil
  end
  if cell.collapsed_output and #cell.outputs > 0 then
    left[#left + 1] = {
      ("  (%d output%s hidden)"):format(#cell.outputs, #cell.outputs == 1 and "" or "s"),
      "CellbookStale",
    }
  end
  if elapsed and ui.show_execution_time then
    right[#right + 1] = {
      fmt_duration(elapsed) .. "  ",
      state == "error" and "CellbookError" or (state == "running" and "CellbookRunning" or "CellbookDone"),
    }
  end
  right[#right + 1] = { (lang_names[nb.filetype] or nb.filetype or "code") .. " ", "CellbookLang" }
  return left, right
end

---@param chunks table[]
---@return integer
local function width(chunks)
  local w = 0
  for _, ch in ipairs(chunks) do
    w = w + api.nvim_strwidth(ch[1])
  end
  return w
end

---Draw the header of one cell on its tracking extmark.
---@param nb cellbook.Notebook
---@param r {cell: cellbook.Cell, start: integer, stop: integer}
---@param _ integer? index (unused, kept for callers)
function M.header(nb, r, _)
  local cfg = config.get(nb.bufnr)
  local cell = r.cell
  if not cell.mark then
    return
  end
  local buf = nb.bufnr
  local line = api.nvim_buf_get_lines(buf, r.start, r.start + 1, false)[1] or ""
  local lw = api.nvim_strwidth(line)
  local t = tracker.display_type(cell)
  local opts = { id = cell.mark, invalidate = true, undo_restore = true, right_gravity = true }
  api.nvim_buf_clear_namespace(buf, M.ns_hdr, r.start, r.start + 1)
  if cfg.ui.cell_header then
    local left, right
    if t == "code" then
      left, right = M.code_header(nb, cell)
      opts.line_hl_group = "CellbookCellBg"
      local pad = math.max(0, lw - width(left))
      left[#left + 1] = { string.rep(" ", pad), "CellbookCellHeader" }
    elseif t == "markdown" then
      -- the delimiter of a markdown cell is drawn as an empty spacer line
      left = { { string.rep(" ", lw), "Normal" } }
    else
      left = { { " raw" .. string.rep(" ", math.max(0, lw - 4)), "CellbookRaw" } }
    end
    opts.virt_text = left
    opts.virt_text_pos = "overlay"
    opts.hl_mode = "replace"
    opts.priority = 200
    if right and #right > 0 then
      pcall(api.nvim_buf_set_extmark, buf, M.ns_hdr, r.start, 0, {
        virt_text = right,
        virt_text_pos = "right_align",
        hl_mode = "replace",
        priority = 200,
      })
    end
  end
  pcall(api.nvim_buf_set_extmark, buf, tracker.ns, r.start, 0, opts)
end

-- body ----------------------------------------------------------------------------

local magic_patterns = { "^%s*%%", "^%s*!", "^%s*%?", "%?%??%s*$" }

---@param line string
---@return boolean
function M.is_magic(line)
  for _, p in ipairs(magic_patterns) do
    if line:find(p) then
      if p == "%?%??%s*$" then
        return not line:find("^%s*#") and line:find("[%w_%)%]]%?%??%s*$") ~= nil
      end
      return true
    end
  end
  return false
end

---@param buf integer
---@param row integer
---@param col integer
---@param end_col integer
---@param opts table
local function mark(buf, row, col, end_col, opts)
  opts.end_col = end_col
  pcall(api.nvim_buf_set_extmark, buf, M.ns_md, row, col, opts)
end

---Inline markdown: code spans, bold, italic, links (offsets are byte columns).
---@param buf integer
---@param row integer
---@param text string content without the comment prefix
---@param off integer byte offset of `text` in the line
local function render_inline(buf, row, text, off)
  local taken = {}
  local function free(s, e)
    for i = s, e do
      if taken[i] then
        return false
      end
    end
    for i = s, e do
      taken[i] = true
    end
    return true
  end
  -- `code`
  local pos = 1
  while true do
    local s, e = text:find("`[^`]+`", pos)
    if not s then
      break
    end
    if free(s, e) then
      mark(buf, row, off + s - 1, off + s, { conceal = "", priority = 210 })
      mark(buf, row, off + e - 1, off + e, { conceal = "", priority = 210 })
      mark(buf, row, off + s, off + e - 1, { hl_group = "CellbookMdCode", priority = 170 })
    end
    pos = e + 1
  end
  -- [text](url)
  pos = 1
  while true do
    local s, ms, e = text:find("%[[^%]]-%]()%([^%)]-%)", pos)
    if not s then
      break
    end
    if free(s, e) then
      mark(buf, row, off + s - 1, off + s, { conceal = "", priority = 210 })
      mark(buf, row, off + ms - 2, off + e, { conceal = "", priority = 210 })
      mark(buf, row, off + s, off + ms - 2, { hl_group = "CellbookMdLink", priority = 170 })
    end
    pos = e + 1
  end
  -- **bold** / __bold__ then *italic* / _italic_
  for _, spec in ipairs({
    { "%*%*[^%*]+%*%*", 2, "CellbookMdBold" },
    { "__[^_]+__", 2, "CellbookMdBold" },
    { "%*[^%*%s][^%*]-%*", 1, "CellbookMdItalic" },
    { "%f[%w_]_[^_%s][^_]-_%f[^%w_]", 1, "CellbookMdItalic" },
  }) do
    pos = 1
    while true do
      local s, e = text:find(spec[1], pos)
      if not s then
        break
      end
      local n = spec[2]
      if free(s, e) then
        mark(buf, row, off + s - 1, off + s - 1 + n, { conceal = "", priority = 210 })
        mark(buf, row, off + e - n, off + e, { conceal = "", priority = 210 })
        mark(buf, row, off + s - 1 + n, off + e - n, { hl_group = spec[3], priority = 165 })
      end
      pos = e + 1
    end
  end
end

---Markdown / raw cell body.
---@param nb cellbook.Notebook
---@param r {cell: cellbook.Cell, start: integer, stop: integer}
---@param lines string[]
---@param rendered boolean
local function markdown_body(nb, r, lines, rendered)
  local buf = nb.bufnr
  local cfg = config.get(buf)
  local c = nb.comment
  local plen = #c + 1
  local t = tracker.display_type(r.cell)
  local base = t == "markdown" and "CellbookMarkdown" or "CellbookRaw"
  local in_fence = false
  for i, l in ipairs(lines) do
    local row = r.start + i
    local has_prefix = l == c or l:sub(1, plen) == c .. " "
    local off = has_prefix and math.min(plen, #l) or 0
    if has_prefix and cfg.ui.conceal_comment_prefix then
      mark(buf, row, 0, off, { conceal = "", priority = 200 })
    end
    local text = l:sub(off + 1)
    if #text > 0 then
      mark(buf, row, off, #l, { hl_group = base, priority = 150 })
    end
    if t == "markdown" and rendered then
      local fence = text:match("^%s*```") or text:match("^%s*~~~")
      if fence or in_fence then
        mark(buf, row, 0, 0, { line_hl_group = "CellbookMdCodeBlock", priority = 140 })
        if fence then
          in_fence = not in_fence
        end
      else
        local hashes, rest = text:match("^(#+)%s+()")
        if hashes and #hashes <= 6 then
          local level = math.min(#hashes, 3)
          mark(buf, row, off, off + rest - 1, { conceal = "", priority = 210 })
          mark(buf, row, off + rest - 1, #l, { hl_group = "CellbookMdH" .. level, priority = 170 })
          if #hashes <= 2 then
            local w = api.nvim_strwidth(text:sub(rest))
            mark(buf, row, 0, 0, {
              virt_lines = { { { string.rep(#hashes == 1 and "━" or "─", math.max(w, 3)), "CellbookMdRule" } } },
              priority = 100,
            })
          end
          render_inline(buf, row, text:sub(rest), off + rest - 1)
        elseif text:match("^%s*[-*_]%s*[-*_]%s*[-*_][-*_%s]*$") then
          mark(buf, row, off, #l, {
            virt_text = { { string.rep("─", 60), "CellbookMdRule" } },
            virt_text_pos = "overlay",
            priority = 210,
          })
        else
          local bullet = text:match("^%s*()[-*+]%s")
          if bullet then
            mark(buf, row, off + bullet - 1, off + bullet, { conceal = "•", priority = 210 })
            mark(buf, row, off + bullet - 1, off + bullet, { hl_group = "CellbookMdBullet", priority = 175 })
          end
          local q = text:match("^()>%s?")
          if q then
            mark(buf, row, off, off + 1, { conceal = "▎", priority = 210 })
            mark(buf, row, off, #l, { hl_group = "CellbookMdQuote", priority = 160 })
          end
          render_inline(buf, row, text, off)
        end
      end
    end
  end
end

---Body decorations of one cell.
---@param nb cellbook.Notebook
---@param r {cell: cellbook.Cell, start: integer, stop: integer}
function M.body(nb, r)
  local buf = nb.bufnr
  local first, last = r.start + 1, r.stop
  api.nvim_buf_clear_namespace(buf, M.ns_md, r.start, r.stop + 1)
  if last < first then
    return
  end
  local cfg = config.get(buf)
  local t = tracker.display_type(r.cell)
  local lines = api.nvim_buf_get_lines(buf, first, last + 1, false)
  if t == "code" then
    local cell_magic = lines[1] and lines[1]:find("^%s*%%%%") ~= nil
    for i, l in ipairs(lines) do
      local row = first + i - 1
      local opts = { line_hl_group = cfg.ui.cell_header and "CellbookCellBg" or nil, priority = 50 }
      if cfg.ui.cell_padding > 0 then
        opts.virt_text = { { string.rep(" ", cfg.ui.cell_padding), "CellbookCellPad" } }
        opts.virt_text_pos = "inline"
        opts.right_gravity = false
      end
      pcall(api.nvim_buf_set_extmark, buf, M.ns_md, row, 0, opts)
      if (cell_magic and i == 1) or (not cell_magic and M.is_magic(l)) then
        mark(buf, row, 0, #l, { hl_group = "CellbookMagic", priority = 150 })
      end
    end
    return
  end
  local editing = nb.md_editing == r.cell
  markdown_body(nb, r, lines, cfg.ui.render_markdown and not editing)
end

---Redraw everything.
---@param nb cellbook.Notebook
function M.full(nb)
  api.nvim_buf_clear_namespace(nb.bufnr, M.ns_md, 0, -1)
  api.nvim_buf_clear_namespace(nb.bufnr, M.ns_hdr, 0, -1)
  for i, r in ipairs(nb.ranges) do
    M.header(nb, r, i)
    M.body(nb, r)
  end
end

---Redraw the header of one cell (after a state change).
---@param nb cellbook.Notebook
---@param cell cellbook.Cell
function M.update_cell(nb, cell)
  for i, r in ipairs(nb.ranges) do
    if r.cell == cell then
      M.header(nb, r, i)
      return
    end
  end
end

---@param nb cellbook.Notebook
---@param info table
function M.on_refresh(nb, info)
  if info.structure then
    M.full(nb)
    return
  end
  for _, r in ipairs(info.dirty or {}) do
    M.header(nb, r)
    M.body(nb, r)
  end
end

---Insert mode in a markdown cell shows its raw text; other cells stay rendered.
---@param nb cellbook.Notebook
---@param row integer 0-based cursor row
---@param inserting boolean
function M.on_cursor(nb, row, inserting)
  if not config.get(nb.bufnr).ui.render_markdown then
    return
  end
  local _, r = tracker.index_at(nb, row)
  local cell = inserting and r and tracker.display_type(r.cell) == "markdown" and r.cell or nil
  if cell == nb.md_editing then
    return
  end
  local prev = nb.md_editing
  nb.md_editing = cell
  for _, rr in ipairs(nb.ranges) do
    if rr.cell == prev or rr.cell == cell then
      M.body(nb, rr)
    end
  end
end

-- spinner ------------------------------------------------------------------------

local timer ---@type uv.uv_timer_t?

local function any_running()
  for _, nb in ipairs(require("cellbook.model.notebook").all()) do
    for _, c in ipairs(nb.cells or {}) do
      if c.run_state == "running" then
        return true
      end
    end
  end
  return false
end

function M.start_spinner()
  if timer then
    return
  end
  timer = vim.uv.new_timer()
  timer:start(
    100,
    100,
    vim.schedule_wrap(function()
      if not any_running() then
        if timer then
          timer:stop()
          timer:close()
          timer = nil
        end
        return
      end
      spinner_frame = spinner_frame % #config.values.ui.spinner + 1
      for _, nb in ipairs(require("cellbook.model.notebook").all()) do
        for i, r in ipairs(nb.ranges or {}) do
          if r.cell.run_state == "running" then
            M.header(nb, r, i)
          end
        end
      end
    end)
  )
end

---Window-local options for notebook windows.
---@param win integer
function M.setup_window(win)
  local buf = api.nvim_win_get_buf(win)
  local cfg = config.get(buf)
  if cfg.ui.conceal_comment_prefix or cfg.ui.render_markdown then
    api.nvim_set_option_value("conceallevel", 2, { scope = "local", win = win })
    api.nvim_set_option_value("concealcursor", "", { scope = "local", win = win })
  end
  if cfg.ui.toolbar then
    require("cellbook.toolbar").attach(win)
  end
end

return M
