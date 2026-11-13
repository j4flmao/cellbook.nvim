---`:checkhealth cellbook`
local M = {}

local h = vim.health

---Run the bridge in `--check` mode with a candidate (synchronous; health may block).
---@param cand cellbook.PythonCandidate
---@return table? report
---@return string? err
local function check_candidate(cand)
  local specs = require("cellbook.kernel.specs")
  local cmd = specs.command(cand, { "--check" })
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true, stdin = false }):wait(180000)
  end)
  if not ok then
    return nil, tostring(res)
  end
  local line = vim.trim(res.stdout or ""):match("[^\n]*$") or ""
  local report = require("cellbook.format.json").pdecode(line)
  if type(report) ~= "table" then
    local err = vim.trim((res.stderr or "") .. "\n" .. (res.stdout or ""))
    return nil, ("exit code %s%s"):format(tostring(res.code), err ~= "" and (": " .. err:sub(1, 300)) or "")
  end
  if report.event == "fatal" then
    return nil, tostring(report.params and report.params.message)
  end
  return report, nil
end

---Version tuple from "3.12.1".
local function version_ge(v, major, minor)
  local a, b = tostring(v or ""):match("^(%d+)%.(%d+)")
  a, b = tonumber(a), tonumber(b)
  if not a then
    return false
  end
  return a > major or (a == major and b >= minor)
end

function M.check()
  h.start("cellbook: Neovim")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error(
      "Neovim ≥ 0.11 is required (found " .. tostring(vim.version()) .. ")",
      { "Upgrade Neovim: https://github.com/neovim/neovim/releases" }
    )
  end
  local bridge_path = require("cellbook.kernel.specs").bridge_path()
  if vim.uv.fs_stat(bridge_path) then
    h.ok("Bridge script: " .. bridge_path)
  else
    h.error("Bridge script not found: " .. bridge_path, { "Reinstall the plugin" })
  end

  h.start("cellbook: Python & Jupyter (kernel execution)")
  local cfg = require("cellbook.config").values
  local nb = require("cellbook.model.notebook").get(0)
  local dir = nb and nb.path and vim.fn.fnamemodify(nb.path, ":h") or vim.fn.getcwd()
  local cands = require("cellbook.kernel.specs").candidates(dir, cfg)
  if vim.fn.executable("uv") == 1 then
    local v = vim.system({ "uv", "--version" }, { text = true }):wait(10000)
    h.ok(
      "uv found: "
        .. vim.trim(v.stdout or "uv")
        .. " (bridge runs with `uv run --with jupyter_client --with ipykernel`)"
    )
  else
    h.info("uv not found (optional, recommended): https://docs.astral.sh/uv/getting-started/installation/")
  end
  if #cands == 0 then
    h.error("No Python interpreter found", {
      "Install uv: https://docs.astral.sh/uv/getting-started/installation/",
      "or install Python ≥ 3.9 and run: python3 -m pip install jupyter_client ipykernel",
      "or set `python = '/path/to/python'` in require('cellbook').setup()",
    })
    return
  end
  local working
  for _, cand in ipairs(cands) do
    local report, err = check_candidate(cand)
    if report and report.jupyter_client then
      working = { cand = cand, report = report }
      h.ok(
        ("Bridge Python: %s → %s (Python %s)"):format(
          cand.label,
          tostring(report.python),
          tostring(report.python_version)
        )
      )
      if not version_ge(report.python_version, 3, 9) then
        h.warn(
          "Python " .. tostring(report.python_version) .. " is older than the supported 3.9",
          { "Use Python ≥ 3.9 (uv picks a recent one automatically)" }
        )
      end
      h.ok("jupyter_client " .. tostring(report.jupyter_client))
      break
    elseif report then
      h.warn(("%s: Python %s has no jupyter_client"):format(cand.label, tostring(report.python_version)), {
        (cand.cmd[1] or "python") .. " -m pip install jupyter_client ipykernel",
      })
    else
      h.warn(("%s: %s"):format(cand.label, tostring(err)))
    end
  end
  if not working then
    h.error("No Python with jupyter_client found — notebooks open and save, but cells cannot run", {
      "python3 -m pip install jupyter_client ipykernel",
      "or install uv (https://docs.astral.sh/uv/) — cellbook then installs the bridge dependencies automatically",
    })
  else
    local report = working.report
    local specs_list = report.specs or {}
    if #specs_list == 0 then
      h.error("No Jupyter kernels installed", { "python3 -m pip install ipykernel" })
    else
      local names = {}
      for _, s in ipairs(specs_list) do
        names[#names + 1] = ("%s (%s)"):format(s.name, s.display_name)
      end
      h.ok("Kernels: " .. table.concat(names, ", "))
    end
    if report.ipykernel then
      h.ok("ipykernel " .. tostring(report.ipykernel) .. " (in the bridge environment)")
    else
      h.info("ipykernel is not installed in the bridge environment (fine if you use other kernelspecs)")
    end
  end

  h.start("cellbook: Images (optional)")
  local backend = cfg.image.backend
  local adapter, why = require("cellbook.render.image").select(backend)
  if adapter then
    h.ok("Image backend: " .. adapter.name)
  else
    h.info("No image backend (" .. tostring(why) .. "); images show as placeholders and open with <localleader>o", {
      "Install folke/snacks.nvim with `image = { enabled = true }`, or 3rd/image.nvim",
    })
  end
  local term = vim.env.TERM_PROGRAM or vim.env.TERM or "?"
  local graphics = vim.env.KITTY_WINDOW_ID or vim.env.WEZTERM_EXECUTABLE or vim.env.GHOSTTY_RESOURCES_DIR
  if graphics or term:lower():find("kitty") or term:lower():find("wezterm") or term:lower():find("ghostty") then
    h.ok("Terminal with kitty graphics support detected (" .. term .. ")")
  else
    h.info("Terminal " .. term .. ": inline images need kitty, WezTerm or Ghostty")
  end
  if vim.env.TMUX then
    local out = vim.system({ "tmux", "show", "-gv", "allow-passthrough" }, { text = true }):wait(3000)
    if vim.trim(out.stdout or "") == "on" or vim.trim(out.stdout or "") == "all" then
      h.ok("tmux allow-passthrough is on")
    else
      h.warn(
        "tmux allow-passthrough is off (images will not render inside tmux)",
        { "tmux set -g allow-passthrough on" }
      )
    end
  end

  h.start("cellbook: Keymaps")
  h.info(
    "<S-CR>/<C-CR> need a terminal that reports them (kitty, WezTerm, Ghostty, Alacritty, Windows Terminal); <localleader>r always works"
  )
  if vim.g.maplocalleader == nil then
    h.info("maplocalleader is not set; <localleader> defaults to '\\'")
  end
end

return M
