---Statusline / winbar component.
local M = {}

local state_icons = {
  none = "○",
  starting = "◌",
  idle = "●",
  busy = "◉",
  restarting = "◌",
  dead = "✗",
  shutdown = "○",
}

---@param bufnr integer?
---@return string e.g. " python3 ● idle  [3/12]"
function M.statusline(bufnr)
  local Notebook = require("cellbook.model.notebook")
  local nb = Notebook.get(bufnr or 0)
  if not nb then
    return ""
  end
  if nb.readonly then
    return " notebook (read-only)"
  end
  local s = nb.session
  local kname
  if s and s.kernel_name then
    kname = s.kernel_name
  else
    local ks = type(nb.metadata) == "table" and nb.metadata.kernelspec
    kname = type(ks) == "table" and ks.name or nb.language
  end
  local state = s and s.state or "none"
  if state == "none" then
    state = "no kernel"
  end
  local idx
  local tracker = require("cellbook.buffer.tracker")
  local win = tracker.win_for(nb.bufnr)
  if win then
    idx = tracker.index_at(nb, vim.api.nvim_win_get_cursor(win)[1] - 1)
  end
  local queued = s and #s.queue or 0
  return (" %s %s %s%s  [%s/%d]"):format(
    tostring(kname),
    state_icons[s and s.state or "none"] or "○",
    state,
    queued > 0 and (" +" .. queued) or "",
    idx and tostring(idx) or "-",
    #nb.cells
  )
end

return M
