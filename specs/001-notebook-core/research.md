# Research: Notebook Core

**Feature**: `001-notebook-core` | **Date**: 2026-11-12

This document resolves every technical unknown in `plan.md`. Each entry: Decision, Rationale, Alternatives considered.

---

## R1. How does Neovim talk to a Jupyter kernel?

**Decision**: A small Python bridge script (`python/cellbook_bridge.py`, shipped with the plugin) started with `vim.system()` / `vim.fn.jobstart()`. It uses `jupyter_client` (`KernelManager` + `AsyncKernelClient`) and speaks newline-delimited JSON (NDJSON) over stdin/stdout with Lua. One bridge process per kernel session.

**Rationale**:
- Jupyter kernels speak ZeroMQ. Lua has no portable ZMQ binding without compiled C modules, which would break the one-line install.
- `jupyter_client` is the reference implementation; it handles connection files, heartbeats, kernelspec discovery, interrupts, and restarts correctly.
- A Python environment is required anyway to run `ipykernel`, so requiring `jupyter_client` adds minimal friction.
- NDJSON over stdio is trivial to parse in Lua (`vim.json.decode` per line), needs no ports, and dies with Neovim.
- Avoids `pynvim` and `:UpdateRemotePlugins`, the main setup pain point of molten-nvim (Constitution II).

**Alternatives considered**:
- *Neovim remote plugin (pynvim)*: rejected; fragile setup, a top complaint for existing plugins.
- *Jupyter Server REST + WebSocket from Lua*: requires users to run `jupyter server`, token handling, and a WebSocket client in Lua (no built-in). Kept as a future transport for remote kernels (spec 004).
- *Pure-Lua ZMQ via LuaJIT FFI to libzmq*: requires libzmq installed system-wide; platform-specific failures; rejected for core, possible optional transport later.
- *Driving a browser (jupynium/neopyter approach)*: heavy, needs a browser and a running Jupyter UI; rejected.

---

## R2. Buffer representation of a notebook

