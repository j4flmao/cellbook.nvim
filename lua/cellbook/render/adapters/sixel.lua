---Sixel image adapter (Windows Terminal >= 1.22, WezTerm, foot, mlterm, xterm -ti vt340).
---
---Each image is encoded once with ImageMagick (`magick in.png -resize WxH sixel:-`,
---argv only, no shell). Sixel data is a palette followed by 6-pixel bands
---separated by "-", so an image that is only partly on screen is drawn by sending
---just the visible bands (no re-encoding, no gaps). The adapter reserves blank
---virtual lines under the cell. While scrolling the terminal moves the pixels
---with the text; visible parts are repainted once scrolling settles. A full
---refresh (`:mode`) only happens when images are removed or windows change.
local api = vim.api
local is_windows = vim.fn.has("win32") == 1

---@type cellbook.RendererAdapter
local M = { name = "sixel" }

M.ns = api.nvim_create_namespace("cellbook.sixel")

---@class cellbook.SixelPlacement
---@field id integer
---@field buf integer
---@field mark integer
---@field file string
---@field cols integer
---@field rows integer
---@field img cellbook.SixelImage?   parsed sixel, no shift (nil while encoding)
---@field variants table<integer, cellbook.SixelImage>?  encodings with the top 0..5 px removed
---@field pending table<integer, boolean>?

---@class cellbook.SixelImage
---@field header string   palette definitions
---@field bands string[]  6-pixel bands
---@field width integer
---@field height integer

---@type table<integer, cellbook.SixelPlacement>
local placements = {}
local next_id = 0
local cache = {} ---@type table<string, cellbook.SixelImage>

-- terminal cell size in pixels -------------------------------------------------------
-- Windows: measured from the Windows Terminal window (client size / Neovim grid),
-- re-measured on resize. Elsewhere: 8x16 fallback; override with image.cell_size.

local cell = { w = 8, h = 16, known = false }
local measured_for = nil ---@type string?

local measure_cell -- defined after the console helpers

---@return {w: integer, h: integer, known: boolean}
function M.cell_size()
  local cfg = require("cellbook.config").values.image
  if type(cfg.cell_size) == "table" and cfg.cell_size[1] and cfg.cell_size[2] then
    return { w = cfg.cell_size[1], h = cfg.cell_size[2], known = true }
  end
  if is_windows and measure_cell then
    local ui = api.nvim_list_uis()[1]
    local key = ui and (ui.width .. "x" .. ui.height) or nil
    if key and key ~= measured_for then
      measured_for = key
      local ok, w, h = pcall(measure_cell, ui.width, ui.height)
      if ok and w then
        cell = { w = w, h = h, known = true }
        require("cellbook.log").add("info", ("sixel: terminal cell %dx%d px (measured)"):format(w, h))
      end
    end
  end
  return cell
end

-- output path -------------------------------------------------------------------------
-- Unix: the `nvim --embed` server inherits the terminal as stderr.
-- Windows: the server's stderr does not reach the terminal (the TUI is a separate
-- process). Attach to the TUI process's console for the duration of the write and
-- write to CONOUT$ directly; ConPTY passes the sixel data on to the terminal.

local win_ok = nil ---@type boolean? nil = not tried yet
local ffi_ready = false

---@param s string
---@return boolean ok, string? err
local function win_console_write(s)
  local ok_ffi, ffi = pcall(require, "ffi")
  if not ok_ffi then
    return false, "LuaJIT FFI unavailable"
  end
  if not ffi_ready then
    ffi.cdef([[
      int FreeConsole(void);
      int AttachConsole(unsigned long dwProcessId);
      void* CreateFileW(const uint16_t* name, unsigned long access, unsigned long share, void* sec,
                        unsigned long disposition, unsigned long flags, void* tmpl);
      int WriteFile(void* h, const void* buf, unsigned long n, unsigned long* written, void* ov);
      int CloseHandle(void* h);
      unsigned long GetLastError(void);
    ]])
    ffi_ready = true
  end
  local k = ffi.C
  local ppid = vim.uv.os_getppid()
  if not ppid then
    return false, "no parent process"
  end
  k.FreeConsole()
  if k.AttachConsole(ppid) == 0 then
    return false, ("AttachConsole(%d) failed: %d"):format(ppid, tonumber(k.GetLastError()))
  end
  local name = ffi.new("uint16_t[8]", { 67, 79, 78, 79, 85, 84, 36, 0 }) -- "CONOUT$"
  local h = k.CreateFileW(name, 0xC0000000, 3, nil, 3, 0, nil) -- RW, share RW, OPEN_EXISTING
  if h == nil or ffi.cast("intptr_t", h) == -1 then
    local err = tonumber(k.GetLastError())
    k.FreeConsole()
    return false, "CreateFileW(CONOUT$) failed: " .. tostring(err)
  end
  local written = ffi.new("unsigned long[1]")
  local pos, len = 0, #s
  local buf = ffi.cast("const char*", s)
  local ok = true
  while pos < len do
    local chunk = math.min(len - pos, 65536)
    if k.WriteFile(h, buf + pos, chunk, written, nil) == 0 or written[0] == 0 then
      ok = false
      break
    end
    pos = pos + tonumber(written[0])
  end
  k.CloseHandle(h)
  k.FreeConsole()
  if not ok then
    return false, "WriteFile failed"
  end
  return true
