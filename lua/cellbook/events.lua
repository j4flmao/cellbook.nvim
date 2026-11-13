---User autocommand emitters (`:h cellbook-events`).
local M = {}

---@param pattern "CellbookAttached"|"CellbookKernelStarted"|"CellbookKernelStateChanged"|"CellbookCellExecuted"|"CellbookSaved"
---@param data table
function M.emit(pattern, data)
  vim.schedule(function()
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = pattern, data = data, modeline = false })
  end)
end

return M
