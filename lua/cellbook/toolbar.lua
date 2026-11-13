---Notebook toolbar in the window bar (like VS Code's notebook toolbar):
---  + Code  + Markdown │ ▷ Run All  ↻ Restart  □ Interrupt  ✕ Clear All │ … ◉ Python 3.13 (.venv) · idle
---Every item is clickable; the kernel item opens "Select Kernel".
local M = {}

local EXPR = "%{%v:lua.require'cellbook.toolbar'.render()%}"

---@type {id: integer, label: string, icon: string, run: fun(bufnr: integer)}[]
M.buttons = {
  {
    id = 1,
    icon = "+",
    label = "Code",
    tiny = "Code",
    run = function(b)
      require("cellbook").add_cell(b, { where = "below", type = "code" })
    end,
  },
  {
    id = 2,
    icon = "+",
    label = "Markdown",
    tiny = "MD",
    run = function(b)
      require("cellbook").add_cell(b, { where = "below", type = "markdown" })
    end,
  },
  { id = 0, sep = true },
  {
    id = 3,
    icon = "▷",
    label = "Run All",
    tiny = "Run",
    run = function(b)
      require("cellbook").run_all(b)
    end,
  },
  {
    id = 4,
    icon = "↻",
    label = "Restart",
    run = function(b)
      require("cellbook").restart(b)
    end,
  },
  {
    id = 5,
    icon = "□",
    label = "Interrupt",
    short = "Stop",
    run = function(b)
      require("cellbook").interrupt(b)
    end,
  },
  {
    id = 6,
    icon = "✕",
    label = "Clear All Outputs",
    short = "Clear",
    run = function(b)
      require("cellbook").clear_output(b, { all = true })
    end,
  },
  { id = 0, sep = true },
  {
    id = 7,
    icon = "≡",
    label = "Outline",
    run = function(b)
      M.outline(b)
    end,
  },
}

local KERNEL_ID = 99

---Kernel label and state for the toolbar.
---@param nb cellbook.Notebook
---@return string label, string state
function M.kernel_label(nb)
  local s = nb.session
  local choice = require("cellbook.kernel.envs").get_choice(nb.path)
  local label
  if s and s.display_name then
    label = s.display_name
  elseif choice then
    label = choice.display_name
  else
    local ks = type(nb.metadata) == "table" and nb.metadata.kernelspec
    label = type(ks) == "table" and ks.display_name or nil
  end
  local state = s and s.state or "none"
  return label or "Select Kernel", state
end

local function esc(s)
  return (s:gsub("%%", "%%%%"))
end

---Winbar content for the window being drawn.
---@return string
function M.render()
  local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok then
    return ""
  end
  local nb = require("cellbook.model.notebook").get(buf)
  if not nb then
    return ""
  end
  if nb.readonly then
    return "%#CellbookToolbar#  notebook opened read-only (" .. esc(tostring(nb.readonly_reason)) .. ")"
  end
  local label, state = M.kernel_label(nb)
  local win_width = vim.api.nvim_win_get_width(win)
  local kernel_w = vim.api.nvim_strwidth(label) + #state + 12
  -- full labels when they fit, otherwise short labels, otherwise icons only
  local function buttons_width(mode)
    local w = 1
    for _, b in ipairs(M.buttons) do
      if b.sep then
        w = w + 2
      else
        local text = mode == "icons" and (b.tiny or "") or (mode == "short" and (b.short or b.label) or b.label)
        w = w + vim.api.nvim_strwidth(b.icon) + (text ~= "" and (1 + vim.api.nvim_strwidth(text)) or 0) + 2
      end
    end
    return w
  end
  local mode = "full"
  if buttons_width("full") + kernel_w > win_width then
    mode = buttons_width("short") + kernel_w <= win_width and "short" or "icons"
  end
  local parts = { "%#CellbookToolbar# " }
  for _, b in ipairs(M.buttons) do
    if b.sep then
      parts[#parts + 1] = "%#CellbookToolbarSep#│ "
    else
      local text = mode == "icons" and (b.tiny or "") or (mode == "short" and (b.short or b.label) or b.label)
      parts[#parts + 1] = ("%%%d@v:lua.CellbookToolbarClick@%%#CellbookToolbarIcon#%s%%#CellbookToolbarButton#%s%%X  "):format(
        b.id,
        b.icon,
        text ~= "" and (" " .. text) or ""
      )
    end
  end
  parts[#parts + 1] = "%#CellbookToolbar#%<%="
  local state_group, state_text = "CellbookToolbarIdle", state
  if state == "busy" or state == "starting" or state == "restarting" then
    state_group = "CellbookToolbarBusy"
  elseif state == "dead" then
    state_group = "CellbookToolbarDead"
  elseif state == "none" or state == "shutdown" then
    state_group, state_text = "CellbookToolbarKernel", "not started"
  end
  local queued = nb.session and #nb.session.queue or 0
  parts[#parts + 1] = ("%%%d@v:lua.CellbookToolbarClick@%%#CellbookToolbarKernel# ◉ %s %%#%s#● %s%s %%X "):format(
    KERNEL_ID,
    esc(label),
    state_group,
    state_text,
    queued > 0 and (" +" .. queued) or ""
  )
  return table.concat(parts)
end

---Click handler (called from the winbar).
---@param minwid integer
function M.click(minwid)
  local pos = vim.fn.getmousepos()
  local win = pos.winid ~= 0 and pos.winid or vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if minwid == KERNEL_ID then
    require("cellbook").select_kernel(buf)
    return
  end
  for _, b in ipairs(M.buttons) do
    if b.id == minwid and b.run then
      b.run(buf)
      return
    end
  end
end

---Show the toolbar in a notebook window.
---@param win integer
-- selene: allow(global_usage)
function M.attach(win)
  if not _G.CellbookToolbarClick then
    -- v:lua click handlers must be global functions
    _G.CellbookToolbarClick = function(minwid)
      require("cellbook.toolbar").click(minwid)
    end
  end
  vim.api.nvim_set_option_value("winbar", EXPR, { scope = "local", win = win })
end

---Refresh every window bar.
function M.redraw()
  pcall(vim.cmd, "redrawstatus!")
end

---Outline of the notebook (markdown headings + code cells) to jump to.
---@param bufnr integer
function M.outline(bufnr)
  local nb = require("cellbook.model.notebook").get(bufnr)
  if not nb or nb.readonly then
    return
  end
  local tracker = require("cellbook.buffer.tracker")
  tracker.flush(nb)
  local items = {}
  for i, r in ipairs(nb.ranges) do
    local src = tracker.source_of(nb, r)
    local first = src:match("[^\n]*") or ""
    local t = tracker.display_type(r.cell)
    if t == "markdown" then
      for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        local hashes, title = line:match("^(#+)%s+(.*)")
        if hashes then
          items[#items + 1] = { row = r.start + 1, text = string.rep("  ", #hashes - 1) .. title, idx = i }
        end
      end
    elseif t == "code" then
      local ec = r.cell.execution_count
      items[#items + 1] = {
        row = r.start + 1,
        text = ("  [%s] %s"):format((ec ~= nil and ec ~= vim.NIL) and tostring(ec) or " ", first),
        idx = i,
      }
    end
  end
  vim.ui.select(items, {
    prompt = "Notebook outline",
    format_item = function(it)
      return it.text
    end,
  }, function(it)
    if it then
      local win = tracker.win_for(nb.bufnr)
      if win then
        vim.api.nvim_win_set_cursor(win, { math.min(it.row + 1, vim.api.nvim_buf_line_count(nb.bufnr)), 0 })
      end
    end
  end)
end

return M
