---Images drawn with Unicode half blocks ("▀": foreground = upper pixel,
---background = lower pixel) in virtual lines. Works in any terminal with
---'termguicolors' — no graphics protocol needed. The bridge downsizes the image
---with Pillow (`render_image`); results are cached on the output.
local api = vim.api

local M = {}

local groups = {} ---@type table<string, true>

---Quantize a 0xRRGGBB colour (fewer highlight groups, same look).
---@param c integer
---@return integer
local function q(c)
  local r = math.floor(c / 65536) % 256
  local g = math.floor(c / 256) % 256
  local b = c % 256
  local function s(v)
    return math.min(255, math.floor(v / 8) * 8 + 4)
  end
  return s(r) * 65536 + s(g) * 256 + s(b)
end

---@param top integer
---@param bottom integer
---@return string group
local function group(top, bottom)
  local name = ("CellbookPx%06x%06x"):format(top, bottom)
  if not groups[name] then
    api.nvim_set_hl(0, name, { fg = top, bg = bottom })
    groups[name] = true
  end
  return name
end

---Forget cached groups (after :colorscheme / :hi clear).
function M.reset()
  groups = {}
end

---Character for a 2x3 sextant pattern (bit i = sub-pixel i, row-major).
---@param n integer 0..63
---@return string
function M.sextant_char(n)
  if n == 0 then
    return " "
  elseif n == 63 then
    return "█"
  elseif n == 21 then
    return "▌"
  elseif n == 42 then
    return "▐"
  end
  local idx = n - 1 - (n > 21 and 1 or 0) - (n > 42 and 1 or 0)
  return vim.fn.nr2char(0x1FB00 + idx)
end

---Build virtual lines from a `render_image` result ("half" or "sextant" mode).
---@param res {rows: integer[][][], width: integer, height: integer, cols: integer, mode: string?}
---@return table[] lines
function M.build(res)
  local sext = res.mode == "sextant"
  local lines = {}
  for _, row in ipairs(res.rows or {}) do
    local chunks = {}
    local cur_group, cur_text = nil, {}
    for _, px in ipairs(row) do
      local g, ch
      if sext then
        local fg, bg = q(px[2]), q(px[3])
        ch = M.sextant_char(px[1])
        g = group(px[1] == 0 and bg or fg, bg)
      else
        g, ch = group(q(px[1]), q(px[2])), "▀"
      end
      if g ~= cur_group then
        if cur_group then
          chunks[#chunks + 1] = { table.concat(cur_text), cur_group }
        end
        cur_group, cur_text = g, {}
      end
      cur_text[#cur_text + 1] = ch
    end
    if cur_group then
      chunks[#chunks + 1] = { table.concat(cur_text), cur_group }
    end
    lines[#lines + 1] = chunks
  end
  return lines
end

---Background colour used to flatten transparent images.
---@return integer[]? rgb
local function background()
  local ok, n = pcall(api.nvim_get_hl, 0, { name = "Normal", link = false })
  local bg = ok and n.bg or nil
  if not bg then
    return nil -- white, like Jupyter
  end
  return { math.floor(bg / 65536) % 256, math.floor(bg / 256) % 256, bg % 256 }
end

---Lines for an image output, or nil while rendering / when unavailable.
---Starts the render in the background and re-renders the cell when done.
---@param nb cellbook.Notebook
---@param cell cellbook.Cell
---@param out cellbook.Output
---@param mime string
---@param cols integer
---@param max_rows integer
---@return table[]? lines
---@return {pending: boolean?, failed: string?}? state
---@param mode "half"|"sextant"?
function M.lines(nb, cell, out, mime, cols, max_rows, mode)
  mode = mode or "sextant"
  if not vim.o.termguicolors then
    return nil, { failed = "'termguicolors' is off" }
  end
  if mime ~= "image/png" and mime ~= "image/jpeg" and mime ~= "image/gif" then
    return nil, { failed = "unsupported" }
  end
  local key = cols .. "x" .. max_rows .. mode
  local cache = out.blocks
  if cache and cache.key == key then
    return cache.lines, cache
  end
  local data = require("cellbook.model.outputs").get(out, mime)
  if type(data) ~= "string" then
    return nil, { failed = "no data" }
  end
  cache = { key = key, pending = true }
  out.blocks = cache
  local session = require("cellbook.kernel.session").get_or_create(nb)
  session:with_bridge(function(ok, err)
    if not ok then
      cache.pending, cache.failed = false, tostring(err)
      return
    end
    session.bridge:request("render_image", {
      data = data,
      cols = cols,
      max_rows = max_rows,
      mode = mode,
      background = background(),
    }, function(res, rerr)
      cache.pending = false
      if rerr then
        cache.failed = rerr.message or rerr.code
        require("cellbook.log").add("warn", "render_image: " .. tostring(cache.failed))
      else
        cache.lines = M.build(res)
        cache.size = ("%d×%d"):format(res.width or 0, res.height or 0)
      end
      if out.blocks == cache and api.nvim_buf_is_valid(nb.bufnr) then
        require("cellbook.render.text").render(nb, cell)
      end
    end, 60000)
  end)
  return nil, cache
end

return M