end
M._console_write = win_console_write

---Cell size from the Windows Terminal window: client area / Neovim grid.
---@param cols integer
---@param rows integer
---@return integer? w, integer? h
measure_cell = function(cols, rows)
  local ffi = require("ffi")
  if not ffi_ready then
    win_console_write("") -- loads the shared cdefs
  end
  pcall(
    ffi.cdef,
    [[
    typedef struct { long left; long top; long right; long bottom; } CB_RECT;
    void* GetConsoleWindow(void);
    void* GetAncestor(void* hwnd, unsigned int flags);
    int GetClientRect(void* hwnd, CB_RECT* r);
  ]]
  )
  local k = ffi.C
  local user32 = ffi.load("user32")
  k.FreeConsole()
  if k.AttachConsole(vim.uv.os_getppid()) == 0 then
    return nil
  end
  local hwnd = k.GetConsoleWindow()
  local root = hwnd ~= nil and user32.GetAncestor(hwnd, 3) or nil -- GA_ROOTOWNER
  local r = ffi.new("CB_RECT")
  local ok = root ~= nil and user32.GetClientRect(root, r) ~= 0
  k.FreeConsole()
  if not ok then
    return nil
  end
  local W, H = r.right - r.left, r.bottom - r.top
  if W <= 0 or H <= 0 or cols <= 0 or rows <= 0 then
    return nil
  end
  local w = math.floor(W / cols) -- padding/scrollbar are small next to the grid
  local h = math.floor((H - 40) / rows) -- tab row + padding
  if h < 1.6 * w or h > 3 * w then
    h = 2 * w
  end
  if w < 4 or h < 8 then
    return nil
  end
  return w, h
end

---@param s string
local function write(s)
  if is_windows and win_ok ~= false then
    local ok, err = win_console_write(s)
    if win_ok == nil then
      win_ok = ok
      require("cellbook.log").add(
        ok and "info" or "warn",
        ok and "sixel: writing to the terminal console (Windows)" or ("sixel: console write failed: " .. tostring(err))
      )
    end
    if ok then
      return
    end
  end
  pcall(vim.fn.chansend, vim.v.stderr, s)
end

-- detection ---------------------------------------------------------------------------

---@param forced boolean? backend explicitly set to "sixel"
function M.available(forced)
  if vim.fn.executable("magick") == 0 and vim.fn.executable("convert") == 0 then
    return false, "ImageMagick (magick) not found"
  end
  if forced then
    return true
  end
  local term = (vim.env.TERM_PROGRAM or ""):lower()
  local sixel_term = vim.env.WT_SESSION ~= nil
    or term:find("wezterm") ~= nil
    or term:find("mlterm") ~= nil
    or (vim.env.TERM or ""):find("foot") ~= nil
    or vim.env.CELLBOOK_SIXEL == "1"
  if not sixel_term then
    return false, "terminal not known to support sixel (set image.backend = 'sixel' to force)"
  end
  return true
end

---@param mime string
function M.supports(mime)
  return mime == "image/png" or mime == "image/jpeg" or mime == "image/gif" or mime == "image/svg+xml"
end

-- image size ----------------------------------------------------------------------------

---@param file string
---@return integer? w, integer? h
local function image_size(file)
  local f = io.open(file, "rb")
  if not f then
    return nil
  end
  local head = f:read(32) or ""
  f:close()
  local w, h = require("cellbook.model.outputs").png_size(head)
  if w then
    return w, h
  end
  local exe = vim.fn.executable("magick") == 1 and { "magick", "identify" } or { "identify" }
  local res = vim.system(vim.list_extend(exe, { "-format", "%w %h", file .. "[0]" }), { text = true }):wait(5000)
  local a, b = (res.stdout or ""):match("(%d+) (%d+)")
  return tonumber(a), tonumber(b)
end

