---Bridge process: spawn, NDJSON framing, request/response correlation, events.
local json = require("cellbook.format.json")
local framing = require("cellbook.kernel.framing")
local log = require("cellbook.log")

local M = {}

M.PROTOCOL = 1

---@class cellbook.Bridge
---@field proc vim.SystemObj?
---@field next_id integer
---@field pending table<integer, {cb: fun(result: any, err: table?), timer: uv.uv_timer_t?, method: string}>
---@field on_event fun(event: string, params: table)
---@field on_exit fun(code: integer, signal: integer)
---@field exited boolean
---@field hello table?
---@field label string
local Bridge = {}
Bridge.__index = Bridge

---@param msg table
function Bridge:_dispatch(msg)
  if msg.id ~= nil and msg.id ~= vim.NIL then
    local id = json.tonumber(msg.id)
    local p = self.pending[id]
    if not p then
      return
    end
    self.pending[id] = nil
    if p.timer then
      p.timer:stop()
      p.timer:close()
    end
    if msg.error ~= nil and msg.error ~= vim.NIL then
      p.cb(nil, msg.error)
    else
      p.cb(msg.result, nil)
    end
    return
  end
  if msg.event then
    if msg.event == "hello" then
      self.hello = msg.params
    elseif msg.event == "log" then
      local params = msg.params or {}
      log.add(params.level or "info", tostring(params.message), "bridge")
    end
    local ok, err = pcall(self.on_event, msg.event, msg.params or {})
    if not ok then
      log.add("error", "event handler (" .. tostring(msg.event) .. "): " .. tostring(err))
    end
  end
end

---Spawn a bridge.
---@param cmd string[]
---@param opts {cwd: string?, env: table?, label: string?, on_event: fun(event: string, params: table), on_exit: fun(code: integer, signal: integer)}
---@return cellbook.Bridge? bridge
---@return string? err
function M.spawn(cmd, opts)
  local self = setmetatable({
    next_id = 0,
    pending = {},
    on_event = opts.on_event,
    on_exit = opts.on_exit,
    exited = false,
    label = opts.label or cmd[1],
  }, Bridge)
  local framer = framing.new()
  local queue = {}
  local scheduled = false

  local function flush()
    scheduled = false
    local lines = queue
    queue = {}
    for _, line in ipairs(lines) do
      local msg, err = json.pdecode(line)
      if msg then
        self:_dispatch(msg)
      else
        log.add("error", ("bad protocol line (%s): %s"):format(err and err.message or "?", line:sub(1, 200)), "bridge")
      end
    end
  end

  local stderr_framer = framing.new()
  log.add("info", "starting bridge: " .. table.concat(cmd, " "))
  local ok, proc = pcall(vim.system, cmd, {
    stdin = true,
    cwd = opts.cwd,
    env = opts.env,
    stdout = function(_, data)
      if not data then
        return
      end
      local lines = framer:feed(data)
      if #lines > 0 then
        vim.list_extend(queue, lines)
        if not scheduled then
          scheduled = true
          vim.schedule(flush)
        end
      end
    end,
    stderr = function(_, data)
      if data then
        for _, l in ipairs(stderr_framer:feed(data)) do
          log.add("info", l, "stderr")
        end
      end
    end,
  }, function(obj)
    vim.schedule(function()
      flush()
      self.exited = true
      log.add(obj.code == 0 and "info" or "warn", ("bridge exited (code %s, signal %s)"):format(obj.code, obj.signal))
      local pending = self.pending
      self.pending = {}
      for _, p in pairs(pending) do
        if p.timer then
          p.timer:stop()
          p.timer:close()
        end
        pcall(p.cb, nil, { code = "kernel_dead", message = "bridge process exited" })
      end
      pcall(self.on_exit, obj.code, obj.signal)
    end)
  end)
  if not ok then
    return nil, tostring(proc)
  end
  self.proc = proc
  return self, nil
end

---Send a request.
---@param method string
---@param params table?
---@param cb fun(result: any, err: table?)?
---@param timeout_ms integer? nil = no timeout
---@return integer? id
function Bridge:request(method, params, cb, timeout_ms)
  cb = cb or function() end
  if self.exited or not self.proc then
    cb(nil, { code = "kernel_dead", message = "bridge is not running" })
    return nil
  end
  self.next_id = self.next_id + 1
  local id = self.next_id
  local entry = { cb = cb, method = method }
  if timeout_ms then
    entry.timer = vim.uv.new_timer()
    entry.timer:start(
      timeout_ms,
      0,
      vim.schedule_wrap(function()
        local p = self.pending[id]
        if p then
          self.pending[id] = nil
          if p.timer then
            p.timer:close()
          end
          p.cb(nil, { code = "timeout", message = ("%s timed out after %ds"):format(method, timeout_ms / 1000) })
        end
      end)
    )
  end
  self.pending[id] = entry
  local line = json.encode({ id = id, method = method, params = json.object(params or {}) }, { indent = false }) .. "\n"
  local ok, err = pcall(self.proc.write, self.proc, line)
  if not ok then
    self.pending[id] = nil
    if entry.timer then
      entry.timer:stop()
      entry.timer:close()
    end
    cb(nil, { code = "kernel_dead", message = "cannot write to bridge: " .. tostring(err) })
    return nil
  end
  return id
end

---Close stdin (bridge shuts its kernel down and exits).
function Bridge:close()
  if self.proc and not self.exited then
    pcall(self.proc.write, self.proc, nil)
  end
end

---Kill the process.
function Bridge:kill()
  if self.proc and not self.exited then
    pcall(self.proc.kill, self.proc, 9)
  end
end

---@return integer? pid
function Bridge:pid()
  return self.proc and self.proc.pid
end

return M
