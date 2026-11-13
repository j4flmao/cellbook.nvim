---Kernel session: one bridge process + one kernel per notebook.
---
---State machine: starting → idle ⇄ busy → (restarting → idle) | dead | shutdown.
---Lua owns the FIFO execution queue and sends the next `execute` only after the
---previous reply, which keeps cancellation simple.
local api = vim.api
local json = require("cellbook.format.json")
local config = require("cellbook.config")
local outputs = require("cellbook.model.outputs")
local Bridge = require("cellbook.kernel.bridge")
local specs = require("cellbook.kernel.specs")
local events = require("cellbook.events")
local log = require("cellbook.log")

local M = {}

---@type table<cellbook.KernelSession, true>
M.sessions = {}

---@alias cellbook.KernelState "none"|"starting"|"idle"|"busy"|"restarting"|"dead"|"shutdown"

---@class cellbook.QueueItem
---@field cell cellbook.Cell
---@field code string
---@field stop_on_error boolean
---@field token string?
---@field started number?

---@class cellbook.KernelSession
---@field nb cellbook.Notebook
---@field state cellbook.KernelState
---@field bridge cellbook.Bridge?
---@field bridge_ready boolean
---@field queue cellbook.QueueItem[]
---@field current cellbook.QueueItem?
---@field routes table<string, cellbook.Cell>
---@field seq integer
---@field kernel_name string?
---@field display_name string?
---@field python string?
---@field language_info table?
---@field waiters fun(ok: boolean, err: string?)[]
---@field bridge_waiters fun(ok: boolean, err: string?)[]
---@field interrupting boolean
---@field started_at number
local Session = {}
Session.__index = Session
M.Session = Session

---@param nb cellbook.Notebook
---@return cellbook.KernelSession
function M.new(nb)
  local s = setmetatable({
    nb = nb,
    state = "none",
    bridge = nil,
    bridge_ready = false,
    queue = {},
    current = nil,
    routes = {},
    seq = 0,
    waiters = {},
    bridge_waiters = {},
    interrupting = false,
    started_at = vim.uv.hrtime(),
  }, Session)
  M.sessions[s] = true
  return s
end

---@param nb cellbook.Notebook
---@return cellbook.KernelSession
function M.get_or_create(nb)
  if nb.session and nb.session.state ~= "shutdown" then
    return nb.session
  end
  nb.session = M.new(nb)
  return nb.session
end

-- helpers --------------------------------------------------------------------

---@param self cellbook.KernelSession
local function nb_alive(self)
  local nb = self.nb
  return nb and not nb.detached and api.nvim_buf_is_valid(nb.bufnr)
end

---Mark the buffer modified (outputs changed) and redraw a cell.
---@param self cellbook.KernelSession
---@param cell cellbook.Cell
---@param what {header: boolean?, outputs: boolean?}
local function redraw(self, cell, what)
  if not nb_alive(self) then
    return
  end
  local nb = self.nb
  if what.outputs then
    cell.outputs_dirty = true
    require("cellbook.render.text").render(nb, cell)
    if not vim.bo[nb.bufnr].modified then
      vim.bo[nb.bufnr].modified = true
    end
  end
  if what.header ~= false then
    require("cellbook.buffer.decor").update_cell(nb, cell)
  end
end

---@param self cellbook.KernelSession
---@param state cellbook.KernelState
local function set_state(self, state)
  if self.state == state then
    return
  end
  self.state = state
  if nb_alive(self) then
    events.emit("CellbookKernelStateChanged", { bufnr = self.nb.bufnr, state = state })
  end
  vim.schedule(function()
    pcall(vim.cmd, "redrawstatus!")
  end)
end

---@param self cellbook.KernelSession
---@param ok boolean
---@param err string?
local function flush_waiters(self, ok, err)
  local w = self.waiters
  self.waiters = {}
  for _, cb in ipairs(w) do
    pcall(cb, ok, err)
  end
end

