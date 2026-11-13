---BufReadCmd / BufWriteCmd / FileReadCmd / FileWriteCmd handlers.
local api = vim.api
local uv = vim.uv
local config = require("cellbook.config")
local ipynb = require("cellbook.format.ipynb")
local percent = require("cellbook.format.percent")
local Notebook = require("cellbook.model.notebook")
local tracker = require("cellbook.buffer.tracker")
local decor = require("cellbook.buffer.decor")
local events = require("cellbook.events")
local log = require("cellbook.log")

local M = {}

local is_windows = vim.fn.has("win32") == 1

---Sessions kept alive across unload/reload, keyed by notebook path.
---@type table<string, cellbook.KernelSession>
M.kept_sessions = {}

---@param path string
---@return string
function M.normalize(path)
  local p = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  return p
end

---@param a string
---@param b string
---@return boolean
function M.same_path(a, b)
  -- resolve symlinks (e.g. macOS /var -> /private/var) when the files exist
  local function canon(p)
    p = M.normalize(p)
    local real = vim.uv.fs_realpath(p)
    p = real and vim.fs.normalize(real) or p
    return is_windows and p:lower() or p
  end
  return canon(a) == canon(b)
end

---Read a whole file synchronously (BufReadCmd must fill the buffer before returning).
---@param path string
---@return string? text
---@return string? err
---@return string? code e.g. "ENOENT"
function M.read_file(path)
  local fd, err, code = uv.fs_open(path, "r", 438)
  if not fd then
    return nil, err, code
  end
  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, "cannot stat " .. path, "EIO"
  end
  local chunks, offset = {}, 0
  while offset < stat.size do
    local data, rerr = uv.fs_read(fd, math.min(stat.size - offset, 8 * 1024 * 1024), offset)
    if not data then
      uv.fs_close(fd)
      return nil, rerr, "EIO"
    end
    if #data == 0 then
      break
    end
    chunks[#chunks + 1] = data
    offset = offset + #data
  end
  uv.fs_close(fd)
  return table.concat(chunks), nil, nil
end

---Write a file atomically (temp file + rename, keeping the original mode).
---@param path string
---@param text string
---@return boolean ok
---@return string? err
function M.atomic_write(path, text)
  local real = uv.fs_realpath(path) or path
  local dir = vim.fn.fnamemodify(real, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    return false, "directory does not exist: " .. dir
  end
  local stat = uv.fs_stat(real)
  local mode = stat and stat.mode % 4096 or 420
  local tmp = ("%s.cellbook-%d.tmp"):format(real, uv.hrtime())
  local fd, err = uv.fs_open(tmp, "w", mode)
  if not fd then
    return false, err
  end
  local ok, werr = uv.fs_write(fd, text, 0)
  if ok then
    uv.fs_fsync(fd)
  end
  uv.fs_close(fd)
  if not ok then
    uv.fs_unlink(tmp)
    return false, werr
  end
  local rok, rerr = uv.fs_rename(tmp, real)
  if rok then
    return true
  end
  uv.fs_unlink(tmp)
  -- rename can fail on Windows when another program holds the file open: write in place
  local fd2, oerr = uv.fs_open(real, "w", mode)
  if not fd2 then
    return false, rerr or oerr
  end
  local ok2, werr2 = uv.fs_write(fd2, text, 0)
  uv.fs_close(fd2)
  if not ok2 then
    return false, werr2
  end
  return true
end

---@param bufnr integer
---@param lines string[]
local function set_lines_no_undo(bufnr, lines)
  -- No swap file for notebook buffers: the buffer holds the percent-format view,
  -- so "Recover" would write that text into the .ipynb (not JSON). Turning it off
  -- before the first change also avoids the E325 ATTENTION prompt firing in the
  -- middle of BufReadCmd when a stale swap file exists.
  vim.bo[bufnr].swapfile = false
  local ul = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1
  vim.bo[bufnr].modifiable = true
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].undolevels = ul
end

---Show an unparseable notebook read-only as raw text.
---@param bufnr integer
---@param path string
---@param text string
---@param err cellbook.ParseError
function M.show_raw(bufnr, path, text, err)
  local lines = vim.split((text:gsub("\r\n", "\n")), "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    lines[#lines] = nil
  end
  set_lines_no_undo(bufnr, lines)
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modifiable = false
  if err.kind ~= "invalid_utf8" then
    vim.bo[bufnr].filetype = "json"
  end
  Notebook.register({
    bufnr = bufnr,
    path = path,
    readonly = true,
    readonly_reason = err.message,
    cells = {},
    ranges = {},
    mark_to_cell = {},
    raw_text = text,
  })
  M.setup_autocmds(bufnr)
  vim.schedule(function()
    vim.notify(
      ("cellbook: %s is opened read-only: %s"):format(vim.fn.fnamemodify(path, ":~:."), err.message),
      err.kind == "unsupported_version" and vim.log.levels.WARN or vim.log.levels.ERROR
    )
  end)
end

---Stop tracking a buffer (unload/reload).
---@param nb cellbook.Notebook
---@param opts {keep_session: boolean?}?
function M.detach(nb, opts)
  opts = opts or {}
  nb.detached = true
  for _, c in ipairs(nb.cells or {}) do
    pcall(require("cellbook.render.image").clear_cell, nb, c)
  end
  if nb.session then
    if opts.keep_session then
      M.kept_sessions[nb.path] = nb.session
    else
      nb.session:shutdown()
    end
  end
  Notebook.unregister(nb.bufnr)
end

---BufReadCmd handler.
---@param bufnr integer
---@param afile string
function M.read(bufnr, afile)
  local cfg = config.get(bufnr)
  local path = M.normalize(afile)
  local existing = Notebook.get(bufnr)
  if existing then
    M.detach(existing, { keep_session = true })
  end
  local old_session = M.kept_sessions[path]
  M.kept_sessions[path] = nil

  local text, err, code = M.read_file(path)
  local data, perr
  local is_new = false
  if text then
    data, perr = ipynb.parse(text, { default_language = cfg.default_language })
  elseif code == "ENOENT" then
    data = ipynb.empty(cfg.default_language)
    is_new = true
  else
    vim.notify(("cellbook: cannot read %s: %s"):format(path, tostring(err)), vim.log.levels.ERROR)
    return
  end
  if not data then
    ---@cast perr -nil
    ---@cast text -nil
    M.show_raw(bufnr, path, text, perr)
    return
  end

  ---@type cellbook.Notebook
  local nb = data --[[@as cellbook.Notebook]]
  nb.bufnr = bufnr
  nb.path = path
  nb.readonly = false
  nb.is_new = is_new
  nb.mark_to_cell = {}
  nb.ranges = {}
  nb.filetype = percent.filetype_for(nb.language)
  Notebook.register(nb)

  local lines, starts = percent.to_lines(nb.cells, nb.comment)
  if #lines == 0 then
    lines = { "" }
  end
  set_lines_no_undo(bufnr, lines)
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].modified = false
  vim.b[bufnr].cellbook = true

  tracker.attach(nb, starts)
  vim.bo[bufnr].filetype = nb.filetype

  decor.setup_highlights()
  decor.full(nb)
  require("cellbook.render.text").render_all(nb)
  M.setup_autocmds(bufnr)
  require("cellbook.keymaps").apply(nb)
  require("cellbook.lsp").attach(nb)
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(w) == bufnr then
      decor.setup_window(w)
    end
  end

  if old_session and old_session.state ~= "shutdown" then
    old_session.nb = nb
    nb.session = old_session
  end
  events.emit("CellbookAttached", { bufnr = bufnr, path = path })
  if cfg.kernel.autostart and not nb.session then
    vim.schedule(function()
      if Notebook.get(bufnr) == nb then
        require("cellbook.kernel.session").ensure(nb, function() end)
      end
    end)
  end
end

---Write buffer lines as plain text (non-.ipynb targets, partial writes).
---@param path string
---@param lines string[]
---@return boolean
local function write_plain(path, lines)
  local ok, err = M.atomic_write(path, table.concat(lines, "\n") .. "\n")
  if not ok then
    vim.notify(("E212: Can't open file for writing: %s (%s)"):format(path, tostring(err)), vim.log.levels.ERROR)
    return false
  end
  api.nvim_echo({ { ('"%s" %dL written'):format(vim.fn.fnamemodify(path, ":~:."), #lines) } }, false, {})
  return true
end

---Serialize the notebook in a buffer.
---@param nb cellbook.Notebook
---@return string text
---@return table[] raw_cells
---@return string[] sources
function M.serialize(nb)
  tracker.flush(nb)
  tracker.scan(nb)
  if tracker.fix_leading_orphans(nb) then
    tracker.after_refresh(nb, { structure = true })
  end
  local sources = tracker.sources(nb)
  local cfg = config.get(nb.bufnr)
  local text, raw_cells = ipynb.serialize(nb, sources, { strip_outputs = cfg.save.strip_outputs })
  return text, raw_cells, sources
end

---BufWriteCmd handler.
---@param bufnr integer
---@param afile string
---@return boolean ok
function M.write(bufnr, afile)
  local nb = Notebook.get(bufnr)
  local target = M.normalize(afile)
  if not nb then
    return write_plain(target, api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end
  if nb.readonly then
    vim.notify(
      ("cellbook: refusing to overwrite %s (%s)"):format(
        vim.fn.fnamemodify(nb.path, ":~:."),
        nb.readonly_reason or "read-only"
      ),
      vim.log.levels.ERROR
    )
    return false
  end
  if not target:lower():match("%.ipynb$") then
    return write_plain(target, api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end

  local ok_ser, text, raw_cells, sources = pcall(M.serialize, nb)
  if not ok_ser then
    log.add("error", "serialize failed: " .. tostring(text))
    vim.notify("cellbook: failed to serialize notebook (nothing written): " .. tostring(text), vim.log.levels.ERROR)
    return false
  end
  local ok, err = M.atomic_write(target, text)
  if not ok then
    vim.notify(("E212: Can't open file for writing: %s (%s)"):format(target, tostring(err)), vim.log.levels.ERROR)
    return false
  end

  local bufname = api.nvim_buf_get_name(bufnr)
  local is_own = M.same_path(target, nb.path) or (bufname ~= "" and M.same_path(target, bufname))
  if is_own then
    nb.path = target
    ipynb.commit(nb, text, raw_cells, sources)
    nb.is_new = false
    vim.bo[bufnr].modified = false
  end

  if config.get(bufnr).debug then
    local re = ipynb.parse(text)
    if not re then
      log.add("error", "debug self-check: written notebook does not parse!")
      vim.notify("cellbook: self-check failed — written notebook does not parse", vim.log.levels.ERROR)
    elseif #re.cells ~= #nb.cells then
      log.add("error", ("debug self-check: cell count %d ≠ %d"):format(#re.cells, #nb.cells))
    end
  end

  api.nvim_echo(
    { { ('"%s" %d cells, %dB written'):format(vim.fn.fnamemodify(target, ":~:."), #nb.cells, #text) } },
    false,
    {}
  )
  events.emit("CellbookSaved", { bufnr = bufnr, path = target })
  return true
end

---FileWriteCmd handler (`:{range}w file`): writes the selected lines as plain text.
---@param bufnr integer
---@param afile string
function M.write_range(bufnr, afile)
  local first = vim.fn.line("'[")
  local last = vim.fn.line("']")
  local total = api.nvim_buf_line_count(bufnr)
  if first <= 1 and last >= total then
    return M.write(bufnr, afile)
  end
  return write_plain(M.normalize(afile), api.nvim_buf_get_lines(bufnr, first - 1, last, false))
end

---FileReadCmd handler (`:r file.ipynb`): inserts the cells of another notebook.
---@param bufnr integer
---@param afile string
function M.file_read(bufnr, afile)
  local path = M.normalize(afile)
  local text, err = M.read_file(path)
  if not text then
    vim.notify(("cellbook: cannot read %s: %s"):format(path, tostring(err)), vim.log.levels.ERROR)
    return
  end
  local nb = Notebook.get(bufnr)
  local row = vim.fn.line(".")
  local data = ipynb.parse(text)
  local lines
  if data then
    lines = percent.to_lines(data.cells, nb and nb.comment or data.comment)
  else
    lines = vim.split(text, "\n", { plain = true })
  end
  api.nvim_buf_set_lines(bufnr, row, row, false, lines)
  if nb and not nb.readonly then
    tracker.sync(nb)
  end
end

---Switch the notebook language (kernel change): filetype and, when the comment
---leader differs, the delimiter/markdown prefixes of the whole buffer.
---@param nb cellbook.Notebook
---@param lang string
function M.set_language(nb, lang)
  tracker.flush(nb)
  local sources = tracker.sources(nb)
  local newc = percent.comment_for(lang)
  nb.language = lang
  nb.filetype = percent.filetype_for(lang)
  if newc ~= nb.comment then
    for i, c in ipairs(nb.cells) do
      c.source = sources[i]
    end
    nb.comment = newc
    local lines, starts = percent.to_lines(nb.cells, newc)
    if #lines == 0 then
      lines = { "" }
    end
    api.nvim_buf_set_lines(nb.bufnr, 0, -1, false, lines)
    for i, c in ipairs(nb.cells) do
      tracker.place(nb, c, starts[i])
    end
    tracker.scan(nb)
    for _, r in ipairs(nb.ranges) do
      r.cell.snapshot = table.concat(api.nvim_buf_get_lines(nb.bufnr, r.start + 1, r.stop + 1, false), "\n")
    end
    tracker.after_refresh(nb, { structure = true })
  end
  vim.bo[nb.bufnr].filetype = nb.filetype
end

---Buffer-local autocommands for a notebook buffer.
---@param bufnr integer
function M.setup_autocmds(bufnr)
  local group = api.nvim_create_augroup("cellbook_buf_" .. bufnr, { clear = true })
  api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    nested = true,
    callback = function(ev)
      M.write(ev.buf, ev.match ~= "" and ev.match or ev.file)
    end,
  })
  api.nvim_create_autocmd("FileWriteCmd", {
    group = group,
    buffer = bufnr,
    nested = true,
    callback = function(ev)
      M.write_range(ev.buf, ev.match ~= "" and ev.match or ev.file)
    end,
  })
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = bufnr,
    callback = function(ev)
      decor.setup_window(api.nvim_get_current_win())
      local nb = Notebook.get(ev.buf)
      if nb and not nb.readonly then
        require("cellbook.render.image").render_visible(nb)
      end
    end,
  })
  -- markdown cells show their raw text while you type in them (Insert mode)
  api.nvim_create_autocmd({ "InsertEnter", "InsertLeave", "CursorMovedI" }, {
    group = group,
    buffer = bufnr,
    callback = function(ev)
      local nb = Notebook.get(ev.buf)
      if nb and not nb.readonly and not nb.detached then
        tracker.flush(nb)
        decor.on_cursor(nb, api.nvim_win_get_cursor(0)[1] - 1, ev.event ~= "InsertLeave")
      end
    end,
  })
  api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = bufnr,
    callback = function(ev)
      local nb = Notebook.get(ev.buf)
      if not nb then
        return
      end
      local keep = not config.get(ev.buf).kernel.shutdown_on_close
      M.detach(nb, { keep_session = keep })
      pcall(api.nvim_del_augroup_by_id, group)
    end,
  })
end

return M
