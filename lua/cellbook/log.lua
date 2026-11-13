---In-memory log (bridge stderr, protocol logs, plugin errors). `:Cellbook log` shows it.
local M = {}

local MAX = 5000
---@type string[]
M.lines = {}
local bufnr ---@type integer?

local function append_to_buffer(lines)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].modified = false
  end
end

---@param level "debug"|"info"|"warn"|"error"
---@param msg string
---@param source string?
function M.add(level, msg, source)
  local prefix = ("%s [%s]%s "):format(os.date("%H:%M:%S"), level, source and (" " .. source) or "")
  local new = {}
  for _, l in ipairs(vim.split(msg, "\n", { plain = true })) do
    l = l:gsub("\r$", "")
    new[#new + 1] = prefix .. l
  end
  vim.list_extend(M.lines, new)
  if #M.lines > MAX then
    M.lines = vim.list_slice(M.lines, #M.lines - MAX + 1)
  end
  if vim.in_fast_event() then
    vim.schedule(function()
      append_to_buffer(new)
    end)
  else
    append_to_buffer(new)
  end
end

---Last n lines (for error messages).
---@param n integer
---@return string[]
function M.tail(n)
  return vim.list_slice(M.lines, math.max(1, #M.lines - n + 1))
end

function M.open()
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, "cellbook://log")
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].filetype = "cellbook_log"
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, #M.lines > 0 and M.lines or { "(log is empty)" })
  vim.bo[bufnr].modifiable = false
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.cmd("normal! G")
end

return M
