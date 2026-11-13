# Contract: Public Lua API (v1)

Everything in this file is public and covered by semantic versioning. Anything not listed (e.g. `cellbook.buffer.*`, `cellbook.kernel.*`) is internal and may change without notice.

All functions accept an optional `bufnr` (default: current buffer). Calling a notebook function on a non-notebook buffer returns `nil, "not a notebook buffer"` and does not throw.

## Module `cellbook`

```lua
local cb = require("cellbook")

---Optional. Merge user options with defaults and validate.
---Calling setup() more than once re-applies options.
---@param opts cellbook.Config?
cb.setup(opts)

---@return boolean
cb.is_notebook(bufnr)

-- Execution ---------------------------------------------------------------
cb.run_cell(bufnr?, cell_index?)         -- run cell under cursor (or index, 1-based)
cb.run_cell_and_next(bufnr?)             -- run, move to next cell (create one at end)
cb.run_all(bufnr?)
cb.run_above(bufnr?)                     -- cells before the current one (exclusive)
cb.run_below(bufnr?)                     -- current and all following
cb.run_range(bufnr?, start_row, end_row) -- run selected lines as an anonymous request (output on the cell containing end_row)
cb.interrupt(bufnr?)
cb.restart(bufnr?, opts?)                -- opts: { run_all = false }
cb.shutdown(bufnr?)

-- Cells -----------------------------------------------------------------
cb.add_cell(bufnr?, opts?)               -- opts: { where = "below"|"above", type = "code"|"markdown"|"raw" }
cb.delete_cell(bufnr?)
cb.move_cell(bufnr?, delta)              -- delta: -1 up, +1 down
cb.split_cell(bufnr?)                    -- split at cursor line
cb.merge_cell(bufnr?, dir)               -- dir: "below"|"above"
cb.set_cell_type(bufnr?, type)
cb.goto_cell(bufnr?, delta)              -- relative jump; returns new index
cb.clear_output(bufnr?, opts?)           -- opts: { all = false }
cb.toggle_output(bufnr?, opts?)          -- opts: { all = false }
cb.open_output(bufnr?)                   -- full output in a scratch split / image in system viewer

-- Kernel ----------------------------------------------------------------
cb.select_kernel(bufnr?, callback?)      -- vim.ui.select over kernelspecs
cb.kernel_info(bufnr?)                   -- returns { name, display_name, state, python } or nil

-- Introspection -----------------------------------------------------------
---@return { index: integer, id: string?, type: string, run_state: string, execution_count: integer? }?
cb.current_cell(bufnr?)
---@return integer
cb.cell_count(bufnr?)

-- UI --------------------------------------------------------------------
cb.statusline(bufnr?)                    -- string, e.g. " python3 ● idle  [3/12]"
```

## User events

Fired with `vim.api.nvim_exec_autocmds("User", { pattern = ..., data = ... })`.

| Pattern | `data` |
|---|---|
| `CellbookAttached` | `{ bufnr, path }` |
| `CellbookKernelStarted` | `{ bufnr, kernel_name }` |
| `CellbookKernelStateChanged` | `{ bufnr, state }` |
| `CellbookCellExecuted` | `{ bufnr, cell_id, index, status, execution_count, duration_ms }` |
| `CellbookSaved` | `{ bufnr, path }` |

Example:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "CellbookCellExecuted",
  callback = function(ev)
    if ev.data.duration_ms > 10000 then
      vim.notify(("Cell %d finished in %.1fs"):format(ev.data.index, ev.data.duration_ms / 1000))
    end
  end,
})
```

## Renderer adapter registration

```lua
require("cellbook").register_renderer({
  name = "my-backend",
  available = function() return true end,
  supports = function(mime) return mime == "image/png" end,
  render = function(bufnr, row, file, opts) return handle end,
  clear = function(handle) end,
})
```

Registered adapters are tried before built-ins when `image.backend = "auto"`.

## Highlight groups

All defined with `default = true` so colorschemes can override.

| Group | Default link | Used for |
|---|---|---|
| `CellbookCellHeader` | `FloatTitle` | delimiter line decoration |
| `CellbookCellHeaderMarkdown` | `Title` | markdown cell header |
| `CellbookCellBorder` | `WinSeparator` | separator rule |
| `CellbookRunning` | `DiagnosticWarn` | running indicator |
| `CellbookDone` | `DiagnosticOk` | execution count |
| `CellbookError` | `DiagnosticError` | error state |
| `CellbookStale` | `Comment` | source changed after run |
| `CellbookOutput` | `Normal` | plain output text |
| `CellbookOutputStderr` | `DiagnosticWarn` | stderr stream |
| `CellbookOutputTruncated` | `NonText` | "N more lines" marker |
| `CellbookMagic` | `PreProc` | `%magic` / `!shell` lines |

## Deprecation policy

Removed or renamed API functions keep a shim for one minor release that calls `vim.deprecate()`.
