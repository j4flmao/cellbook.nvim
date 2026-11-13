---Image outputs: adapter registry/selection, base64 → cache file, visible-range rendering.
local api = vim.api
local config = require("cellbook.config")
local outputs = require("cellbook.model.outputs")

local M = {}

---@class cellbook.RendererAdapter
---@field name string
---@field available fun(): boolean, string?
---@field supports fun(mime: string): boolean
---@field render fun(bufnr: integer, row: integer, file: string, opts: {width: integer?, height: integer?, win: integer}): any
---@field clear fun(handle: any)

---@type cellbook.RendererAdapter[]
M.user_adapters = {}

local builtin = {
  snacks = "cellbook.render.adapters.snacks",
  ["image.nvim"] = "cellbook.render.adapters.image_nvim",
  sixel = "cellbook.render.adapters.sixel",
}
local builtin_order = { "snacks", "image.nvim", "sixel" }

local ext = { ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/gif"] = "gif", ["image/svg+xml"] = "svg" }

local selected = {} ---@type table<string, cellbook.RendererAdapter|false>
local reasons = {} ---@type table<string, string?>

function M.reset()
  selected = {}
  reasons = {}
end

---@param adapter cellbook.RendererAdapter
function M.register(adapter)
  vim.validate("adapter", adapter, "table")
  vim.validate("adapter.name", adapter.name, "string")
  vim.validate("adapter.available", adapter.available, "function")
  vim.validate("adapter.supports", adapter.supports, "function")
  vim.validate("adapter.render", adapter.render, "function")
  vim.validate("adapter.clear", adapter.clear, "function")
  for i, a in ipairs(M.user_adapters) do
    if a.name == adapter.name then
      M.user_adapters[i] = adapter
      M.reset()
      return
    end
  end
  table.insert(M.user_adapters, adapter)
  M.reset()
end

---@param name string
---@return cellbook.RendererAdapter?
local function load_builtin(name)
  local ok, mod = pcall(require, builtin[name])
  return ok and mod or nil
end

---Selected adapter for a backend setting (`false` = placeholder only).
---@param backend string
---@return cellbook.RendererAdapter|false adapter
---@return string? reason why no adapter is available
function M.select(backend)
  if selected[backend] ~= nil then
    return selected[backend], reasons[backend]
  end
  local result, reason = false, nil
  if backend == "none" then
    reason = "image.backend = 'none'"
  elseif backend == "auto" then
    local candidates = vim.list_extend({}, M.user_adapters)
    for _, n in ipairs(builtin_order) do
      candidates[#candidates + 1] = load_builtin(n)
    end
    local why_list = {}
    for _, a in ipairs(candidates) do
      local ok, avail, why = pcall(a.available)
      if ok and avail then
        result = a
        break
      end
      why_list[#why_list + 1] = a.name .. ": " .. tostring(why or "unavailable")
    end
    if not result then
      reason = table.concat(why_list, "; ")
    end
  else
    local a
    for _, u in ipairs(M.user_adapters) do
      if u.name == backend then
        a = u
      end
    end
    a = a or (builtin[backend] and load_builtin(backend))
    if a then
      -- explicitly configured: adapters may skip terminal auto-detection
      local ok, avail, why = pcall(a.available, true)
      if ok and avail then
        result = a
      else
        reason = tostring(why or "unavailable")
      end
    else
      reason = "unknown backend " .. backend
    end
  end
  selected[backend] = result
  reasons[backend] = reason
  return result, reason
end

---@param nb cellbook.Notebook
---@return cellbook.RendererAdapter|false
local function adapter_for(nb)
  return (M.select(config.get(nb.bufnr).image.backend))
end

---Can the active backend display this MIME type?
---@param nb cellbook.Notebook
---@param mime string
---@return boolean
function M.supports(nb, mime)
  local a = adapter_for(nb)
  if not a then
    return false
  end
  local ok, res = pcall(a.supports, mime)
  return ok and res == true
end

---Will images of this MIME type be drawn by an adapter (instead of a placeholder)?
M.renders = M.supports

---@return string
function M.cache_dir()
  return vim.fs.joinpath(vim.fn.stdpath("cache"), "cellbook")
end

---Cache file path for an image (content-addressed by sha256 of the base64 data).
---@param data string
---@param mime string
---@return string
function M.cache_path(data, mime)
  return vim.fs.joinpath(M.cache_dir(), vim.fn.sha256(data) .. "." .. (ext[mime] or "bin"))
end

---Write the decoded image to the cache (async I/O) and call back with its path.
---@param out cellbook.Output
---@param mime string
---@param cb fun(path: string?, err: string?)
function M.ensure_file(out, mime, cb)
  local data = outputs.get(out, mime)
  if type(data) ~= "string" then
    return cb(nil, "no image data")
  end
  local path = M.cache_path(data, mime)
  if vim.uv.fs_stat(path) then
    return cb(path)
  end
  local bytes
  if mime == "image/svg+xml" then
    bytes = data
  else
    local ok, decoded = pcall(vim.base64.decode, (data:gsub("%s", "")))
    if not ok then
      return cb(nil, "invalid base64 image data")
    end
    bytes = decoded
  end
  vim.fn.mkdir(M.cache_dir(), "p")
  local tmp = path .. ".tmp" .. tostring(vim.uv.hrtime())
  local function done(p, err)
    vim.schedule(function()
      cb(p, err)
    end)
  end
  vim.uv.fs_open(tmp, "w", 420, function(oerr, fd)
    if oerr or not fd then
      return done(nil, oerr)
    end
    vim.uv.fs_write(fd, bytes, 0, function(werr)
      vim.uv.fs_close(fd, function()
        if werr then
          vim.uv.fs_unlink(tmp)
          return done(nil, werr)
        end
        vim.uv.fs_rename(tmp, path, function(rerr)
          if rerr then
            vim.uv.fs_unlink(tmp)
            -- another writer may have won the race
            if vim.uv.fs_stat(path) then
              return done(path)
            end
            return done(nil, rerr)
          end
          done(path)
        end)
      end)
    end)
  end)
end

---Image outputs of a cell that the backend will draw: list of {out, mime}.
---@param nb cellbook.Notebook
---@param cell cellbook.Cell
---@return {out: cellbook.Output, mime: string}[]
function M.image_outputs(nb, cell)
  local cfg = config.get(nb.bufnr)
  local list = {}
  for _, o in ipairs(cell.outputs) do
    if (o.type == "display_data" or o.type == "execute_result") and o.data then
      local mime = outputs.select_mime(o, cfg.output.mime_priority, function(m)
        return M.supports(nb, m)
      end)
      if mime and mime:sub(1, 6) == "image/" and M.supports(nb, mime) then
        list[#list + 1] = { out = o, mime = mime }
      end
    end
  end
  return list
end

---@param nb cellbook.Notebook
---@param cell cellbook.Cell
function M.clear_cell(nb, cell)
  local view = cell.view
  if not view then
    return
  end
  view.image_gen = (view.image_gen or 0) + 1
  view.images_pending = false
  local handles = view.images
  view.images = nil
  if not handles then
    return
  end
  local a = adapter_for(nb)
  for _, h in ipairs(handles) do
    if a then
      pcall(a.clear, h)
    end
  end
end

---First window that shows `row` (with one screen of margin).
---@param nb cellbook.Notebook
---@param row integer 0-based
---@return integer? win
local function visible_win(nb, row)
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(w) == nb.bufnr then
      -- nvim_win_call returns a single value
      local top = vim.fn.line("w0", w)
      local bot = vim.fn.line("w$", w)
      local margin = api.nvim_win_get_height(w)
      if row + 1 >= top - margin and row + 1 <= bot + margin then
        return w
      end
    end
  end
  return nil
end

---Render (or re-render) the images of a cell.
---@param nb cellbook.Notebook
---@param cell cellbook.Cell
---@param force boolean? re-render even if the image outputs did not change
function M.render_cell(nb, cell, force)
  local a = adapter_for(nb)
  if not a then
    return
  end
  local list = cell.collapsed_output and {} or M.image_outputs(nb, cell)
  local sig = {}
  for i, item in ipairs(list) do
    sig[i] = tostring(item.out) .. item.mime
  end
  sig = table.concat(sig, ",")
  local view = cell.view
  if not force and view and view.image_sig == sig and (view.images or view.images_pending or sig == "") then
    return -- unchanged (e.g. text streaming into the same cell)
  end
  M.clear_cell(nb, cell)
  cell.view = cell.view or {}
  cell.view.image_sig = sig
  if #list == 0 then
    return
  end
  local range
  for _, r in ipairs(nb.ranges) do
    if r.cell == cell then
      range = r
      break
    end
  end
  if not range then
    return
  end
  local cfg = config.get(nb.bufnr)
  cell.view = cell.view or {}
  local win = visible_win(nb, range.stop)
  if cfg.image.only_visible and not win then
    cell.view.images_pending = true
    return
  end
  win = win or require("cellbook.buffer.tracker").win_for(nb.bufnr)
  if not win then
    cell.view.images_pending = true
    return
  end
  cell.view.images = {}
  local generation = cell.view.image_gen
  for _, item in ipairs(list) do
    M.ensure_file(item.out, item.mime, function(path, err)
      if not path then
        require("cellbook.log").add("warn", "image cache: " .. tostring(err))
        return
      end
      if not cell.view or cell.view.image_gen ~= generation or not api.nvim_buf_is_valid(nb.bufnr) then
        return
      end
      local avail = 80
      if api.nvim_win_is_valid(win) then
        local textoff = (vim.fn.getwininfo(win)[1] or {}).textoff or 0
        avail = api.nvim_win_get_width(win) - textoff - (cfg.ui.cell_padding or 0) - 2
      end
      local width = math.min(cfg.image.max_width or avail, avail)
      local ok, handle = pcall(a.render, nb.bufnr, range.stop, path, {
        win = win,
        width = width,
        height = cfg.image.max_height,
      })
      if ok and handle then
        table.insert(cell.view.images, handle)
      elseif not ok then
        require("cellbook.log").add("error", ("image adapter %s: %s"):format(a.name, tostring(handle)))
      end
    end)
  end
end

---Render pending images that scrolled into view.
---@param nb cellbook.Notebook
function M.render_visible(nb)
  for _, c in ipairs(nb.cells) do
    if c.view and c.view.images_pending then
      M.render_cell(nb, c, true)
    end
  end
end

---@param nb cellbook.Notebook
---@param info table
function M.on_refresh(nb, info)
  for _, c in ipairs(info.removed or {}) do
    M.clear_cell(nb, c)
  end
  if not info.structure or not adapter_for(nb) then
    return
  end
  for _, c in ipairs(nb.cells) do
    if c.view and (c.view.images or c.view.images_pending) then
      M.render_cell(nb, c, true)
    end
  end
end

---Open the first image output of a cell with the system viewer.
---@param _ cellbook.Notebook
---@param cell cellbook.Cell
---@return boolean found
function M.open_external(_, cell)
  for _, o in ipairs(cell.outputs) do
    if o.data then
      for _, mime in ipairs({ "image/png", "image/jpeg", "image/gif", "image/svg+xml" }) do
        if o.data[mime] ~= nil then
          M.ensure_file(o, mime, function(path, err)
            if not path then
              vim.notify("cellbook: cannot open image: " .. tostring(err), vim.log.levels.ERROR)
              return
            end
            local _, oerr = require("cellbook.render.adapters.placeholder").open(path)
            if oerr then
              vim.notify("cellbook: " .. tostring(oerr), vim.log.levels.ERROR)
            end
          end)
          return true
        end
      end
    end
  end
  return false
end

return M
