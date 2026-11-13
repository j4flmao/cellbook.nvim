---Placeholder fallback: images are shown as a text line
---`[image/png 640×480 — open with <localleader>o]` (drawn by render/text.lua)
---and opened with the system viewer (`vim.ui.open`).
---@type cellbook.RendererAdapter
local M = { name = "placeholder" }

function M.available()
  return true
end

function M.supports(_)
  return false
end

function M.render(_, _, file, _)
  return { file = file }
end

function M.clear(_) end

---Open an image file with the system viewer.
---@param file string
---@return vim.SystemObj? proc
---@return string? err
function M.open(file)
  return vim.ui.open(file)
end

return M
