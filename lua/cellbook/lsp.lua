---LSP integration: hide diagnostics on IPython magic / shell-escape lines and
---inside `%%` cell-magic cells (research R7), in notebook buffers only.
local M = {}

local wrapped = setmetatable({}, { __mode = "k" })

---Rows (0-based) whose diagnostics are hidden.
---@param nb cellbook.Notebook
---@return table<integer, true>
function M.hidden_rows(nb)
  local decor = require("cellbook.buffer.decor")
  local rows = {}
  local lines = vim.api.nvim_buf_get_lines(nb.bufnr, 0, -1, false)
  for _, r in ipairs(nb.ranges or {}) do
    rows[r.start] = true -- delimiter lines
    if r.cell.type == "code" then
      local first = lines[r.start + 2]
      if first and first:find("^%s*%%%%") then
        for row = r.start + 1, r.stop do
          rows[row] = true
        end
      else
        for row = r.start + 1, r.stop do
          local l = lines[row + 1]
          if l and decor.is_magic(l) then
            rows[row] = true
          end
        end
      end
    end
  end
  return rows
end

---@param bufnr integer
---@param diagnostics vim.Diagnostic[]
---@return vim.Diagnostic[]
function M.filter(bufnr, diagnostics)
  local nb = require("cellbook.model.notebook").get(bufnr)
  if not nb or nb.readonly then
    return diagnostics
  end
  if not require("cellbook.config").get(bufnr).lsp.filter_magic_diagnostics then
    return diagnostics
  end
  local rows = M.hidden_rows(nb)
  local out = {}
  for _, d in ipairs(diagnostics) do
    if not rows[d.lnum] then
      out[#out + 1] = d
    end
  end
  return out
end

---Wrap every registered diagnostic handler's `show` once.
function M.setup()
  for _, handler in pairs(vim.diagnostic.handlers) do
    if type(handler) == "table" and type(handler.show) == "function" and not wrapped[handler] then
      local orig = handler.show
      wrapped[handler] = orig
      handler.show = function(namespace, bufnr, diagnostics, opts)
        if require("cellbook.model.notebook").get(bufnr) then
          diagnostics = M.filter(bufnr, diagnostics)
        end
        return orig(namespace, bufnr, diagnostics, opts)
      end
    end
  end
end

---@param _ cellbook.Notebook
function M.attach(_)
  M.setup()
end

return M
