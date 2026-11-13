# Data Model: Notebook Core

**Feature**: `001-notebook-core` | **Date**: 2026-11-12

All entities live in Lua (`lua/cellbook/model/`). Types are written in LuaCATS annotations so `lua_ls` can check them.

---

## Notebook

One per notebook buffer. Registry: `require("cellbook.model.notebook").get(bufnr)`.

```lua
---@class cellbook.Notebook
---@field bufnr integer                 Buffer holding the percent-format text
---@field path string                   Absolute path of the .ipynb file
---@field raw table                     Full decoded JSON document (source of truth for unknown fields)
---@field nbformat integer              Major version (must be 4)
---@field nbformat_minor integer        0..5 (decides whether new cells get ids)
---@field metadata table                Reference into raw.metadata (kernelspec, language_info, ...)
---@field cells cellbook.Cell[]         Ordered cells, mirrors buffer order
---@field cell_by_id table<string, cellbook.Cell>
---@field language string               Kernel language ("python", "r", "julia", ...)
---@field comment_prefix string         Prefix for markdown/raw lines (e.g. "# ")
---@field session cellbook.KernelSession?  Attached kernel session, nil until first run
---@field readonly boolean              True for parse failures / nbformat 3
---@field original_bytes string?        Kept only for files < 2 MB, used by round-trip self-check in debug mode
```

**Validation rules**
- `nbformat == 4`; otherwise `readonly = true`.
- `cells` order always equals the order of cell extmarks in the buffer (tracker invariant, asserted in debug mode).
- `language` resolution order: `metadata.kernelspec.language` → `metadata.language_info.name` → config `default_language` → `"python"`.

**State transitions**: `loading → ready ⇄ dirty → (saving → ready)`; `ready|dirty → readonly` only on parse failure at load time.

---

## Cell

```lua
---@alias cellbook.CellType "code"|"markdown"|"raw"
---@alias cellbook.RunState "idle"|"queued"|"running"|"done"|"error"|"interrupted"|"cancelled"

---@class cellbook.Cell
---@field id string?                    nbformat cell id (nil for nbformat_minor < 5)
---@field type cellbook.CellType
---@field mark integer                  Extmark id on the delimiter line (namespace cellbook.cells)
---@field raw table?                    Original JSON object of the cell (nil for new cells)
---@field source_dirty boolean          Source changed since load/save
---@field outputs cellbook.Output[]     Code cells only; empty for others
---@field outputs_dirty boolean         Outputs changed since load/save
---@field execution_count integer|vim.NIL
---@field run_state cellbook.RunState
---@field run_started_at number?        vim.uv.hrtime() when running started
---@field msg_id string?                Jupyter msg_id of the current execute_request
---@field collapsed_output boolean      User toggled outputs hidden
```

**Validation rules**
- New cell id: 8–12 chars from `[a-zA-Z0-9-_]`, unique within notebook (nbformat 4.5 rule: 1–64 chars matching `^[a-zA-Z0-9-_]+$`).
- `outputs` MUST be empty for `markdown`/`raw` cells; converting a code cell to markdown drops outputs and `execution_count`.
- `source` is never stored on the cell while the buffer is loaded; it is read from the buffer range `[delimiter_row + 1, next_delimiter_row)` and comment prefixes are stripped for markdown/raw.
- Source serialization: list of lines each ending with `"\n"` except the last (nbformat convention). If `raw.source` was a single string, keep the string form.

**Run state transitions**

```text
idle ──run──► queued ──kernel picks──► running ──execute_reply ok──► done
                 │                         ├──execute_reply error──► error
                 │                         └──interrupt──► interrupted
                 └──batch cancelled / restart──► cancelled
done|error|interrupted|cancelled ──run──► queued
any ──edit source──► (state kept; header shows "stale" marker if done)
```

---

## Output

```lua
---@alias cellbook.OutputType "stream"|"execute_result"|"display_data"|"error"

---@class cellbook.Output
---@field type cellbook.OutputType
---@field raw table                     Original/received JSON object (preserved verbatim on save)
---@field name string?                  stream: "stdout"|"stderr"
---@field text string?                  stream text (appended while streaming)
---@field data table<string, any>?      MIME bundle for execute_result/display_data
---@field metadata table?               output metadata (e.g. image size)
---@field display_id string?            transient.display_id for update_display_data
---@field ename string?                 error
---@field evalue string?                error
---@field traceback string[]?           error (with ANSI codes)
---@field view cellbook.OutputView?     render handle, never serialized
```

**Rules**
- Consecutive `stream` messages with the same `name` are merged into one output (Jupyter behavior).
- `\r` handling in streams: carriage return rewrites the current line (progress bars like tqdm).
- `clear_output(wait=true)` clears on the next output message; `wait=false` clears immediately.
- `update_display_data` replaces `data` of the output with the same `display_id` (search across all cells of the notebook).
- On save, outputs received from the kernel are converted to nbformat form: `execute_result` gets `execution_count`; `transient` is dropped; multiline MIME strings are split into line lists.

### OutputView (render-only)

```lua
---@class cellbook.OutputView
---@field kind "text"|"image"|"placeholder"
---@field extmark integer?              virt_lines extmark id
---@field image_handle any?             adapter handle
---@field truncated boolean
---@field line_count integer
```

---

## KernelSession

```lua
---@alias cellbook.KernelState "starting"|"idle"|"busy"|"restarting"|"dead"|"shutdown"

---@class cellbook.KernelSession
---@field id string                     Local session id
---@field kernel_name string            kernelspec name (e.g. "python3")
---@field display_name string
---@field python string                 Interpreter running the bridge
---@field proc vim.SystemObj            Bridge process
---@field state cellbook.KernelState
---@field queue cellbook.Cell[]         Pending executions (FIFO)
---@field current cellbook.Cell?        Running cell
---@field pending table<integer, fun(result:any, err:string?)>  Request callbacks by request id
---@field notebooks table<integer, true>  Buffers using this session (normally one)
---@field started_at number
```

**State transitions**

```text
(spawn) starting ──kernel_ready──► idle ⇄ busy (status messages)
idle|busy ──restart──► restarting ──kernel_ready──► idle
any ──bridge exit / kernel died──► dead ──restart──► starting
any ──shutdown / VimLeavePre / last buffer wiped──► shutdown (terminal)
```

**Invariants**
- At most one `current` cell; `queue` never contains the same cell twice.
- On `dead` or `restarting`, `current` → `interrupted`/`cancelled`, all `queue` cells → `cancelled`.

---

## RendererAdapter

```lua
---@class cellbook.RendererAdapter
---@field name string
---@field available fun(): boolean, string?   -- returns ok, reason
---@field supports fun(mime: string): boolean
---@field render fun(bufnr: integer, row: integer, file: string, opts: {width:integer?, height:integer?, win:integer}): any  -- handle
---@field clear fun(handle: any)
```

Selection: `config.image.backend` (`"auto"|"snacks"|"image.nvim"|"none"`). `auto` picks the first available in order snacks → image.nvim → placeholder.

---

## Config (validated)

Defined in `contracts/commands-keymaps-config.md`. Stored once in `require("cellbook.config").values`; per-buffer overrides via `vim.b.cellbook_config`.

---

## Relationships

```text
Notebook 1 ── * Cell 1 ── * Output 1 ── 0..1 OutputView
Notebook * ── 0..1 KernelSession (sessions keyed by notebook path; one session per notebook by default)
OutputView * ── 1 RendererAdapter (images only)
```
