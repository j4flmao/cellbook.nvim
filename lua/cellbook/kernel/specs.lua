---Python discovery for the bridge and the bridge script location.
local config = require("cellbook.config")

local M = {}

local is_windows = vim.fn.has("win32") == 1

---Absolute path of python/cellbook_bridge.py in this plugin.
---@return string
function M.bridge_path()
  local src = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fn.fnamemodify(src, ":p:h:h:h:h")
  return vim.fs.joinpath(vim.fs.normalize(root), "python", "cellbook_bridge.py")
end

---Python executable inside a virtualenv / conda prefix.
---@param prefix string
---@return string?
function M.env_python(prefix)
  local candidates = is_windows and { "Scripts/python.exe", "python.exe" } or { "bin/python3", "bin/python" }
  for _, rel in ipairs(candidates) do
    local p = vim.fs.joinpath(prefix, rel)
    if vim.fn.executable(p) == 1 then
      return p
    end
  end
  return nil
end

---@param exe string
---@return string?
local function exepath(exe)
  local p = vim.fn.exepath(exe)
  if p == "" then
    return nil
  end
  -- Windows "App execution alias" stubs open the Microsoft Store instead of running Python
  if is_windows and p:lower():find("windowsapps", 1, true) then
    return nil
  end
  return p
end

---@class cellbook.PythonCandidate
---@field cmd string[]     command prefix (the bridge script and args are appended)
---@field label string     human readable description
---@field kind "config"|"venv"|"conda"|"uv"|"dotvenv"|"system"

---Ordered list of ways to run the bridge for a notebook directory.
---@param dir string? notebook directory (for `.venv` discovery / uv project)
---@param cfg cellbook.Config?
---@param choice cellbook.KernelChoice? kernel picked with "Select Kernel"
---@return cellbook.PythonCandidate[]
function M.candidates(dir, cfg, choice)
  cfg = cfg or config.values
  local out = {}
  if choice and choice.kind == "python" and choice.python then
    -- an environment picked with "Select Kernel": layer the Jupyter packages on
    -- top of it with uv (its own packages stay importable), else run it directly
    local uvcfg = type(cfg.uv) == "table" and cfg.uv or { enabled = cfg.uv }
    local uv = uvcfg.enabled ~= false and exepath("uv")
    if uv then
      local cmd = { uv, "run", "--quiet", "--no-project", "--python", choice.python }
      for _, pkg in ipairs(uvcfg.with or {}) do
        vim.list_extend(cmd, { "--with", pkg })
      end
      cmd[#cmd + 1] = "python"
      out[#out + 1] = { cmd = cmd, label = "uv + " .. choice.python, kind = "uv" }
    end
    out[#out + 1] = { cmd = { choice.python }, label = choice.python, kind = "venv" }
    return out
  end
  local py = cfg.python
  if type(py) == "string" and py ~= "" then
    return { { cmd = { vim.fn.expand(py) }, label = "python = " .. py, kind = "config" } }
  elseif type(py) == "table" and #py > 0 then
    return { { cmd = vim.deepcopy(py), label = "python = { " .. table.concat(py, " ") .. " }", kind = "config" } }
  end

  local venv = vim.env.VIRTUAL_ENV
  if venv and venv ~= "" then
    local p = M.env_python(venv)
    if p then
      out[#out + 1] = { cmd = { p }, label = "$VIRTUAL_ENV (" .. p .. ")", kind = "venv" }
    end
  end
  local conda = vim.env.CONDA_PREFIX
  if conda and conda ~= "" then
    local p = M.env_python(conda)
    if p then
      out[#out + 1] = { cmd = { p }, label = "$CONDA_PREFIX (" .. p .. ")", kind = "conda" }
    end
  end

  local uvcfg = type(cfg.uv) == "table" and cfg.uv or { enabled = cfg.uv }
  local uv_enabled = uvcfg.enabled
  if uv_enabled == nil then
    uv_enabled = "auto"
  end
  local uv = uv_enabled ~= false and exepath("uv")
  if uv then
    local cmd = { uv, "run", "--quiet" }
    vim.list_extend(cmd, uvcfg.args or {})
    for _, pkg in ipairs(uvcfg.with or {}) do
      vim.list_extend(cmd, { "--with", pkg })
    end
    cmd[#cmd + 1] = "python"
    out[#out + 1] = { cmd = cmd, label = "uv (" .. uv .. ")", kind = "uv" }
  elseif uv_enabled == true then
    vim.notify_once("cellbook: uv.enabled = true but `uv` is not on $PATH", vim.log.levels.WARN)
  end

  if dir then
    local found = vim.fs.find(".venv", { upward = true, path = dir, type = "directory" })[1]
    if found then
      local p = M.env_python(found)
      if p then
        out[#out + 1] = { cmd = { p }, label = ".venv (" .. p .. ")", kind = "dotvenv" }
      end
    end
  end

  for _, exe in ipairs({ "python3", "python" }) do
    local p = exepath(exe)
    if p then
      local dup = false
      for _, c in ipairs(out) do
        if c.cmd[1] == p then
          dup = true
        end
      end
      if not dup then
        out[#out + 1] = { cmd = { p }, label = exe .. " (" .. p .. ")", kind = "system" }
      end
    end
  end
  return out
end

---Full bridge command for a candidate.
---@param cand cellbook.PythonCandidate
---@param extra string[]? extra bridge arguments
---@return string[]
function M.command(cand, extra)
  local cmd = vim.deepcopy(cand.cmd)
  vim.list_extend(cmd, { "-u", M.bridge_path() })
  vim.list_extend(cmd, extra or { "--protocol", tostring(require("cellbook.kernel.bridge").PROTOCOL) })
  return cmd
end

return M
