# Implementation Plan: Notebook Core

**Branch**: `001-notebook-core` | **Date**: 2026-11-12 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-notebook-core/spec.md`

## Summary

Deliver native Jupyter notebook support in Neovim: `.ipynb` files open as a single editable buffer in percent format (cells separated by delimiter lines tracked with extmarks), code cells run against a real Jupyter kernel through a stdio NDJSON bridge written in Python on top of `jupyter_client`, outputs render as virtual lines (text) and through image-backend adapters (snacks.nvim, image.nvim), and saving writes byte-identical, nbformat-compliant JSON using a Jupyter-compatible Lua encoder. Zero-config, `:checkhealth`-guided setup, no Python remote-plugin host.

## Technical Context

**Language/Version**: Lua 5.1 / LuaJIT (Neovim runtime); Python ≥ 3.9 for the kernel bridge
**Primary Dependencies**: Neovim ≥ 0.11 APIs (`vim.system`, extmarks, `virt_lines`, `vim.json`, `vim.uv`, `vim.ui`); Python `jupyter_client` ≥ 8 (bridge); optional `snacks.nvim` or `image.nvim` (images)
**Storage**: `.ipynb` files (nbformat 4.x JSON); image cache in `stdpath("cache")/cellbook/`
**Testing**: `mini.test` (Lua, headless child Neovim, screenshot tests); `pytest` (bridge); `nbformat.validate` in CI
**Target Platform**: Neovim stable + nightly on Linux and macOS (tier 1), WSL (tier 2)
**Project Type**: Single project — Neovim plugin with an embedded Python helper
**Performance Goals**: startup < 1 ms; open 5 MB / 300 cells < 200 ms; keystroke latency < 16 ms during 1,000 lines/s output streaming
**Constraints**: no `pynvim`; no blocking I/O on the main loop; byte-identical round-trip; no hard plugin dependencies
**Scale/Scope**: notebooks up to ~20 MB / 2,000 cells; up to ~10 concurrent kernels per Neovim instance; ~6–8k lines of Lua + ~600 lines of Python at v1.0

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Check | Status |
|---|---|---|
| I. Native notebook, zero conversion | `BufReadCmd`/`BufWriteCmd` on `*.ipynb`; custom encoder for byte-identical output (research R3) | PASS |
| II. One-line install, self-diagnosing | stdio bridge, no pynvim (R1); `:checkhealth cellbook` (US6); `setup()` optional | PASS |
| III. Neovim-native editing | Code cells are real text with kernel filetype; outputs are extmarks (R2, R4); buffer-local keymaps | PASS |
| IV. Performance budgets | lazy `plugin/` file; async `vim.system`; incremental cell tracking on `on_lines` | PASS (verify with benchmarks T090–T092) |
| V. Test-first format layer | Phase 2 writes round-trip and parser tests before implementation; fixture corpus | PASS |
| VI. Small core, pluggable edges | Renderer adapter interface; no hard deps | PASS |
| VII. Documentation is a feature | vimdoc + README tasks in every phase; demo GIF before launch | PASS |

Post-design re-check (after Phase 1): PASS — no violations; see Complexity Tracking for one justified deviation.

## Project Structure

### Documentation (this feature)

```text
specs/001-notebook-core/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── lua-api.md
│   ├── bridge-protocol.md
│   └── commands-keymaps-config.md
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
cellbook.nvim/
├── plugin/
│   └── cellbook.lua               # autocmds for *.ipynb, :Cellbook command (lazy requires only)
├── lua/cellbook/
│   ├── init.lua                   # public API: setup(), run_cell(), ... (contracts/lua-api.md)
│   ├── config.lua                 # defaults, validation (vim.validate), merge
│   ├── health.lua                 # :checkhealth cellbook
│   ├── commands.lua               # :Cellbook subcommands + completion
│   ├── keymaps.lua                # buffer-local default mappings, text objects
│   ├── events.lua                 # User autocmd emitters
│   ├── format/
│   │   ├── json.lua               # Jupyter-compatible JSON encoder (sorted keys, indent=1)
│   │   ├── ipynb.lua              # parse/serialize nbformat 4.x ↔ Notebook model
│   │   └── percent.lua            # Notebook model ↔ buffer lines (delimiters, comment prefixes)
│   ├── model/
│   │   ├── notebook.lua           # Notebook entity, registry by bufnr
│   │   ├── cell.lua               # Cell entity, id generation
│   │   └── outputs.lua            # Output normalization, MIME selection
│   ├── buffer/
│   │   ├── attach.lua             # BufReadCmd/BufWriteCmd handlers, buffer options
│   │   ├── tracker.lua            # extmark-based cell boundary tracking, on_lines sync
│   │   ├── decor.lua              # cell headers, conceal, highlights, state indicators
│   │   └── ops.lua                # add/delete/move/split/merge/convert cells (undo-aware)
│   ├── kernel/
│   │   ├── bridge.lua             # spawn bridge, NDJSON framing, request/response, events
│   │   ├── session.lua            # Kernel Session: state machine, execution queue
│   │   └── specs.lua              # kernelspec listing/selection, python discovery
│   ├── render/
│   │   ├── text.lua               # virt_lines rendering, truncation, full-view split
│   │   ├── ansi.lua               # ANSI SGR → highlight chunks (cached hl groups)
│   │   ├── image.lua              # adapter registry + selection + cache files
│   │   └── adapters/
│   │       ├── snacks.lua
│   │       ├── image_nvim.lua
│   │       └── placeholder.lua
│   ├── lsp.lua                    # diagnostic filter for magics / shell escapes
│   └── status.lua                 # statusline/winbar component
├── python/
│   └── cellbook_bridge.py         # stdio NDJSON ↔ jupyter_client bridge
├── queries/
│   └── python/injections.scm      # markdown injection for markdown-cell comments (optional)
├── doc/
│   └── cellbook.txt               # vimdoc
├── tests/
│   ├── minimal_init.lua
│   ├── fixtures/notebooks/        # ≥ 50 real-world .ipynb files
│   ├── unit/                      # json, ipynb, percent, ansi, outputs, config
│   ├── integration/               # buffer attach/save, tracker, ops, keymaps, render
│   ├── e2e/                       # real kernel execution (requires ipykernel)
│   ├── bench/                     # open/scroll/stream benchmarks
│   └── python/test_bridge.py      # pytest for the bridge
├── scripts/
│   ├── test.sh                    # run mini.test suites
│   └── make_fixtures.py           # generate/validate fixtures with nbformat
├── .github/workflows/
│   ├── ci.yml                     # matrix: os × nvim × python; lint (stylua, selene, ruff)
│   └── release.yml                # release-please + luarocks upload
├── README.md
├── CHANGELOG.md
├── CONTRIBUTING.md
├── LICENSE
├── .stylua.toml
├── selene.toml
└── cellbook.nvim-scm-1.rockspec   # optional: rocks.nvim / luarocks distribution
```

**Structure Decision**: Single-project Neovim plugin layout (`plugin/`, `lua/`, `doc/`, `tests/`) with an embedded `python/` helper. Layers are strictly ordered: `format` (pure, no Neovim UI APIs) → `model` → `buffer` / `kernel` → `render` → public API. `format/` and `model/` must be testable without a UI.

## Architecture

### Data flow

```text
:e nb.ipynb
   │ BufReadCmd
   ▼
