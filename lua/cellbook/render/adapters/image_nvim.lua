---Image adapter for 3rd/image.nvim.
---@type cellbook.RendererAdapter
local M = { name = "image.nvim" }

function M.available()
  if vim.fn.has("win32") == 1 then
    return false, "image.nvim does not support Windows (terminal size via ioctl)"
  end
  local ok, image = pcall(require, "image")
  if not ok or type(image) ~= "table" or not image.from_file then
    return false, "image.nvim not installed"
  end
  return true
end

function M.supports(mime)
  return mime == "image/png" or mime == "image/jpeg" or mime == "image/gif"
end

function M.render(bufnr, row, file, opts)
  local img = require("image").from_file(file, {
    window = opts.win,
    buffer = bufnr,
    x = 0,
    y = row + 1,
    width = opts.width,
    height = opts.height,
    with_virtual_padding = true,
    inline = true,
  })
  if img then
    img:render()
  end
  return img
end

function M.clear(handle)
  if handle and handle.clear then
    handle:clear()
  end
end

return M
