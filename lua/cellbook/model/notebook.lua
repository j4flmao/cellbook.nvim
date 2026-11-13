---Notebook entity and registry (bufnr → Notebook).
local M = {}

---@class cellbook.Notebook: cellbook.NotebookData
---@field bufnr integer
---@field path string
---@field filetype string
---@field readonly boolean
---@field session cellbook.KernelSession?
---@field mark_to_cell table<integer, cellbook.Cell>  every extmark ever created → cell (orphans revive on undo)
---@field ranges {cell: cellbook.Cell, start: integer, stop: integer}[]  last computed layout (0-based rows, inclusive)
---@field structure_sig string?
---@field detached boolean?

---@type table<integer, cellbook.Notebook>
M.registry = {}

---@param bufnr integer?
---@return cellbook.Notebook?
function M.get(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return M.registry[bufnr]
end

---@param nb cellbook.Notebook
function M.register(nb)
  M.registry[nb.bufnr] = nb
end

---@param bufnr integer
function M.unregister(bufnr)
  M.registry[bufnr] = nil
end

---@return cellbook.Notebook[]
function M.all()
  local out = {}
  for _, nb in pairs(M.registry) do
    out[#out + 1] = nb
  end
  return out
end

---Ids currently used in a notebook.
---@param nb cellbook.Notebook
---@return table<string, true>
function M.ids(nb)
  local ids = {}
  for _, c in pairs(nb.mark_to_cell or {}) do
    if c.id then
      ids[c.id] = true
    end
  end
  for _, c in ipairs(nb.cells or {}) do
    if c.id then
      ids[c.id] = true
    end
  end
  return ids
end

---Index of a cell in the current layout.
---@param nb cellbook.Notebook
---@param cell cellbook.Cell
---@return integer?
function M.index_of(nb, cell)
  for i, c in ipairs(nb.cells) do
    if c == cell then
      return i
    end
  end
  return nil
end

return M