format/ipynb.parse(json) ──► model.Notebook ──► format/percent.to_lines() ──► buffer text
                                   │                                       buffer/tracker (extmarks per cell)
                                   │                                       buffer/decor (headers, conceal)
                                   ▼
                         render/text + render/image ◄── outputs per cell

run cell
   │ keymap / :Cellbook run
   ▼
kernel/session.execute(cell) ──NDJSON──► python/cellbook_bridge.py ──ZMQ──► Jupyter kernel
   ▲                                              │
   └──────────── iopub events (stream/display/error/status) ◄┘
           model.Cell.outputs updated → render (scheduled via vim.schedule, throttled)

:w
   │ BufWriteCmd
   ▼
buffer/tracker.read_cells() → model.Notebook (sources) → format/ipynb.serialize() → format/json.encode() → disk
```

### Key design decisions

1. **Model owns the document, buffer owns the text.** The Notebook model keeps the decoded JSON (all metadata, outputs). On save, cell sources are read from the buffer ranges given by the tracker; everything else comes from the model. Unchanged cells reuse their original JSON values verbatim, which is what makes the round-trip exact.
2. **Cell identity = extmark.** Each cell has one extmark at its delimiter line (`id → extmark_id`). `nvim_buf_attach` `on_lines` callbacks mark touched cells dirty in O(changed lines). If a delimiter line is deleted by the user, the tracker merges the two cells (and the operation is undoable); if delimiter text is typed manually, the next `:w` or `:Cellbook sync` creates a new cell.
3. **Undo safety.** Structural operations go through `buffer/ops.lua`, which edits text with `nvim_buf_set_lines` in a single undo block (`undojoin` where needed) and records a structural snapshot keyed by `changedtick`. On `undo`/`redo` (detected via `on_lines` + `b:changedtick` comparison with `undotree()` seq), the tracker re-derives cells from delimiter lines and reattaches outputs by cell id stored in the delimiter's extmark data snapshot.
4. **Async everywhere.** The bridge runs under `vim.system({python, bridge_path}, {stdin = true, stdout = on_stdout})`. Lines are buffered and decoded; each message is dispatched via `vim.schedule`. Render updates for streaming outputs are coalesced at most every 30 ms per cell.
5. **Kernel session state machine:** `starting → idle ⇄ busy → (restarting → idle) | dead | shutdown`. Execution queue is FIFO per session; `run all` enqueues all; an `error` reply cancels the rest of the batch.
6. **Rendering budget.** Only outputs for cells intersecting the visible window range (+1 screen margin) are rendered as images; text outputs are always rendered but truncated. Recomputed on `WinScrolled`/`WinResized` (debounced 50 ms).

### Error handling

- Parse errors → read-only raw view, `vim.notify` with JSON error position, buffer marked `nomodifiable`; `BufWriteCmd` refuses to write.
- Bridge cannot start → actionable notify pointing to `:checkhealth cellbook`.
- Bridge crash → session `dead`, running cell marked error with message, offer restart.
- Write failure → standard `E212`-style error, buffer stays modified.

### Configuration (defaults)

See `contracts/commands-keymaps-config.md`. Highlights: `python = nil` (auto), `output.max_lines = 30`, `image.backend = "auto"`, `keymaps = true`, `run_all.stop_on_error = true`, `kernel.shutdown_on_close = true`.

## Phases

| Phase | Goal | Output | Exit criteria |
|---|---|---|---|
| 0. Research | Resolve unknowns | `research.md` | Done (R1–R10) |
| 1. Design | Model, contracts, quickstart | `data-model.md`, `contracts/*`, `quickstart.md` | Constitution re-check PASS |
| 2. Foundation | Repo, CI, JSON encoder, parser, fixtures (tests first) | `format/*`, CI green | SC-001 round-trip passes on corpus |
| 3. US1 Open/edit/save | Buffer attach, tracker, decor, ops (basic) | v0.1.0-alpha (private) | US1 acceptance tests pass |
| 4. US2 Execution | Bridge, session, text outputs | v0.2.0 (soft launch to testers) | US2 tests pass; e2e with ipykernel |
| 5. US3 Rich outputs | Image adapters, truncation, full view | v0.3.0 **public launch** | US3 tests; demo GIF recorded |
| 6. US4 Navigation | Motions, text objects, move/split/merge/convert, statusline | v0.4.0 | US4 tests |
| 7. US5 Kernels | Kernel select, restart/dead handling, cleanup | v0.5.0 | US5 tests; no orphan processes |
| 8. US6 Health + polish | checkhealth, docs, perf benchmarks | v1.0.0 | All SC met; LazyVim extra PR opened |

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Custom JSON encoder instead of `vim.json.encode` | Byte-identical round-trip (Constitution I) requires sorted keys + `indent=1` + Python float/escape formatting | `vim.json.encode` produces unsorted, unindented output → noisy diffs on every save |
| Python bridge process (second language) | Jupyter kernels speak ZeroMQ; no portable Lua ZMQ | Pure Lua/FFI ZMQ requires system libzmq; pynvim violates Constitution II |
