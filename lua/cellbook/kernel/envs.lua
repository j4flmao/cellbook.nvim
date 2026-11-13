---Kernel sources for "Select Kernel": Python environments (venv, conda, uv,
---PATH) and installed Jupyter kernelspecs, discovered from the file system
---without starting Python. The choice is remembered per notebook.
local M = {}

local is_windows = vim.fn.has("win32") == 1

---@class cellbook.KernelChoice
---@field kind "python"|"kernelspec"
---@field python string?          interpreter path (kind = "python")
---@field name string?            kernelspec name (kind = "kernelspec")
---@field display_name string
---@field language string
---@field version string?
---@field source string?          ".venv", "conda", "uv", "PATH", "kernelspec"...
---@field detail string?          path shown in the picker

---@param path string
---@return string
local function norm(path)
  local p = vim.fs.normalize(path)
  return is_windows and p:lower() or p
end

---@param path string
---@return string?
local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

---Python executable inside an environment prefix.
---@param prefix string
---@return string?
function M.env_python(prefix)
  local rels = is_windows and { "Scripts/python.exe", "python.exe" } or { "bin/python3", "bin/python" }
  for _, rel in ipairs(rels) do
    local p = vim.fs.joinpath(prefix, rel)
    if vim.uv.fs_stat(p) then
      return vim.fs.normalize(p)
    end
  end
  return nil
end

---Python version of a virtualenv from pyvenv.cfg (no process spawn).
---@param prefix string
---@return string?
function M.venv_version(prefix)
  local cfg = read(vim.fs.joinpath(prefix, "pyvenv.cfg"))
  if not cfg then
    return nil
  end
  return cfg:match("version_info%s*=%s*([%d%.]+)")
    or cfg:match("\nversion%s*=%s*([%d%.]+)")
    or cfg:match("^version%s*=%s*([%d%.]+)")
end

---@param list cellbook.KernelChoice[]
---@param seen table<string, true>
---@param prefix string
---@param source string
local function add_env(list, seen, prefix, source)
  local py = M.env_python(prefix)
  if not py or seen[norm(py)] then
    return
  end
  seen[norm(py)] = true
  local version = M.venv_version(prefix)
  local name = vim.fn.fnamemodify(vim.fs.normalize(prefix), ":t")
  list[#list + 1] = {
    kind = "python",
    python = py,
    display_name = ("Python %s (%s)"):format(version or "3", name),
    language = "python",
    version = version,
    source = source,
    detail = vim.fn.fnamemodify(prefix, ":~"),
  }
end

---Discover Python environments, most relevant first.
---@param dir string? notebook directory
---@return cellbook.KernelChoice[]
function M.python_envs(dir)
  local list, seen = {}, {}
  if dir then
    -- .venv / venv / env next to the notebook or in a parent directory
    for _, name in ipairs({ ".venv", "venv", "env" }) do
      for _, found in ipairs(vim.fs.find(name, { upward = true, path = dir, type = "directory", limit = 3 })) do
        add_env(list, seen, found, name)
      end
    end
  end
  if vim.env.VIRTUAL_ENV and vim.env.VIRTUAL_ENV ~= "" then
    add_env(list, seen, vim.env.VIRTUAL_ENV, "$VIRTUAL_ENV")
  end
  if vim.env.CONDA_PREFIX and vim.env.CONDA_PREFIX ~= "" then
    add_env(list, seen, vim.env.CONDA_PREFIX, "conda")
  end
  -- conda environments registry
  local home = vim.uv.os_homedir() or ""
  local conda_txt = read(vim.fs.joinpath(home, ".conda", "environments.txt"))
  if conda_txt then
    for line in conda_txt:gmatch("[^\r\n]+") do
      if vim.uv.fs_stat(line) then
        add_env(list, seen, line, "conda")
      end
    end
  end
  -- interpreters managed by uv and on PATH
  if vim.fn.executable("uv") == 1 then
    local ok, res = pcall(function()
      return vim
        .system({ "uv", "python", "list", "--only-installed", "--output-format", "json" }, { text = true })
        :wait(5000)
    end)
    if ok and res and res.code == 0 then
      local okj, items = pcall(vim.json.decode, res.stdout or "[]")
      if okj and type(items) == "table" then
        local keys = {}
        for _, it in ipairs(items) do
          local p = type(it.path) == "string" and vim.fs.normalize(it.path) or nil
          local v = type(it.version) == "string" and it.version or ""
          local key = type(it.key) == "string" and it.key or p
          -- stable releases only, one entry per interpreter
          if p and v:match("^%d+%.%d+%.%d+$") and not keys[key] and not seen[norm(p)] then
            if not (is_windows and p:lower():find("windowsapps", 1, true)) then
              keys[key] = true
              seen[norm(p)] = true
              list[#list + 1] = {
                kind = "python",
                python = p,
                display_name = ("Python %s"):format(v),
                language = "python",
                version = v,
                source = p:lower():find("uv[/\\]python") and "uv" or "global",
                detail = vim.fn.fnamemodify(p, ":~"),
              }
            end
          end
        end
      end
    end
  end
  for _, exe in ipairs({ "python3", "python" }) do
    local p = vim.fn.exepath(exe)
    if p ~= "" and not (is_windows and p:lower():find("windowsapps", 1, true)) then
      p = vim.fs.normalize(p)
      if not seen[norm(p)] then
        seen[norm(p)] = true
        list[#list + 1] = {
          kind = "python",
          python = p,
          display_name = "Python (" .. exe .. ")",
          language = "python",
          source = "PATH",
          detail = vim.fn.fnamemodify(p, ":~"),
        }
      end
    end
  end
  return list
