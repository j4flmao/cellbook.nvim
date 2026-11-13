# Feature Specification: Notebook Core (open, edit, run, render, save `.ipynb` in Neovim)

**Feature Branch**: `001-notebook-core`
**Created**: 2026-11-12
**Status**: Draft
**Input**: User description: "A long-term Neovim plugin with high star potential: native Jupyter notebook support inside Neovim — open `.ipynb` directly, run cells against a real kernel, see outputs (including images) under each cell, save back to `.ipynb` losslessly, one-line install."

## Background & Problem

Jupyter notebooks are the main reason many data/ML users keep VS Code or JupyterLab alongside Neovim. Existing Neovim options are fragmented: molten-nvim (~1.2k stars) requires the Python remote-plugin host and a multi-step setup; jupytext-based setups require conversion; jupynium and neopyter drive a browser instance; several smaller plugins cover only one part of the workflow. No single plugin delivers "open the file, run it, see the output, save it" with a one-line install. This feature delivers that core loop.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Open, edit, and save a notebook losslessly (Priority: P1)

A data scientist opens `analysis.ipynb` with `:e analysis.ipynb`. They see every cell, clearly separated, with code cells highlighted as Python and markdown cells readable. They edit some code, add a cell, delete a cell, reorder two cells, and `:w`. The file opens correctly in JupyterLab and VS Code afterwards, with all metadata, cell IDs, and untouched outputs preserved.

**Why this priority**: Without trustworthy open/save, nothing else matters; one corrupted notebook loses a user forever. This story alone is already useful (editing notebooks with LSP and full Vim motions) and is shippable as an MVP.

**Independent Test**: Open each fixture notebook, save without changes and compare bytes; apply scripted edits, save, validate with `nbformat.validate`, and reopen in JupyterLab.

**Acceptance Scenarios**:

1. **Given** a valid nbformat 4.5 notebook, **When** the user opens and saves it without edits, **Then** the file on disk is byte-identical to the original.
2. **Given** an open notebook, **When** the user edits code in cell 3 and saves, **Then** only cell 3's `source` changes; its `outputs` and `execution_count` are kept unless the user cleared them.
3. **Given** an open notebook, **When** the user adds a cell with the "add cell below" action, **Then** a new code cell with a fresh nbformat-compliant `id` appears and is saved in the correct position.
4. **Given** a notebook with markdown, raw, and code cells, **When** opened, **Then** each cell type is visually distinguishable and code cells use the kernel language's filetype for highlighting and LSP.
5. **Given** a malformed `.ipynb` (invalid JSON), **When** opened, **Then** the user sees a clear error and the raw JSON is shown read-only; the file is never overwritten.

---

### User Story 2 - Run cells and see text outputs inline (Priority: P1)