-- encoding --------------------------------------------------------------------------------

---Split concatenated sixel images into a list of sequences.
---@param data string
---@return string[]
function M.split(data)
  local out = {}
  local pos = 1
  while true do
    local s = data:find("\27P", pos, true)
    if not s then
      break
    end
    local e = data:find("\27\\", s + 2, true)
    if not e then
      break
    end
    out[#out + 1] = data:sub(s, e + 1)
    pos = e + 2
  end
  return out
end

---Parse a sixel image into its palette header and 6-pixel bands.
---@param data string one DCS sixel sequence
---@return cellbook.SixelImage?
function M.parse(data)
  local q = data:find("q", 1, true)
  local e = q and data:find("\27\\", q, true)
  if not q or not e then
    return nil
  end
  local body = data:sub(q + 1, e - 1)
  local w, h = body:match('^"%d+;%d+;(%d+);(%d+)')
  local last = 1
  for _, en in body:gmatch("()#%d+;2;%d+;%d+;%d+()") do
    last = en
  end
  local header = body:sub(1, last - 1):gsub('^"%d+;%d+;%d+;%d+', "")
  local bands = vim.split(body:sub(last), "-", { plain = true })
  if bands[#bands] == "" then
    bands[#bands] = nil
  end
  return { header = header, bands = bands, width = tonumber(w) or 0, height = tonumber(h) or (#bands * 6) }
end

---A sixel sequence with only bands [first, last] (1-based) of an image.
---@param img cellbook.SixelImage
---@param first integer
---@param last integer
---@return string
function M.slice(img, first, last)
  first = math.max(1, first)
  last = math.min(#img.bands, last)
  if last < first then
    return ""
  end
  return "\27P0;1;0q"
    .. ('"1;1;%d;%d'):format(img.width, (last - first + 1) * 6)
    .. img.header
    .. table.concat(img.bands, "-", first, last)
    .. "\27\\"
end

---Encode the image, optionally with the top `shift` pixels removed (0..5), so a
---partially visible image can start exactly at a cell boundary: sixel bands are
---6 px tall, cells are usually not a multiple of 6.
---@param p cellbook.SixelPlacement
---@param shift integer?
local function encode(p, shift)
  shift = shift or 0
  p.variants = p.variants or {}
  p.pending = p.pending or {}
  if p.variants[shift] or p.pending[shift] then
    return
  end
  local cs = M.cell_size()
  local pw, ph = p.cols * cs.w, p.rows * cs.h
  local key = ("%s|%dx%d|%d|v5"):format(p.file, pw, ph, shift)
  if cache[key] then
    p.variants[shift] = cache[key]
    if shift == 0 then
      p.img = cache[key]
    end
    M.schedule_paint(false)
    return
  end
  p.pending[shift] = true
  local exe = vim.fn.executable("magick") == 1 and "magick" or "convert"
  local argv = {
    exe,
    p.file .. "[0]",
    "-background",
    "white",
    "-flatten",
    -- only shrink ("WxH>"): an image that already fits keeps its exact pixels;
    -- resampling it to the cell-rounded size would blur text
    "-resize",
    pw .. "x" .. ph .. ">",
  }
  -- quantize first (no dithering: speckles in gradients otherwise), then chop, so
  -- every shifted variant uses exactly the same colours as the unshifted one
  vim.list_extend(argv, { "-dither", "None", "-colors", "256" })
  if shift > 0 then
    vim.list_extend(argv, { "-gravity", "north", "-chop", "0x" .. shift, "+gravity" })
  end
  argv[#argv + 1] = "sixel:-"
  vim.system(argv, { text = false }, function(res)
    vim.schedule(function()
      p.pending[shift] = nil
      local img = res.code == 0 and res.stdout and M.parse(res.stdout) or nil
      if not img then
        require("cellbook.log").add("error", "sixel encode failed: " .. tostring(res.stderr))
        return
      end
      cache[key] = img
      if shift == 0 then
        require("cellbook.log").add(
          "info",
          ("sixel: encoded %s (%dx%d px, %d bands, cell %dx%d)"):format(
            vim.fn.fnamemodify(p.file, ":t"),
            img.width,
            img.height,
            #img.bands,
            cs.w,
            cs.h
          )
        )
      end
      if placements[p.id] then
        p.variants[shift] = img
        if shift == 0 then
          p.img = img
        end
        M.schedule_paint(false)
      end
    end)
  end)
end

-- painting --------------------------------------------------------------------------------

---Number of virtual lines drawn after the image block before the next text line
---(cellbook's output block anchored above the next delimiter).
---@param buf integer
---@param row integer 0-based anchor row
---@return integer
local function lines_after(buf, row)
  local ok, text = pcall(require, "cellbook.render.text")
  if not ok then
    return 0
  end
  local n = 0
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, text.ns, { row + 1, 0 }, { row + 1, -1 }, { details = true })) do
    if m[4].virt_lines and m[4].virt_lines_above then
      n = n + #m[4].virt_lines
    end
  end
  return n
end

---Visible part of a placement in a window.
---@param p cellbook.SixelPlacement
---@param win integer
---@return {row: integer, col: integer, first: integer, last: integer}? view
---  row/col: screen position (1-based) of the first visible image row;
---  first/last: visible image rows (1-based, in terminal rows)
local function visible_part(p, win)
  local pos = api.nvim_buf_get_extmark_by_id(p.buf, M.ns, p.mark, {})
  if not pos[1] then
    return nil
  end
  local anchor = pos[1] -- 0-based
  local info = vim.fn.getwininfo(win)[1] or {}
  -- text area of the window (excludes the winbar / toolbar line)
  local win_top = (info.winrow or 1) + (info.winbar or 0)
  local win_bot = win_top + (info.height or api.nvim_win_get_height(win)) - 1
  local pad = require("cellbook.config").get(p.buf).ui.cell_padding or 0
  local col = (info.wincol or 1) + (info.textoff or 0) + pad
  local first_row -- screen row of image row 1 (may be above the window)
  local sp = vim.fn.screenpos(win, anchor + 1, 1)
  if sp.row > 0 then
    local ok, th = pcall(api.nvim_win_text_height, win, { start_row = anchor, end_row = anchor })
    local line_rows = ok and (th.all - th.fill) or 1
    first_row = sp.row + line_rows
  else
    -- anchor line scrolled out: its virtual lines may still show as filler at the top
    if vim.fn.line("w0", win) ~= anchor + 2 then
      return nil
    end
    local topfill = api.nvim_win_call(win, function()
      return vim.fn.winsaveview().topfill or 0
    end)
    if topfill <= 0 then
      return nil
    end
    first_row = win_top - (p.rows + lines_after(p.buf, anchor) - topfill)
  end
  local top = math.max(win_top, first_row)
  local bot = math.min(win_bot, first_row + p.rows - 1)
  if bot < top then
    return nil
  end
  return { row = top, col = col, first = top - first_row + 1, last = bot - first_row + 1 }
end

---Which encoded variant and bands cover terminal rows [first, last] exactly.
---@param first integer
---@param last integer
---@param ch integer cell height in pixels
---@param nbands integer? bands available in that variant (clamps the end)
---@return integer shift, integer band_first, integer band_last
function M.band_range(first, last, ch, nbands)
  local top_px = (first - 1) * ch
  local bottom_px = last * ch
  local shift = top_px % 6
  local bf = (top_px - shift) / 6 + 1
  local bl = math.floor((bottom_px - shift) / 6)
  if nbands then
    bl = math.min(bl, nbands)
  end
  return shift, bf, bl
end

---Floating windows (screen rectangles, 1-based, inclusive incl. border).
---@return {top: integer, left: integer, bottom: integer, right: integer}[]
local function float_rects()
  local rects = {}
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    local c = api.nvim_win_get_config(w)
    if c.relative ~= "" and not c.hide then
      local fp = api.nvim_win_get_position(w)
      rects[#rects + 1] = {
        top = fp[1],
        left = fp[2],
        bottom = fp[1] + api.nvim_win_get_height(w) + 1,
        right = fp[2] + api.nvim_win_get_width(w) + 1,
      }
    end
  end
  return rects
end

local paint_timer ---@type uv.uv_timer_t?
local settle_ms = 120
local pending_wipe = false
local last_count = -1

local function paint_now()
  if #api.nvim_list_uis() == 0 then
    return
  end
  local floats = float_rects()
  local ch = M.cell_size().h
  local out = {}
  for _, p in pairs(placements) do
    if p.variants and p.variants[0] and api.nvim_buf_is_valid(p.buf) then
      for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if api.nvim_win_get_buf(win) == p.buf and api.nvim_win_get_config(win).relative == "" then
          local v = visible_part(p, win)
          if v then
            local vb = v.row + (v.last - v.first)
            local covered = false
            for _, f in ipairs(floats) do
              if not (f.bottom < v.row or f.top > vb or f.right < v.col or f.left > v.col + p.cols - 1) then
                covered = true
                break
              end
            end
            if not covered then
              local shift = M.band_range(v.first, v.last, ch)
              local img = p.variants[shift]
              local seq = ""
              if img then
                local _, bf, bl = M.band_range(v.first, v.last, ch, #img.bands)
                seq = M.slice(img, bf, bl)
              else
                encode(p, shift) -- drawn as soon as this variant is ready
              end
              if seq ~= "" then
                out[#out + 1] = ("\0277\27[%d;%dH"):format(v.row, v.col) .. seq .. "\0278"
              end
            end
          end
        end
      end
    end
  end
  if #out > 0 then
    write(table.concat(out))
  end
  if #out ~= last_count then
    last_count = #out
    require("cellbook.log").add("debug", ("sixel: painted %d image part(s)"):format(#out))
  end
end

local function paint()
  if pending_wipe then
    pending_wipe = false
    -- remove stale graphics (images deleted/moved by edits): full redraw first,
    -- then paint once the UI has flushed it
    pcall(vim.cmd, "noautocmd mode")
    vim.defer_fn(paint_now, 40)
  else
    paint_now()
  end
end

---Schedule a repaint. `wipe` = clear the screen first (layout changed / image removed).
---@param wipe boolean?
function M.schedule_paint(wipe)
  if wipe then
    pending_wipe = true
  end
  if not paint_timer then
    paint_timer = vim.uv.new_timer()
  end
  paint_timer:stop()
  -- Wait until scrolling/typing settles: the terminal itself moves the pixels
  -- with the text (Neovim scrolls with DECSTBM + delete/insert line), so painting
  -- in the middle of a scroll only races the TUI and makes the image flicker.
  paint_timer:start(wipe and 60 or settle_ms, 0, vim.schedule_wrap(paint))
end

---Re-encode everything (cell size changed).
function M.refresh_all()
  for _, p in pairs(placements) do
    p.img, p.variants, p.pending = nil, nil, nil
    encode(p)
  end
  M.schedule_paint(true)
end

local autocmds_ready = false
local function setup_autocmds()
  if autocmds_ready then
    return
  end
  autocmds_ready = true
  local group = api.nvim_create_augroup("cellbook_sixel", { clear = true })
  local function on(events, wipe)
    api.nvim_create_autocmd(events, {
      group = group,
      callback = function()
        if next(placements) then
          M.schedule_paint(wipe)
        end
      end,
    })
  end
  -- scrolling/editing: the terminal moves the pixels with the text; repaint once
  -- things settle (newly exposed strips), never clear the screen
  on({ "WinScrolled", "TextChanged", "TextChangedI", "FocusGained", "CmdlineLeave", "CompleteDone" }, false)
  -- window layout changes: wipe stale pixels, then repaint
  on({ "WinResized", "VimResized", "BufWinEnter", "TabEnter", "WinClosed" }, true)
end

-- adapter API -------------------------------------------------------------------------------

---@param bufnr integer
---@param row integer 0-based anchor row (last line of the cell)
---@param file string
---@param opts {width: integer?, height: integer?, win: integer}
---@return cellbook.SixelPlacement?
function M.render(bufnr, row, file, opts)
  setup_autocmds()
  local iw, ih = image_size(file)
  if not iw or not ih or iw == 0 then
    return nil
  end
  local cs = M.cell_size()
  local max_cols = math.max(10, opts.width or 80)
  local max_rows = math.max(4, opts.height or 30)
  -- natural size in cells, scaled down to fit
  local cols = math.min(max_cols, math.ceil(iw / cs.w))
  local rows = math.ceil(cols * cs.w * ih / iw / cs.h)
  if rows > max_rows then
    rows = max_rows
    cols = math.max(4, math.floor(rows * cs.h * iw / ih / cs.w))
  end
  local blank = {}
  for i = 1, rows do
    blank[i] = { { "", "Normal" } }
  end
  local ok, mark = pcall(api.nvim_buf_set_extmark, bufnr, M.ns, row, 0, {
    virt_lines = blank,
    priority = 300,
  })
  if not ok then
    return nil
  end
  next_id = next_id + 1
  local p = { id = next_id, buf = bufnr, mark = mark, file = file, cols = cols, rows = rows }
  placements[p.id] = p
  encode(p)
  return p
end

---@param p cellbook.SixelPlacement
function M.clear(p)
  if not p or not placements[p.id] then
    return
  end
  placements[p.id] = nil
  pcall(api.nvim_buf_del_extmark, p.buf, M.ns, p.mark)
  M.schedule_paint(true)
end

---@return integer number of active placements (tests)
function M._count()
  local n = 0
  for _ in pairs(placements) do
    n = n + 1
  end
  return n
end

M._visible_part = visible_part

return M
