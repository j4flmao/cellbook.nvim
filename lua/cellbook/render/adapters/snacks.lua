---Image adapter for folke/snacks.nvim (`Snacks.image`).
---@type cellbook.RendererAdapter
local M = { name = "snacks" }

local function snacks()
  local ok, S = pcall(require, "snacks")
  if ok and type(S) == "table" and S.image then
    return S
  end
  return nil
end

function M.available()
  local S = snacks()
  if not S then
    return false, "snacks.nvim not installed"
  end
  if not (S.image.placement and S.image.placement.new) then
    return false, "snacks.nvim image module not available (update snacks.nvim)"
  end
  if S.image.supports_terminal and not S.image.supports_terminal() then
    return false, "terminal does not support the kitty graphics protocol"
  end
  return true
end

function M.supports(mime)
  if mime == "image/png" or mime == "image/jpeg" or mime == "image/gif" then
    return true
  end
  if mime == "image/svg+xml" then
    return vim.fn.executable("magick") == 1 or vim.fn.executable("convert") == 1
  end
  return false
end

function M.render(bufnr, row, file, opts)
  local S = snacks()
  if not S then
    return nil
  end
  return S.image.placement.new(bufnr, file, {
    pos = { row + 1, 0 },
    inline = true,
    max_width = opts.width,
    max_height = opts.height,
  })
end

function M.clear(handle)
  if handle and handle.close then
    handle:close()
  end
end

return M