The user presses a key on a code cell. A Python kernel starts automatically (using the notebook's kernelspec). The cell shows a running indicator, then its stdout, the repr of the last expression, and errors with tracebacks appear directly under the cell. The user can run the current cell, run and move to the next, run all, run all above, interrupt, and restart the kernel.

**Why this priority**: Execution is the core value of a notebook; together with US1 it forms the minimum product people would star.

**Independent Test**: With `ipykernel` installed, open a fixture notebook, run all cells, and assert outputs and execution counts match expected values; save and confirm outputs are persisted in nbformat.

**Acceptance Scenarios**:

1. **Given** a notebook with kernelspec `python3` and `ipykernel` installed, **When** the user runs a cell, **Then** the kernel starts without further prompts and the output appears under the cell.
2. **Given** a cell printing in a loop for 10 seconds, **When** running, **Then** output streams incrementally and Neovim remains responsive to typing.
3. **Given** a cell that raises an exception, **When** run, **Then** the traceback is shown with ANSI colors converted to highlights and the cell is marked as errored.
4. **Given** a running cell, **When** the user triggers interrupt, **Then** the kernel receives an interrupt and the cell is marked interrupted.
5. **Given** a queue of cells from "run all", **When** one errors, **Then** remaining queued cells are cancelled (Jupyter default behavior).
6. **Given** executed cells, **When** saved, **Then** outputs and `execution_count` are written in nbformat-compliant form.

---

### User Story 3 - Rich outputs: images, HTML tables, and long output (Priority: P2)

The user runs a cell that plots with matplotlib and a cell that displays a pandas DataFrame. The plot renders as an image under the cell in a supported terminal (kitty, WezTerm, Ghostty). The DataFrame renders as a readable text table. Long outputs are truncated with an action to expand or open in a split.

**Why this priority**: Plots and DataFrames are what make notebooks notebooks; this is the "wow" moment for the demo GIF, but it depends on US1/US2.

**Independent Test**: Run fixture cells producing `image/png`, `text/html` table, and 10,000-line stdout; assert correct renderer selection and truncation behavior with and without an image backend installed.

**Acceptance Scenarios**:

1. **Given** an image backend (snacks.nvim image or image.nvim) is available and the terminal supports graphics, **When** a cell outputs `image/png`, **Then** the image renders under the cell scaled to the window width.
2. **Given** no image backend, **When** a cell outputs an image, **Then** a placeholder line `[image/png 640×480 — open]` is shown and the open action opens it with the system viewer.
3. **Given** a DataFrame output with `text/html` and `text/plain`, **When** rendered, **Then** the plain-text table is shown by default.
4. **Given** output longer than the configured limit (default 30 lines), **When** rendered, **Then** it is truncated with a "N more lines" marker and an action to view the full output in a scratch split.

---

### User Story 4 - Navigate and manage cells efficiently (Priority: P2)

The user jumps between cells (`]c` / `[c`), selects a cell with text objects (`ic` / `ac`), moves cells up/down, changes cell type, splits and merges cells, clears outputs (one cell or all), and sees a winbar/statusline component showing kernel state and cell index.

**Why this priority**: Vim users expect motions and text objects; this is what makes the Neovim notebook experience better than a browser.

**Independent Test**: Scripted keystroke tests on fixture notebooks asserting resulting cell structure and cursor positions.

**Acceptance Scenarios**:

1. **Given** the cursor in cell 2, **When** the user presses `]c`, **Then** the cursor moves to the first line of cell 3.
2. **Given** the cursor in a cell, **When** the user types `dac`, **Then** the whole cell is deleted and can be restored with undo, including its outputs.
3. **Given** a code cell, **When** the user converts it to markdown, **Then** its outputs are dropped (per nbformat) and the change is undoable.

---

### User Story 5 - Kernel selection and management (Priority: P3)

The user picks a kernel from installed kernelspecs (e.g. a project virtualenv, R, Julia), sees kernel status (idle/busy/dead), and can restart, shut down, or reconnect. When a notebook has no kernelspec or an unknown one, they are prompted with `vim.ui.select`.

**Why this priority**: Required for real projects with virtualenvs and non-Python kernels, but Python default covers most early users.

**Independent Test**: With two kernelspecs installed, switch kernels and verify execution happens in the selected environment (`sys.executable`).

**Acceptance Scenarios**:

1. **Given** multiple kernelspecs, **When** the user runs `:Cellbook kernel select`, **Then** a `vim.ui.select` list shows display names and the choice is saved into notebook metadata.
2. **Given** a kernel that dies, **When** the user runs a cell, **Then** they are told the kernel died and offered a restart.
3. **Given** Neovim exits, **When** notebooks have running kernels, **Then** all kernels and bridge processes are shut down (no orphan processes).

---

### User Story 6 - Diagnose setup with checkhealth (Priority: P3)

A new user installs the plugin and runs `:checkhealth cellbook`. They get a list of OK/WARN/ERROR lines for: Neovim version, Python found, `jupyter_client` importable, at least one kernelspec, image backend presence, terminal graphics support — each failure with an exact command to fix it.

**Why this priority**: Directly drives adoption and reduces issue volume; cheap to build after the bridge exists.

**Independent Test**: Run checkhealth in CI containers with each dependency removed in turn; assert the expected messages.

**Acceptance Scenarios**:

1. **Given** `jupyter_client` is not installed, **When** checkhealth runs, **Then** it reports ERROR with `python3 -m pip install jupyter_client ipykernel`.
2. **Given** everything is installed, **When** checkhealth runs, **Then** all core checks are OK and optional checks are OK or INFO.

### Edge Cases

- Notebook with nbformat 4.0–4.4 (no cell `id`): preserved as-is on save; IDs are only added if the user adds cells AND nbformat minor ≥ 5, otherwise new cells get no id.
- Notebook with nbformat 3: opened read-only with a message suggesting `jupyter nbconvert --to notebook --nbformat 4`.
- File modified on disk while open (e.g. by JupyterLab): standard Neovim `FileChangedShell` flow; reload re-parses the notebook.
- Cell source containing the cell-delimiter text (e.g. a literal `# %%` line in a string): must not split the cell (delimiters are tracked by extmarks, not by text parsing, while the buffer is open).
- Very large outputs (e.g. 50 MB base64 images): not loaded into Lua strings for rendering beyond what is displayed; preserved on save.
- Outputs with `application/vnd.jupyter.widget-view+json` (ipywidgets): preserved on save, rendered as a placeholder `[widget — not supported]`.
- Notebook trusted/untrusted state (`metadata.trusted`): never executes anything on open; execution only on explicit user action.
- CRLF files and non-UTF-8 content: preserved; invalid UTF-8 triggers read-only mode with an error.
- Two windows on the same notebook buffer: outputs render in both.
- `:saveas`, `:w other.ipynb`, `:w copy.py`: `.ipynb` targets write nbformat; other targets write the plain buffer text.

## Requirements *(mandatory)*

### Functional Requirements

**Format & buffer**
- **FR-001**: The system MUST intercept reading and writing of `*.ipynb` files (`BufReadCmd`/`BufWriteCmd`/`FileReadCmd`/`FileWriteCmd`) and present the notebook as a single editable buffer.
- **FR-002**: The system MUST parse nbformat 4.0–4.5 and preserve every unknown or unused field (notebook metadata, cell metadata, attachments, outputs, widget state) on save.
- **FR-003**: The system MUST serialize with Jupyter-compatible formatting (`indent=1`, keys sorted, `ensure_ascii=False`, trailing newline) so that unmodified notebooks round-trip byte-identically.
- **FR-004**: The system MUST track cell boundaries with extmarks so that edits never accidentally merge or split cells.
- **FR-005**: Code cells MUST use the kernel language's filetype (from `metadata.kernelspec.language` or `language_info.name`, default `python`) so LSP and Treesitter attach.
- **FR-006**: Markdown cells MUST be visually distinct and readable; raw cells MUST be preserved verbatim.
- **FR-007**: The system MUST support undo/redo of structural cell operations (add, delete, move, split, merge, change type) as normal Neovim undo steps.

**Execution**
- **FR-010**: The system MUST start a kernel lazily on first execution using the notebook's kernelspec, via a bridge process communicating over stdio with newline-delimited JSON.
- **FR-011**: The system MUST support: run cell, run cell and advance, run all, run above, run below, run selection (visual), interrupt, restart, restart-and-run-all, shutdown.
- **FR-012**: The system MUST stream `stream`, `execute_result`, `display_data`, `update_display_data`, `error`, and `clear_output` messages into the cell's outputs as they arrive.
- **FR-013**: Execution MUST never block the Neovim main loop.
- **FR-014**: The system MUST show per-cell state: queued, running (with elapsed time), done (execution count), error, interrupted.
- **FR-015**: The system MUST shut down all kernels and bridge processes on `VimLeavePre` and when the last buffer for a notebook is wiped.

**Rendering**
- **FR-020**: The system MUST render text outputs as virtual lines below the cell, converting ANSI color codes to highlight groups.
- **FR-021**: The system MUST choose the richest supported MIME type in a configurable priority order (default: `image/png`, `image/jpeg`, `image/svg+xml` (only when the image backend supports it), `text/markdown`, `text/plain`); `text/html` falls back to `text/plain`.
- **FR-022**: The system MUST render images through an adapter interface with implementations for snacks.nvim image and image.nvim, falling back to a placeholder with an "open externally" action.
- **FR-023**: The system MUST truncate outputs beyond a configurable line limit and offer a full view in a scratch split.
- **FR-024**: Output rendering MUST be toggleable per cell and globally (hide/show outputs).

**Navigation & UX**
- **FR-030**: The system MUST provide buffer-local defaults: `]c`/`[c` (next/prev cell), `ic`/`ac` text objects, and `<localleader>` mappings for run/add/delete/move/convert/clear; all overridable or disable-able via config.
- **FR-031**: The system MUST provide a single `:Cellbook {subcommand}` user command with completion.
- **FR-032**: The system MUST expose a statusline/winbar function returning kernel name, state, and current cell index.
- **FR-033**: The system MUST provide `:checkhealth cellbook` covering all dependencies with fix commands.

**Configuration & API**
- **FR-040**: The plugin MUST work with zero configuration; `require("cellbook").setup(opts)` is optional and validated with clear errors for unknown keys.
- **FR-041**: The system MUST expose a documented Lua API (see `contracts/lua-api.md`) and `User` autocommand events (`CellbookKernelStarted`, `CellbookCellExecuted`, etc.) for integrations.

### Key Entities

- **Notebook**: A parsed `.ipynb` document bound to one buffer: format version, metadata, ordered list of cells, kernel binding, dirty state.
- **Cell**: One notebook cell: id, type (code/markdown/raw), source (buffer range via extmarks), metadata, outputs, execution count, run state.
- **Output**: One output entry: type, MIME bundle, metadata, rendered view (virtual lines or image handle).
- **Kernel Session**: A running kernel managed by one bridge process: kernelspec, state, execution queue, message routing to cells.
- **Renderer Adapter**: A pluggable implementation that can display an image MIME output at a buffer position and clear it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of the fixture corpus (≥ 50 real-world notebooks from JupyterLab, VS Code, Colab, Kaggle) round-trips byte-identically when opened and saved without edits.
- **SC-002**: A new user goes from install to running their first cell in under 3 minutes, following only the README and `:checkhealth` (measured with 5 test users before launch).
- **SC-003**: Opening a 5 MB / 300-cell notebook renders in under 200 ms; startup time impact under 1 ms (`nvim --startuptime`).
- **SC-004**: During streaming output of 1,000 lines/second, typing latency stays under 16 ms per keystroke.
- **SC-005**: Zero data-loss bugs open at each release; every `data-loss` issue fixed within 72 hours.
- **SC-006**: Adoption targets (non-functional, tracked in ROADMAP.md): 500 GitHub stars within 30 days of the v0.3 public launch; 1,500 within 12 months; inclusion as a LazyVim extra within 12 months.

## Assumptions

- Users who want to run code have (or can install) Python ≥ 3.9 with `jupyter_client` and a kernel such as `ipykernel`; non-Python kernels still need Python for the bridge.
- Image rendering is only expected in terminals supporting the kitty graphics protocol (kitty, WezTerm, Ghostty) or via the user's chosen backend; other terminals use placeholders.
- ipywidgets, interactive HTML/JS outputs, and collaborative editing are out of scope for this feature.
- Remote Jupyter servers (over HTTP/WebSocket), notebook diff/merge, and AI features are future specs (see ROADMAP.md).

## Out of Scope

- Rendering arbitrary HTML/JavaScript outputs.
- ipywidgets interactivity.
- Real-time collaboration.
- Connecting to remote Jupyter servers (planned: spec 004).
- Converting to/from other formats (`.py`, `.md`, Quarto) — users can rely on jupytext.

## Clarifications

### Session 2026-11-12

- Q: Should the plugin require users to work on a `.py` mirror (jupytext) instead of the `.ipynb`? → A: No. The `.ipynb` is edited directly; any intermediate representation is internal and never written to disk.
- Q: Should the plugin use Neovim's Python remote-plugin host? → A: No. A standalone bridge process over stdio (Constitution II).
- Q: Default output limit? → A: 30 visible lines per output, configurable.
- Q: Behavior when "run all" hits an error? → A: Stop and cancel the remaining queue (matches JupyterLab).
