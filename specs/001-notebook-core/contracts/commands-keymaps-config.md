# Contract: Commands, Keymaps, Configuration (v1)

## `:Cellbook` command

Single command with subcommand completion. All subcommands act on the current notebook buffer.

| Subcommand | Action | Lua API |
|---|---|---|
| `run` | Run current cell (with range: run selected lines) | `run_cell` / `run_range` |
| `run_next` | Run and move to next | `run_cell_and_next` |
| `run_all` | Run all cells | `run_all` |
| `run_above` / `run_below` | Run cells above / from current | `run_above` / `run_below` |
| `interrupt` | Interrupt kernel | `interrupt` |
| `restart [run_all]` | Restart kernel (optionally run all) | `restart` |
| `shutdown` | Shut down kernel | `shutdown` |
| `kernel` | Select kernel | `select_kernel` |
| `add [above\|below] [code\|markdown\|raw]` | Add cell | `add_cell` |
| `delete` | Delete cell | `delete_cell` |
| `move up\|down` | Move cell | `move_cell` |
| `split` / `merge [above\|below]` | Split / merge cells | `split_cell` / `merge_cell` |
| `type code\|markdown\|raw` | Change cell type | `set_cell_type` |
| `clear [all]` | Clear outputs | `clear_output` |
| `toggle [all]` | Hide/show outputs | `toggle_output` |
| `open` | Open full output | `open_output` |
| `info` | Show notebook + kernel info in a float | — |
| `log` | Open bridge/kernel log buffer | — |
| `raw` | Open the raw JSON read-only in a split | — |
| `refresh` | Re-render decorations and outputs (after config changes) | — |

Unknown subcommand → error listing valid ones. `:Cellbook` alone opens `vim.ui.select` with all subcommands.

## Default buffer-local keymaps

Applied only in notebook buffers, only if `keymaps = true` (default). Each mapping has a `desc` (shows in which-key).

| Mode | Key | Action |
|---|---|---|
| n | `]c` / `[c` | Next / previous cell (falls back to diff `]c` when `&diff`) |
| o, x | `ic` / `ac` | Inner cell (source) / around cell (with delimiter) |
| n | `<S-CR>` | Run cell and go to next |
| n | `<C-CR>` | Run cell (stay) |
| x | `<C-CR>` | Run selection |
| n | `<localleader>r` | Run cell |
| n | `<localleader>R` | Run all |
| n | `<localleader>a` / `<localleader>b` | Add code cell above / below |
| n | `<localleader>m` | Toggle cell type code ↔ markdown |
| n | `<localleader>d` | Delete cell |
| n | `<localleader>k` / `<localleader>j` | Move cell up / down |
| n | `<localleader>s` | Split cell at cursor |
| n | `<localleader>J` | Merge with cell below |
| n | `<localleader>c` / `<localleader>C` | Clear output / clear all outputs |
| n | `<localleader>o` | Open full output |
| n | `<localleader>i` | Interrupt |
| n | `<localleader>0` | Restart kernel |
| n | `<localleader>K` | Select kernel |

Note: `<S-CR>`/`<C-CR>` need a terminal that reports them (kitty, WezTerm, Ghostty, Alacritty with CSI u). Documented in checkhealth as INFO.

Customize:

```lua
require("cellbook").setup({
  keymaps = {
    run_cell = "<leader>jr",   -- remap
    run_all = false,           -- disable one
  },
})
-- or keymaps = false to disable all and map the Lua API yourself
```

## Configuration

```lua
---@class cellbook.Config
local defaults = {
  -- Python used to run the bridge. nil = auto: $VIRTUAL_ENV/bin/python, $CONDA_PREFIX/bin/python, python3, python
  python = nil,

  -- Language used when the notebook has no kernelspec/language_info
  default_language = "python",

  kernel = {
    -- Kernel to use when the notebook has none. nil = prompt with vim.ui.select
    default = nil,
    -- Start the kernel on open instead of on first run
    autostart = false,
    -- Shut down the kernel when the last window/buffer of the notebook closes
    shutdown_on_close = true,
    -- Working directory for the kernel: "notebook" (file's dir) | "cwd"
    cwd = "notebook",
  },

  run_all = {
    stop_on_error = true,
  },

  output = {
    max_lines = 30,            -- truncate visible lines per output
    max_line_width = nil,      -- nil = window width
    show_stderr = true,
    ansi = true,               -- convert ANSI colors
    mime_priority = { "image/png", "image/jpeg", "image/svg+xml", "text/markdown", "text/plain" },
    virt_lines_leftcol = false,
  },

  image = {
    backend = "auto",          -- "auto" | "snacks" | "image.nvim" | "none"
    max_height = 20,           -- in terminal rows
    max_width = nil,           -- nil = window width
    only_visible = true,       -- render images only for visible cells
  },

  ui = {
    cell_header = true,        -- decorated delimiter lines
    show_execution_time = true,
    conceal_comment_prefix = true,
    border_char = "─",
    icons = { running = "", done = "", error = "", queued = "", stale = "" },
  },

  lsp = {
    filter_magic_diagnostics = true,
  },

  keymaps = true,              -- boolean or table of { action = lhs|false }

  save = {
    -- Strip outputs on save (useful for git-tracked notebooks)
    strip_outputs = false,
  },

  debug = false,               -- extra assertions + round-trip self-check
}
```

**Validation**: `setup()` validates types with `vim.validate` and warns (does not error) on unknown keys, listing the nearest valid key ("did you mean `output.max_lines`?").

**Per-buffer override**: `vim.b.cellbook_config = { output = { max_lines = 100 } }` before or after attach (re-render on change via `:Cellbook refresh`).