**Decision**: One buffer per notebook. Buffer text contains only cell sources, separated by a single delimiter line per cell (`# %%` for code, `# %% [markdown]` for markdown, `# %% [raw]` for raw — adapted to the language's comment string). Delimiter lines are decorated/concealed with extmarks (cell header with type, execution count, state). Cell boundaries are authoritative in extmarks while the buffer is loaded; text is used only to rebuild them after undo/redo when extmarks are invalidated.

**Rationale**:
- One buffer gives LSP a whole-file view (cross-cell go-to-definition, diagnostics), matching how users think of a notebook.
- Using the "percent format" delimiter keeps the buffer valid source code for the kernel language, so LSP, Treesitter, and formatters see a normal file.
- Markdown and raw cell content is stored as comment-prefixed lines (`# ` for Python, derived from `'commentstring'` for other languages), exactly like jupytext's percent format. The comment prefix is hidden with extmark `conceal`, and the cell range gets markdown highlighting through a Treesitter injection query (`; extends` injection for `comment` nodes inside markdown cells) or, at MVP, plain extmark highlights. The buffer therefore stays syntactically valid for the kernel language, so Treesitter's parser and the LSP never see prose as code.
- Typing in a markdown cell continues the comment prefix automatically via buffer-local `'comments'`/`'formatoptions'` (`ro`), so editing prose feels normal.
- On save, the prefix is stripped line by line; the round-trip is exact because the prefix is always added by the plugin, never by the user (a line the user types without the prefix is treated as content and prefixed on next render).
- Extmarks with `right_gravity`/`end_right_gravity` tuned per edge keep boundaries stable during edits.

**Alternatives considered**:
- *One buffer per cell (floating windows / splits)*: breaks LSP cross-cell context, makes motions across cells awkward; rejected.
- *Markdown cells as plain, uncommented lines*: nicer to edit, but the language's Treesitter parser produces ERROR nodes whose recovery can bleed into neighbouring code cells, and the LSP reports syntax errors; rejected for MVP. Revisit with a shadow document (R7).
- *Hidden metadata in buffer text*: rejected, pollutes buffer and breaks LSP.

**Open risk**: Concealed prefixes confuse some motions (`0`, `^`) for users with `conceallevel=0`. Mitigation: set `conceallevel=2`/`concealcursor=""` window-locally in notebook windows and document it.

---

## R3. Lossless round-trip of `.ipynb`

**Decision**: Keep the full decoded JSON document in Lua as the source of truth for everything except cell sources and outputs that changed. On save, rebuild only changed fields and serialize with a custom Lua JSON encoder that matches Python's `json.dumps(nb, indent=1, sort_keys=True, ensure_ascii=False) + "\n"`.

**Rationale**:
- `vim.json.encode` does not sort keys or indent, so it cannot match Jupyter's formatting.
- A custom encoder (~150 lines) gives deterministic output and byte-identical round-trip for unmodified notebooks.
- Source strings are stored as lists of lines (nbformat convention: each line keeps its `\n` except the last); we preserve whether the original used a string or list form per cell.
- Number formatting edge cases (floats like `1e-05`, large ints) are preserved by keeping original literal text where possible: the decoder records raw number tokens for metadata fields (decode with `luanil` options and a custom number path).

**Alternatives considered**:
- *Delegate save to the Python bridge (nbformat.write)*: would make saving depend on Python even for users who only edit; violates "edit works without Python". Kept as a validation tool in tests (`nbformat.validate`).
- *Use `vim.json.encode` and accept diffs*: rejected; noisy git diffs are a top reason people distrust notebook tools.

---

## R4. Rendering text outputs

**Decision**: Render outputs as `virt_lines` extmarks anchored to the last line of the cell, in a dedicated namespace. ANSI escape sequences are parsed into highlight chunks (SGR 0–107, 256-color and truecolor mapped to dynamically created highlight groups, cached).

**Rationale**:
- `virt_lines` don't affect buffer text, LSP, or undo (Constitution III).
- Neovim ≥ 0.10 supports `virt_lines` scrolling well; long outputs are capped to keep redraw fast (FR-023).

**Alternatives considered**:
- *Floating windows per output*: complicated positioning on scroll; rejected for MVP.
- *Real buffer lines*: breaks LSP and undo; rejected.

---

## R5. Rendering images

**Decision**: Define a renderer adapter interface (`render(bufnr, row, mime, data_path, opts) -> handle`, `clear(handle)`). Ship adapters for `snacks.nvim` image (folke) and `image.nvim` (3rd/image.nvim). Auto-detect at runtime; fallback adapter shows a placeholder line and an "open" action (`vim.ui.open`). Image bytes are decoded from base64 once, written to a cache file under `stdpath("cache")/cellbook/<sha256>.png`, and rendered from file.

**Rationale**:
- Terminal graphics (kitty protocol, sixel, tmux passthrough) are hard; both backends already solve them and have many users.
- Rendering from cached files avoids holding large binary data in Lua.
- `vim.ui.open` exists in Neovim ≥ 0.10.

**Alternatives considered**:
- *Own kitty-protocol implementation*: duplicate effort, many edge cases; rejected (Constitution VI).
- *Convert images to Unicode blocks (chafa)*: optional future fallback adapter.

`image/svg+xml` is rendered only if the backend supports it (snacks can convert via ImageMagick); otherwise placeholder.

---

## R6. Kernel discovery and selection

**Decision**: Bridge command `list_kernelspecs` returns `KernelSpecManager().get_all_specs()`. Default kernel = notebook `metadata.kernelspec.name`; if missing/not installed, prompt with `vim.ui.select`. Config option `python` sets the interpreter for the bridge (default: first of `$VIRTUAL_ENV/bin/python`, `python3`, `python`).

**Rationale**: Mirrors JupyterLab behavior, respects virtualenvs, and works with pickers via `vim.ui.select` overrides (telescope, fzf-lua, snacks).

---

## R7. LSP behavior with IPython magics and shell escapes

**Problem**: Real notebooks contain lines that are not valid Python: line magics (`%matplotlib inline`, `%timeit x`), cell magics (`%%bash`), shell escapes (`!pip install x`), and help syntax (`obj?`). The LSP reports syntax errors on them, and Treesitter marks them as ERROR.

**Decision (MVP)**: Wrap the `vim.diagnostic` display for notebook buffers (a namespace-agnostic filter via `vim.diagnostic.handlers` wrapper) to hide diagnostics on lines matching magic/shell patterns, and on whole cells starting with a cell magic (`%%`). Highlight magic lines with a dedicated highlight group (`CellbookMagic`).

**Decision (post-MVP, spec 002)**: Evaluate a "shadow document": attach the LSP to a hidden scratch buffer where magic lines are rewritten to valid placeholders of equal length (e.g. `pass  # ...`) and `%%` cells are blanked, mirroring edits incrementally. This removes noise from hover, completion, and code actions too.

**Rationale**: Diagnostic filtering is cheap and removes the most visible noise; the shadow document is more invasive and deserves its own spec.

---

## R8. Testing strategy

**Decision**:
- Lua unit/integration tests with `mini.test` (single dependency, runs headless, supports child Neovim processes and screenshot tests).
- Python bridge tests with `pytest` + real `ipykernel`.
- Fixture corpus in `tests/fixtures/notebooks/` (≥ 50 files, licensed for redistribution; sources: Jupyter docs examples, nbformat test files, self-made exports from JupyterLab/VS Code/Colab).
- Round-trip test: for every fixture, open → save → `cmp` bytes.
- Validation test: after scripted edits, run `nbformat.validate` via Python in CI.
- CI: GitHub Actions matrix {ubuntu-latest, macos-latest} × {nvim stable, nightly} × {python 3.9, 3.13}.

**Alternatives**: plenary/busted — widely used but heavier and plenary is in maintenance mode; mini.test chosen.

---

## R9. Plugin loading and startup cost

**Decision**: `plugin/cellbook.lua` registers only the `*.ipynb` autocommands and the `:Cellbook` command (both lazy `require`). No `setup()` call needed. Compatible with lazy.nvim (`ft`/`event` not even required) and with Neovim 0.12 `vim.pack`.

**Rationale**: Startup cost < 1 ms (Constitution IV); works with any plugin manager.

---

## R10. Naming and positioning

**Decision**: Provisional name `cellbook.nvim`. Before public launch, verify the name is unused on GitHub, LuaRocks, and dotfyle; alternatives: `nbook.nvim`, `jot.nvim`. Positioning line: "Jupyter notebooks in Neovim. Open the `.ipynb`, run it, see the plots. One-line install."

**Competitive landscape (as of research date)**: molten-nvim (~1.2k stars, remote-plugin host), jupynium.nvim (browser-driven), neopyter (browser/JupyterLab extension), jupytext.nvim (conversion), ipynb.nvim, jupyter.nvim, jupynava.nvim, vim-jukit (smaller). Star counts are snapshots and must be re-checked before launch. Differentiation: native `.ipynb`, no remote host, no browser, lossless round-trip, checkhealth-guided setup.