end

---Jupyter data directories that may contain kernelspecs.
---@return string[]
function M.kernel_dirs()
  local dirs = {}
  local function add(d)
    if d and d ~= "" then
      dirs[#dirs + 1] = vim.fs.joinpath(d, "kernels")
    end
  end
  if vim.env.JUPYTER_DATA_DIR then
    add(vim.env.JUPYTER_DATA_DIR)
  end
  for p in (vim.env.JUPYTER_PATH or ""):gmatch(is_windows and "[^;]+" or "[^:]+") do
    add(p)
  end
  local home = vim.uv.os_homedir() or ""
  if is_windows then
    add(vim.env.APPDATA and vim.fs.joinpath(vim.env.APPDATA, "jupyter"))
    add(vim.env.PROGRAMDATA and vim.fs.joinpath(vim.env.PROGRAMDATA, "jupyter"))
  elseif vim.fn.has("mac") == 1 then
    add(vim.fs.joinpath(home, "Library", "Jupyter"))
    add("/usr/local/share/jupyter")
    add("/usr/share/jupyter")
  else
    add(vim.fs.joinpath(vim.env.XDG_DATA_HOME or vim.fs.joinpath(home, ".local", "share"), "jupyter"))
    add("/usr/local/share/jupyter")
    add("/usr/share/jupyter")
  end
  for _, prefix in ipairs({ vim.env.VIRTUAL_ENV, vim.env.CONDA_PREFIX }) do
    if prefix and prefix ~= "" then
      add(vim.fs.joinpath(prefix, "share", "jupyter"))
    end
  end
  return dirs
end

---Installed kernelspecs (kernel.json files).
---@return cellbook.KernelChoice[]
function M.kernelspecs()
  local list, seen = {}, {}
  for _, dir in ipairs(M.kernel_dirs()) do
    if vim.uv.fs_stat(dir) then
      for name, t in vim.fs.dir(dir) do
        if (t == "directory" or t == "link") and not seen[name] then
          local text = read(vim.fs.joinpath(dir, name, "kernel.json"))
          local ok, spec = pcall(vim.json.decode, text or "")
          if ok and type(spec) == "table" then
            seen[name] = true
            list[#list + 1] = {
              kind = "kernelspec",
              name = name,
              display_name = type(spec.display_name) == "string" and spec.display_name or name,
              language = type(spec.language) == "string" and spec.language:lower() or "",
              source = "kernelspec",
              detail = type(spec.argv) == "table" and type(spec.argv[1]) == "string" and spec.argv[1] or dir,
            }
          end
        end
      end
    end
  end
  table.sort(list, function(a, b)
    return a.display_name < b.display_name
  end)
  return list
end

-- persistence -------------------------------------------------------------------

local state_cache ---@type table<string, cellbook.KernelChoice>?

---@return string
function M.state_path()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "cellbook", "kernels.json")
end

---@return table<string, cellbook.KernelChoice>
local function load_state()
  if state_cache then
    return state_cache
  end
  local ok, t = pcall(vim.json.decode, read(M.state_path()) or "{}")
  state_cache = ok and type(t) == "table" and t or {}
  return state_cache
end

---Remembered kernel choice of a notebook.
---@param path string
---@return cellbook.KernelChoice?
function M.get_choice(path)
  local c = load_state()[norm(path)]
  if type(c) == "table" and (c.kind == "python" or c.kind == "kernelspec") then
    return c
  end
  return nil
end

---Remember (or forget, with nil) the kernel choice of a notebook.
---@param path string
---@param choice cellbook.KernelChoice?
function M.set_choice(path, choice)
  local state = load_state()
  state[norm(path)] = choice
  vim.fn.mkdir(vim.fn.fnamemodify(M.state_path(), ":h"), "p")
  local f = io.open(M.state_path(), "wb")
  if f then
    f:write(vim.json.encode(state))
    f:close()
  end
end

---Reset the in-memory cache (tests).
function M._reset()
  state_cache = nil
end

return M