---@param self cellbook.KernelSession
---@param ok boolean
---@param err string?
local function flush_bridge_waiters(self, ok, err)
  local w = self.bridge_waiters
  self.bridge_waiters = {}
  for _, cb in ipairs(w) do
    pcall(cb, ok, err)
  end
end

---Notebook directory / kernel cwd.
---@param self cellbook.KernelSession
---@return string dir, string cwd
local function dirs(self)
  local dir = vim.fn.fnamemodify(self.nb.path, ":h")
  local cfg = config.get(self.nb.bufnr)
  local cwd = cfg.kernel.cwd == "cwd" and vim.fn.getcwd() or dir
  return dir, cwd
end

---Choose a kernelspec with vim.ui.select.
---@param list table[]
---@param prompt string
---@param cb fun(spec: table?)
function M.pick(list, prompt, cb)
  vim.ui.select(list, {
    prompt = prompt,
    kind = "cellbook.kernel",
    format_item = function(s)
      local lang = (s.language and s.language ~= "") and (" · " .. s.language) or ""
      return ("%s (%s%s)"):format(s.display_name or s.name, s.name, lang)
    end,
  }, cb)
end

-- bridge ---------------------------------------------------------------------

---Start the bridge process (no kernel yet), trying each Python candidate in turn.
---@param cb fun(ok: boolean, err: string?)
function Session:with_bridge(cb)
  if self.bridge and self.bridge_ready and not self.bridge.exited then
    return cb(true)
  end
  table.insert(self.bridge_waiters, cb)
  if #self.bridge_waiters > 1 then
    return
  end
  local cfg = config.get(self.nb.bufnr)
  local dir, cwd = dirs(self)
  self.choice = require("cellbook.kernel.envs").get_choice(self.nb.path)
  local cands = specs.candidates(dir, cfg, self.choice)
  if #cands == 0 then
    return flush_bridge_waiters(
      self,
      false,
      "no Python interpreter found. Install uv (https://docs.astral.sh/uv/) or Python ≥ 3.9 with `pip install jupyter_client ipykernel`, or set `python` in setup(). See :checkhealth cellbook"
    )
  end
  local reasons = {}
  local function try(i)
    local cand = cands[i]
    if not cand then
      local msg = "could not start the kernel bridge. Tried:\n  "
        .. table.concat(reasons, "\n  ")
        .. "\nSee :checkhealth cellbook and :Cellbook log"
      return flush_bridge_waiters(self, false, msg)
    end
    local got_hello, fatal = false, nil
    local timer
    local b, err
    b, err = Bridge.spawn(specs.command(cand), {
      cwd = cwd,
      label = cand.label,
      on_event = function(event, params)
        if self.bridge ~= b then
          return
        end
        if event == "hello" then
          got_hello = true
          if timer then
            timer:stop()
            timer:close()
            timer = nil
          end
          if json.tonumber(params.protocol) ~= Bridge.PROTOCOL then
            reasons[#reasons + 1] = cand.label .. ": protocol mismatch (update cellbook.nvim)"
            b:kill()
            return
          end
          self.python = params.python
          self.python_version = params.python_version
          self.bridge_ready = true
          log.add(
            "info",
            ("bridge ready via %s: python %s, jupyter_client %s"):format(
              cand.label,
              tostring(params.python_version),
              tostring(params.jupyter_client)
            )
          )
          flush_bridge_waiters(self, true)
        elseif event == "fatal" then
          fatal = params
          log.add("error", ("bridge fatal (%s): %s"):format(tostring(params.code), tostring(params.message)))
        elseif event == "status" then
          self:_on_status(params.state)
        elseif event == "iopub" then
          self:_on_iopub(params)
        end
      end,
      on_exit = function(code)
        if timer then
          timer:stop()
          timer:close()
          timer = nil
        end
        if self.bridge ~= b then
          return
        end
        if not got_hello or not self.bridge_ready then
          local why = fatal and (fatal.message .. (fatal.fix and (" — fix: " .. fatal.fix) or ""))
            or ("exited with code " .. tostring(code))
          reasons[#reasons + 1] = cand.label .. ": " .. why
          self.bridge = nil
          return try(i + 1)
        end
        self.bridge_ready = false
        if self.state ~= "shutdown" then
          self:_on_dead("the kernel bridge exited (code " .. tostring(code) .. ")")
        end
      end,
    })
    if not b then
      reasons[#reasons + 1] = cand.label .. ": " .. tostring(err)
      return try(i + 1)
    end
    self.bridge = b
    local timeout = (cfg.kernel.start_timeout or 180) * 1000
    timer = vim.uv.new_timer()
    timer:start(
      timeout,
      0,
      vim.schedule_wrap(function()
        if timer then
          timer:close()
          timer = nil
        end
        if not got_hello then
          reasons[#reasons + 1] = cand.label .. ": no handshake within " .. (timeout / 1000) .. "s"
          b:kill()
        end
      end)
    )
  end
  try(1)
end

-- kernel start -----------------------------------------------------------------

---Kernel name to start (may prompt).
---@param cb fun(name: string?, err: string?)
function Session:_resolve_kernel(cb)
  local nb = self.nb
  local choice = self.choice
  if choice and choice.kind == "python" then
    return cb("python3") -- ipykernel inside the selected environment
  elseif choice and choice.kind == "kernelspec" and choice.name then
    return cb(choice.name)
  end
  local ks = type(nb.metadata) == "table" and nb.metadata.kernelspec
  local name = type(ks) == "table" and type(ks.name) == "string" and ks.name ~= "" and ks.name or nil
  if name then
    return cb(name)
  end
  local cfg = config.get(nb.bufnr)
  if cfg.kernel.default then
    return cb(cfg.kernel.default)
  end
  self.bridge:request("list_kernelspecs", {}, function(res, err)
    if err then
      return cb(nil, err.message)
    end
    local list = res.specs or {}
    if #list == 0 then
      return cb(nil, "no Jupyter kernels installed. Install one with: python -m pip install ipykernel")
    end
    if #list == 1 then
      self.picked_spec = list[1]
      return cb(list[1].name)
    end
    M.pick(list, "Select a kernel for " .. vim.fn.fnamemodify(nb.path, ":t"), function(spec)
      if not spec then
        return cb(nil, "no kernel selected")
      end
      self.picked_spec = spec
      cb(spec.name)
    end)
  end, 30000)
end

---Record the kernelspec in notebook metadata (when missing or explicitly chosen).
---@param spec {name: string, display_name: string?, language: string?}
---@param language_info table?
function Session:_record_kernelspec(spec, language_info)
  local nb = self.nb
  if not nb_alive(self) then
    return
  end
  nb.metadata.kernelspec = json.object({
    name = spec.name,
    display_name = spec.display_name or spec.name,
    language = (spec.language and spec.language ~= "") and spec.language or nb.language,
  })
  if language_info and type(nb.metadata.language_info) ~= "table" then
    nb.metadata.language_info = setmetatable(json.deepcopy(language_info), json.object_mt)
  end
  nb.meta_dirty = true
  vim.bo[nb.bufnr].modified = true
end

---Start bridge + kernel; cb(ok, err) when the kernel is idle.
---@param cb fun(ok: boolean, err: string?)?
function Session:start(cb)
  cb = cb or function() end
  if self.state == "idle" or self.state == "busy" then
    return cb(true)
  end
  table.insert(self.waiters, cb)
  if self.state == "starting" or self.state == "restarting" then
    return
  end
  set_state(self, "starting")
  self:with_bridge(function(ok, err)
    if not ok then
      set_state(self, "dead")
      return flush_waiters(self, false, err)
    end
    self:_resolve_kernel(function(name, rerr)
      if not name then
        set_state(self, "none")
        return flush_waiters(self, false, rerr)
      end
      self:_start_kernel(name, false)
    end)
  end)
end

---@param name string
---@param retried boolean
function Session:_start_kernel(name, retried)
  local _, cwd = dirs(self)
  local cfg = config.get(self.nb.bufnr)
  set_state(self, "starting")
  self.bridge:request("start_kernel", {
    kernel_name = name,
    cwd = cwd,
    timeout = cfg.kernel.start_timeout,
    native = self.choice ~= nil and self.choice.kind == "python",
  }, function(res, err)
    if err then
      if err.code == "no_such_kernel" and not retried then
        return self.bridge:request("list_kernelspecs", {}, function(lres)
          local list = lres and lres.specs or {}
          if #list == 0 then
            set_state(self, "none")
            return flush_waiters(
              self,
              false,
              ("kernel '%s' is not installed and no kernels are available. Install one with: python -m pip install ipykernel"):format(
                name
              )
            )
          end
          M.pick(list, ("Kernel '%s' not found — select a kernel"):format(name), function(spec)
            if not spec then
              set_state(self, "none")
              return flush_waiters(self, false, "no kernel selected")
            end
            self.picked_spec = spec
            self:_start_kernel(spec.name, true)
          end)
        end, 30000)
      end
      set_state(self, "none")
      return flush_waiters(self, false, ("failed to start kernel '%s': %s"):format(name, err.message or err.code))
    end
    self.kernel_name = res.kernel_name or name
    self.display_name = (self.choice and self.choice.kind == "python" and self.choice.display_name)
      or res.display_name
      or name
    self.language_info = res.language_info
    local ks = self.nb.metadata and self.nb.metadata.kernelspec
    if self.picked_spec or type(ks) ~= "table" then
      self:_record_kernelspec(
        self.picked_spec or { name = self.kernel_name, display_name = self.display_name, language = res.language },
        res.language_info
      )
      self.picked_spec = nil
    end
    set_state(self, "idle")
    if nb_alive(self) then
      events.emit("CellbookKernelStarted", { bufnr = self.nb.bufnr, kernel_name = self.kernel_name })
    end
    flush_waiters(self, true)
    self:_next()
  end, ((cfg.kernel.start_timeout or 180) + 10) * 1000)
end

-- events -----------------------------------------------------------------------

---@param state string
function Session:_on_status(state)
  if state == "dead" then
    return self:_on_dead("the kernel died")
  end
  if state == "busy" or state == "idle" then
    if self.state == "idle" or self.state == "busy" then
      set_state(self, state)
    end
  end
end

---Find outputs with a display id (across the notebook).
---@param id string
---@return cellbook.Output[] outs, cellbook.Cell[] cells
function Session:_find_display(id)
  local outs, cells = {}, {}
  for _, c in ipairs(self.nb.cells or {}) do
    local hit = false
    for _, o in ipairs(c.outputs) do
      if o.display_id == id then
        outs[#outs + 1] = o
        hit = true
      end
    end
    if hit then
      cells[#cells + 1] = c
    end
  end
  return outs, cells
end

---@param p table iopub event params
function Session:_on_iopub(p)
  if not nb_alive(self) then
    return
  end
  local cell = (p.cell_id ~= nil and p.cell_id ~= vim.NIL) and self.routes[p.cell_id] or nil
  local msg_type = p.msg_type
  local content = p.content or {}
  if msg_type == "execute_input" then
    local ec = json.tonumber(content.execution_count)
    if cell and type(ec) == "number" then
      cell.execution_count = ec
      redraw(self, cell, { header = true })
    end
    return
  end
  if msg_type == "update_display_data" then
    local id = type(content.transient) == "table" and content.transient.display_id
    if not id then
      return
    end
    local outs, cells = self:_find_display(id)
    if #outs == 0 then
      return
    end
    outputs.apply({ outputs = {} }, msg_type, content, function()
      return outs
    end)
    for _, c in ipairs(cells) do
      redraw(self, c, { outputs = true, header = false })
      require("cellbook.render.image").render_cell(self.nb, c, true)
    end
    return
  end
  if not cell then
    return
  end
  local changed = outputs.apply(cell, msg_type, content, function(id)
    return (self:_find_display(id))
  end)
  if changed then
    redraw(self, cell, { outputs = true, header = false })
  end
end

---@param reason string
function Session:_on_dead(reason)
  if self.state == "dead" or self.state == "shutdown" then
    return
  end
  set_state(self, "dead")
  local cur = self.current
  self.current = nil
  if cur then
    local cell = cur.cell
    cell.run_state = "error"
    table.insert(cell.outputs, {
      type = "error",
      ename = "DeadKernelError",
      evalue = reason,
      traceback = { "\27[0;31mDeadKernelError\27[0m: " .. reason },
    })
    redraw(self, cell, { outputs = true })
  end
  self:_cancel_queue()
  flush_waiters(self, false, reason)
  vim.notify("cellbook: " .. reason .. ". Run :Cellbook restart (<localleader>0).", vim.log.levels.ERROR)
end

-- execution ----------------------------------------------------------------------

function Session:_cancel_queue()
  local q = self.queue
  self.queue = {}
  for _, item in ipairs(q) do
    item.cell.run_state = "cancelled"
    redraw(self, item.cell, { header = true })
  end
end

---Queue cells for execution.
---@param items {cell: cellbook.Cell, code: string}[]
---@param opts {stop_on_error: boolean?}?
function Session:enqueue(items, opts)
  opts = opts or {}
  local stop = opts.stop_on_error
  if stop == nil then
    stop = config.get(self.nb.bufnr).run_all.stop_on_error
  end
  local queued = {}
  for _, it in ipairs(self.queue) do
    queued[it.cell] = true
  end
  if self.current then
    queued[self.current.cell] = true
  end
  for _, it in ipairs(items) do
    if not queued[it.cell] then
      queued[it.cell] = true
      it.cell.run_state = "queued"
      self.queue[#self.queue + 1] = { cell = it.cell, code = it.code, stop_on_error = stop }
      redraw(self, it.cell, { header = true })
    end
  end
  if self.state == "dead" then
    self:_cancel_queue()
    vim.ui.select({ "Restart kernel", "Cancel" }, { prompt = "cellbook: the kernel is dead" }, function(choice)
      if choice == "Restart kernel" then
        self:restart({})
      end
    end)
    return
  end
  pcall(vim.cmd, "redrawstatus!")
  if self.state == "idle" or self.state == "busy" then
    self:_next()
  else
    self:start(function(ok, err)
      if not ok then
        self:_cancel_queue()
        if err then
          vim.notify("cellbook: " .. err, vim.log.levels.ERROR)
        end
      end
    end)
  end
end

function Session:_next()
  if self.current or not (self.state == "idle" or self.state == "busy") then
    return
  end
  local item = table.remove(self.queue, 1)
  if not item then
    return
  end
  if not nb_alive(self) then
    self.queue = {}
    return
  end
  local cell = item.cell
  self.current = item
  self.seq = self.seq + 1
  item.token = ("cb%d"):format(self.seq)
  self.routes[item.token] = cell
  item.started = vim.uv.hrtime()
  cell.run_state = "running"
  cell.run_started_at = item.started
  cell.run_duration_ms = nil
  cell.run_source = cell.snapshot
  cell.outputs = {}
  cell.clear_pending = false
  cell.execution_count = vim.NIL
  redraw(self, cell, { outputs = true })
  require("cellbook.buffer.decor").start_spinner()
  self.bridge:request("execute", {
    code = item.code,
    cell_id = item.token,
    silent = false,
    store_history = true,
    stop_on_error = item.stop_on_error,
  }, function(res, err)
    self:_on_reply(item, res, err)
  end)
end

---@param item cellbook.QueueItem
---@param res table?
---@param err table?
function Session:_on_reply(item, res, err)
  if self.current ~= item then
    return -- already handled (dead/restart)
  end
  self.current = nil
  local cell = item.cell
  local duration = (vim.uv.hrtime() - item.started) / 1e6
  cell.run_duration_ms = duration
  local status
  if err then
    if err.code == "kernel_restarted" then
      status = "cancelled"
      cell.run_state = "cancelled"
    else
      status = "error"
      cell.run_state = "error"
      if err.code ~= "kernel_dead" then
        vim.notify("cellbook: execute failed: " .. tostring(err.message or err.code), vim.log.levels.ERROR)
      end
    end
  else
    status = res.status or "error"
    local ec = json.tonumber(res.execution_count)
    if type(ec) == "number" then
      cell.execution_count = ec
      for _, o in ipairs(cell.outputs) do
        if o.type == "execute_result" then
          o.execution_count = ec
        end
      end
    end
    if status == "ok" then
      cell.run_state = "done"
    elseif status == "aborted" then
      cell.run_state = "cancelled"
    elseif self.interrupting or res.ename == "KeyboardInterrupt" then
      cell.run_state = "interrupted"
      status = "interrupted"
    else
      cell.run_state = "error"
    end
  end
  local was_interrupt = self.interrupting
  self.interrupting = false
  if (status ~= "ok" and item.stop_on_error) or was_interrupt then
    self:_cancel_queue()
  end
  redraw(self, cell, { outputs = true })
  if nb_alive(self) then
    events.emit("CellbookCellExecuted", {
      bufnr = self.nb.bufnr,
      cell_id = cell.id,
      index = require("cellbook.model.notebook").index_of(self.nb, cell),
      status = status,
      execution_count = cell.execution_count ~= vim.NIL and cell.execution_count or nil,
      duration_ms = duration,
    })
  end
  self:_next()
end

-- control --------------------------------------------------------------------------

function Session:interrupt()
  if not (self.bridge and self.bridge_ready) or not (self.state == "busy" or self.state == "idle") then
    return
  end
  if self.current then
    self.interrupting = true
  end
  self.bridge:request("interrupt", {}, function(_, err)
    if err then
      vim.notify("cellbook: interrupt failed: " .. tostring(err.message), vim.log.levels.ERROR)
    end
  end, 10000)
end

---@param opts {run_all: boolean?, on_ready: fun()?}?
function Session:restart(opts)
  opts = opts or {}
  local function after(ok, err)
    if not ok then
      if err then
        vim.notify("cellbook: " .. err, vim.log.levels.ERROR)
      end
      return
    end
    for _, c in ipairs(self.nb.cells) do
      if c.run_state ~= "idle" then
        c.run_state = "idle"
        redraw(self, c, { header = true })
      end
    end
    vim.notify("cellbook: kernel restarted", vim.log.levels.INFO)
    if opts.on_ready then
      opts.on_ready()
    end
  end
  self:_cancel_queue()
  if not (self.bridge and self.bridge_ready and self.kernel_name) then
    -- bridge gone (dead) or never started: start fresh
    if self.bridge and not self.bridge.exited then
      self.bridge:kill()
    end
    self.bridge, self.bridge_ready = nil, false
    set_state(self, "none")
    return self:start(after)
  end
  local cur = self.current
  self.current = nil
  if cur then
    cur.cell.run_state = "cancelled"
    redraw(self, cur.cell, { header = true })
  end
  set_state(self, "restarting")
  self.bridge:request("restart", {}, function(res, err)
    if err then
      set_state(self, "dead")
      return after(false, "restart failed: " .. tostring(err.message or err.code))
    end
    self.language_info = res.language_info
    set_state(self, "idle")
    after(true)
    self:_next()
  end, 120000)
end

---Shut down kernel and bridge.
---@param cb fun()?
function Session:shutdown(cb)
  self:_cancel_queue()
  self.current = nil
  M.sessions[self] = nil
  if self.nb and self.nb.session == self then
    self.nb.session = nil
  end
  local b = self.bridge
  set_state(self, "shutdown")
  if not b or b.exited then
    if cb then
      cb()
    end
    return
  end
  b:request("shutdown", {}, function()
    b:close()
    if cb then
      cb()
    end
  end, 3000)
  vim.defer_fn(function()
    if not b.exited then
      b:close()
    end
  end, 3000)
  vim.defer_fn(function()
    if not b.exited then
      b:kill()
    end
  end, 6000)
end

---Info for statusline/API.
---@return {name: string?, display_name: string?, state: string, python: string?}
function Session:info()
  return { name = self.kernel_name, display_name = self.display_name, state = self.state, python = self.python }
end

-- module API -------------------------------------------------------------------------

---Ensure a running kernel for a notebook.
---@param nb cellbook.Notebook
---@param cb fun(ok: boolean, err: string?)
function M.ensure(nb, cb)
  M.get_or_create(nb):start(cb)
end

---"Select Kernel" (like VS Code): Python environments and Jupyter kernelspecs.
---The choice is remembered for the notebook, written to its kernelspec metadata,
---and the kernel is restarted with it.
---@param nb cellbook.Notebook
---@param cb fun(choice: cellbook.KernelChoice?)?
function M.select_kernel(nb, cb)
  cb = cb or function() end
  local envs = require("cellbook.kernel.envs")
  local dir = vim.fn.fnamemodify(nb.path, ":h")
  local items = {}
  for _, e in ipairs(envs.python_envs(dir)) do
    items[#items + 1] = e
  end
  for _, k in ipairs(envs.kernelspecs()) do
    items[#items + 1] = k
  end
  local current = envs.get_choice(nb.path)
  local function is_current(it)
    if not current then
      return false
    end
    if it.kind == "python" then
      return current.kind == "python" and current.python == it.python
    end
    return current.kind == "kernelspec" and current.name == it.name
  end
  if #items == 0 then
    vim.notify("cellbook: no Python environments or Jupyter kernels found. Install uv or Python.", vim.log.levels.ERROR)
    return cb(nil)
  end
  vim.ui.select(items, {
    prompt = "Select Kernel",
    kind = "cellbook.kernel",
    format_item = function(it)
      local mark = is_current(it) and "● " or "  "
      local group = it.kind == "python" and "Python Env " or "Jupyter    "
      local src = it.source and ("[" .. it.source .. "]") or ""
      return ("%s%s %-28s %-12s %s"):format(mark, group, it.display_name, src, it.detail or "")
    end,
  }, function(choice)
    if not choice then
      return cb(nil)
    end
    envs.set_choice(nb.path, choice)
    local s = M.get_or_create(nb)
    local lang = (choice.language and choice.language ~= "") and choice.language or "python"
    s:_record_kernelspec({
      name = choice.kind == "python" and "python3" or choice.name,
      display_name = choice.display_name,
      language = lang,
    }, nil)
    if lang ~= nb.language then
      require("cellbook.buffer.attach").set_language(nb, lang)
    end
    local function start_new()
      local ns = M.get_or_create(nb)
      ns:start(function(ok, err)
        if ok then
          vim.notify("cellbook: kernel " .. (ns.display_name or choice.display_name) .. " ready")
        elseif err then
          vim.notify("cellbook: " .. err, vim.log.levels.ERROR)
        end
      end)
    end
    if s.bridge or s.state ~= "none" then
      s:shutdown(start_new)
    else
      M.sessions[s] = nil
      nb.session = nil
      start_new()
    end
    pcall(vim.cmd, "redrawstatus!")
    cb(choice)
  end)
end

---Shut down every session (VimLeavePre): wait up to `timeout_ms`, then kill.
---@param timeout_ms integer?
function M.shutdown_all(timeout_ms)
  local bridges = {}
  for s in pairs(M.sessions) do
    if s.bridge and not s.bridge.exited then
      bridges[#bridges + 1] = s.bridge
    end
    s:shutdown()
  end
  if #bridges == 0 then
    return
  end
  for _, b in ipairs(bridges) do
    b:close()
  end
  vim.wait(timeout_ms or 1000, function()
    for _, b in ipairs(bridges) do
      if not b.exited then
        return false
      end
    end
    return true
  end, 20)
  for _, b in ipairs(bridges) do
    if not b.exited then
      b:kill()
    end
  end
end

return M
