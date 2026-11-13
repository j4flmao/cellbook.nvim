---Configuration: defaults, validation, merge.
local M = {}

---@class cellbook.Config
M.defaults = {
  -- Python used to run the kernel bridge. nil = auto (see `:h cellbook-python`):
  -- $VIRTUAL_ENV, $CONDA_PREFIX, uv, nearest .venv, python3, python.
  -- A string (path/executable) or a list (full command, e.g. { "uv", "run", "python" }).
  python = nil,

  -- uv integration: run the bridge with `uv run --with jupyter_client --with ipykernel python ...`
  uv = {
    enabled = "auto", -- "auto" (use uv when it is on $PATH) | true | false
    with = { "jupyter_client>=8", "ipykernel>=6", "pillow" }, -- layered on top of the project env (pillow: inline images)
    args = {}, -- extra arguments for `uv run` (e.g. { "--python", "3.12" })
  },

  -- Language used when the notebook has no kernelspec/language_info
  default_language = "python",

  kernel = {
    -- Kernel to use when the notebook has none. nil = prompt with vim.ui.select
    default = nil,
    -- Start the kernel on open instead of on first run
    autostart = false,
    -- Shut down the kernel when the last buffer of the notebook is closed
    shutdown_on_close = true,
    -- Working directory for the kernel: "notebook" (file's dir) | "cwd"
    cwd = "notebook",
    -- Seconds to wait for the bridge/kernel to start (first uv run may download packages)
    start_timeout = 180,
  },

  run_all = {
    stop_on_error = true,
  },

  output = {
    max_lines = 30, -- truncate visible lines per output
    max_line_width = nil, -- nil = window width
    show_stderr = true,
    ansi = true, -- convert ANSI colors
    mime_priority = { "image/png", "image/jpeg", "image/svg+xml", "text/markdown", "text/plain" },
    virt_lines_leftcol = false,
    html_tables = true, -- render HTML tables (pandas DataFrames) as box-drawn tables
  },

  image = {
    backend = "auto", -- "auto" | "snacks" | "image.nvim" | "sixel" | "none"
    cell_size = nil, -- sixel: terminal cell size in pixels { w, h } (nil = measure / 8x16)
    max_height = 30, -- in terminal rows
    -- without a graphics backend, draw images with text characters:
    -- "sextant" (2x3 sub-pixels per cell, sharper) | "half" (▀, works with any font) | false
    blocks = "sextant",
    max_width = nil, -- nil = window width
    only_visible = true, -- render images only for visible cells
  },

  ui = {
    cell_header = true, -- decorated delimiter lines
    show_execution_time = true,
    conceal_comment_prefix = true,
    border_char = "─",
    toolbar = true, -- clickable winbar: + Code, + Markdown, Run All, Restart, ..., Select Kernel
    render_markdown = true, -- render markdown cells (raw text while the cursor is inside)
    cell_padding = 2, -- left padding inside code cells
    output_gutter = "▎", -- bar left of outputs ("" to disable)
    icons = {
      running = "●",
      done = "✓",
      error = "✗",
      queued = "◷",
      stale = "*",
      interrupted = "⊘",
      cancelled = "⊘",
    },
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  },

  lsp = {
    filter_magic_diagnostics = true,
  },

  keymaps = true, -- boolean or table of { action = lhs|false }

  save = {
    -- Strip outputs on save (useful for git-tracked notebooks)
    strip_outputs = false,
  },

  debug = false, -- extra assertions + round-trip self-check
}

---Default keymaps: action → { mode, lhs, desc }.
M.default_keymaps = {
  next_cell = { "n", "]c", "Next cell" },
  prev_cell = { "n", "[c", "Previous cell" },
  inner_cell = { { "o", "x" }, "ic", "Inner cell" },
  around_cell = { { "o", "x" }, "ac", "Around cell" },
  run_and_next = { "n", "<S-CR>", "Run cell and go to next" },
  run_cell_stay = { "n", "<C-CR>", "Run cell" },
  run_selection = { "x", "<C-CR>", "Run selection" },
  run_cell = { "n", "<localleader>r", "Run cell" },
  run_all = { "n", "<localleader>R", "Run all cells" },
  add_above = { "n", "<localleader>a", "Add code cell above" },
  add_below = { "n", "<localleader>b", "Add code cell below" },
  toggle_type = { "n", "<localleader>m", "Toggle cell type code/markdown" },
  delete_cell = { "n", "<localleader>d", "Delete cell" },
  move_up = { "n", "<localleader>k", "Move cell up" },
  move_down = { "n", "<localleader>j", "Move cell down" },
  split_cell = { "n", "<localleader>s", "Split cell at cursor" },
  merge_below = { "n", "<localleader>J", "Merge with cell below" },
  clear_output = { "n", "<localleader>c", "Clear cell output" },
  clear_all = { "n", "<localleader>C", "Clear all outputs" },
  open_output = { "n", "<localleader>o", "Open full output" },
  interrupt = { "n", "<localleader>i", "Interrupt kernel" },
  restart = { "n", "<localleader>0", "Restart kernel" },
  select_kernel = { "n", "<localleader>K", "Select kernel" },
}

---@type cellbook.Config
M.values = vim.deepcopy(M.defaults)

local function levenshtein(a, b)
  local la, lb = #a, #b
  if la == 0 then
    return lb
  end
  if lb == 0 then
    return la
  end
  local prev = {}
  for j = 0, lb do
    prev[j] = j
  end
  for i = 1, la do
    local cur = { [0] = i }
    for j = 1, lb do
      local cost = a:byte(i) == b:byte(j) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev = cur
  end
  return prev[lb]
end

---All valid dotted keys of the defaults.
local function valid_keys()
  local keys = {}
  local function walk(t, prefix)
    for k, v in pairs(t) do
      local key = prefix and (prefix .. "." .. k) or k
      keys[#keys + 1] = key
      if type(v) == "table" and not vim.islist(v) and key ~= "ui.icons" then
        walk(v, key)
      end
    end
  end
  walk(M.defaults, nil)
  -- optional (nil-default) keys
  for _, k in ipairs({ "python", "kernel.default", "output.max_line_width", "image.max_width" }) do
    keys[#keys + 1] = k
  end
  return keys
end

---@param key string
---@return string?
function M.suggest(key)
  local best, best_d
  for _, k in ipairs(valid_keys()) do
    local d = levenshtein(key, k)
    if not best_d or d < best_d then
      best, best_d = k, d
    end
  end
  if best and best_d <= math.max(2, math.floor(#key / 3)) then
    return best
  end
  return nil
end

local types = {
  python = { "string", "table", "nil" },
  uv = { "table", "boolean" },
  ["uv.enabled"] = { "string", "boolean" },
  ["uv.with"] = "table",
  ["uv.args"] = "table",
  default_language = "string",
  kernel = "table",
  ["kernel.default"] = { "string", "nil" },
  ["kernel.autostart"] = "boolean",
  ["kernel.shutdown_on_close"] = "boolean",
  ["kernel.cwd"] = "string",
  ["kernel.start_timeout"] = "number",
  run_all = "table",
  ["run_all.stop_on_error"] = "boolean",
  output = "table",
  ["output.max_lines"] = "number",
  ["output.max_line_width"] = { "number", "nil" },
  ["output.show_stderr"] = "boolean",
  ["output.ansi"] = "boolean",
  ["output.mime_priority"] = "table",
  ["output.virt_lines_leftcol"] = "boolean",
  ["output.html_tables"] = "boolean",
  ["image.blocks"] = { "boolean", "string" },
  ["ui.output_gutter"] = "string",
  image = "table",
  ["image.backend"] = "string",
  ["image.max_height"] = "number",
  ["image.max_width"] = { "number", "nil" },
  ["image.cell_size"] = { "table", "nil" },
  ["image.only_visible"] = "boolean",
  ui = "table",
  ["ui.cell_header"] = "boolean",
  ["ui.show_execution_time"] = "boolean",
  ["ui.conceal_comment_prefix"] = "boolean",
  ["ui.border_char"] = "string",
  ["ui.toolbar"] = "boolean",
  ["ui.render_markdown"] = "boolean",
  ["ui.cell_padding"] = "number",
  ["ui.icons"] = "table",
  ["ui.spinner"] = "table",
  lsp = "table",
  ["lsp.filter_magic_diagnostics"] = "boolean",
  keymaps = { "boolean", "table" },
  save = "table",
  ["save.strip_outputs"] = "boolean",
  debug = "boolean",
}

local enums = {
  ["image.backend"] = { "auto", "snacks", "image.nvim", "sixel", "none" },
  ["kernel.cwd"] = { "notebook", "cwd" },
}

---Validate user options. Returns a list of warnings (never throws for unknown keys).
---@param opts table
---@return string[] warnings
---@return string? err fatal type error
function M.validate(opts)
  local warnings = {}
  local function walk(t, prefix, defaults)
    for k, v in pairs(t) do
      local key = prefix and (prefix .. "." .. k) or tostring(k)
      local expected = types[key]
      if prefix == "keymaps" then
        if not M.default_keymaps[k] then
          local s
          local best_d
          for name in pairs(M.default_keymaps) do
            local d = levenshtein(k, name)
            if not best_d or d < best_d then
              s, best_d = name, d
            end
          end
          warnings[#warnings + 1] = ("cellbook: unknown keymap action `%s`%s"):format(
            k,
            s and (" (did you mean `" .. s .. "`?)") or ""
          )
        elseif type(v) ~= "string" and v ~= false then
          return warnings, ("cellbook: keymaps.%s must be a string or false"):format(k)
        end
      elseif
        prefix == "ui.icons"
        or prefix == "ui.spinner"
        or prefix == "output.mime_priority"
        or prefix == "uv.with"
        or prefix == "uv.args"
      then
        -- free-form tables
      elseif not expected then
        local s = M.suggest(key)
        warnings[#warnings + 1] = ("cellbook: unknown option `%s`%s"):format(
          key,
          s and (" (did you mean `" .. s .. "`?)") or ""
        )
      else
        local list = type(expected) == "table" and expected or { expected }
        if not vim.tbl_contains(list, type(v)) then
          return warnings, ("cellbook: option `%s` must be %s, got %s"):format(key, table.concat(list, "|"), type(v))
        end
        if enums[key] and not vim.tbl_contains(enums[key], v) then
          return warnings, ("cellbook: option `%s` must be one of %s"):format(key, table.concat(enums[key], ", "))
        end
        local _, err
        if type(v) == "table" and key ~= "python" and type(defaults) == "table" and type(defaults[k]) == "table" then
          _, err = walk(v, key, defaults[k])
        elseif key == "keymaps" and type(v) == "table" then
          _, err = walk(v, key, nil)
        end
        if err then
          return warnings, err
        end
      end
    end
    return warnings, nil
  end
  return walk(opts, nil, M.defaults)
end

---@param opts cellbook.Config?
function M.setup(opts)
  opts = opts or {}
  if type(opts.uv) == "boolean" then
    opts = vim.deepcopy(opts)
    opts.uv = { enabled = opts.uv }
  end
  local warnings, err = M.validate(opts)
  for _, w in ipairs(warnings) do
    vim.notify(w, vim.log.levels.WARN)
  end
  if err then
    vim.notify(err, vim.log.levels.ERROR)
    return false
  end
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- list-like options replace instead of merging index-wise
  if opts.output and opts.output.mime_priority then
    merged.output.mime_priority = vim.deepcopy(opts.output.mime_priority)
  end
  if opts.uv and opts.uv.with then
    merged.uv.with = vim.deepcopy(opts.uv.with)
  end
  M.values = merged
  return true
end

---Effective config for a buffer (`vim.b.cellbook_config` overrides).
---@param bufnr integer?
---@return cellbook.Config
function M.get(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local ok, override = pcall(function()
      return vim.b[bufnr].cellbook_config
    end)
    if ok and type(override) == "table" then
      return vim.tbl_deep_extend("force", M.values, override)
    end
  end
  return M.values
end

return M
