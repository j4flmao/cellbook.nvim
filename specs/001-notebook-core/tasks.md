# Tasks: Notebook Core

**Input**: Design documents from `/specs/001-notebook-core/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included. The constitution (Principle V) requires test-first development for the format layer; other layers get tests in the same phase.

**Format**: `[ID] [P?] [Story] Description`
- **[P]**: can run in parallel (different files, no dependency on incomplete tasks)
- **[Story]**: US1–US6 from spec.md
- Paths are relative to the repository root (see plan.md → Project Structure)

**Estimates** (solo, part-time ~12 h/week): Phase 1–2 ≈ 2 weeks, US1 ≈ 3 weeks, US2 ≈ 3 weeks, US3 ≈ 2 weeks, US4 ≈ 2 weeks, US5 ≈ 1.5 weeks, US6 + polish ≈ 2.5 weeks → **~16 weeks to v1.0**, public launch at v0.3 (~week 10).

---

## Phase 1: Setup (Shared Infrastructure)

- [x] T001 Create repository skeleton per plan.md (`plugin/`, `lua/cellbook/`, `python/`, `doc/`, `tests/`, `scripts/`, `.github/workflows/`), MIT `LICENSE`, `.gitignore`
- [x] T002 [P] Add `.stylua.toml`, `selene.toml` (std = "neovim"), `.luarc.json` for lua_ls, `ruff.toml` for Python
- [x] T003 [P] Add `tests/minimal_init.lua` that bootstraps `mini.test` into `.tests/` and adds the plugin to `runtimepath`
- [x] T004 [P] Add `scripts/test.sh` (runs `nvim --headless -u tests/minimal_init.lua -c "lua MiniTest.run()"`, accepts suite filter `unit|integration|e2e|bench`)
- [x] T005 [P] Add `python/requirements-dev.txt` (jupyter_client, ipykernel, nbformat, pytest, ruff)
- [x] T006 Add `.github/workflows/ci.yml`: matrix {ubuntu-latest, macos-latest} × {nvim stable, nightly} × {python 3.9, 3.13}; jobs: lint (stylua, selene, ruff), unit+integration, e2e, pytest
- [x] T007 [P] Add `.github/workflows/release.yml` with release-please (Conventional Commits) and optional LuaRocks upload
- [x] T008 [P] Add `CONTRIBUTING.md`, issue templates (bug with `:checkhealth` output + minimal notebook, feature request), PR template with constitution checklist
- [x] T009 [P] Add `README.md` placeholder with pitch line and "work in progress" banner

---

## Phase 2: Foundational (Blocking Prerequisites)

**⚠️ No user story work starts before this phase is complete.**

### Fixture corpus

- [ ] T010 Collect ≥ 50 redistributable notebooks into `tests/fixtures/notebooks/` (JupyterLab, VS Code, Colab, Kaggle exports, nbformat 4.0–4.5, unicode, CRLF, big outputs, widgets, attachments, raw cells, empty notebook); record source + license in `tests/fixtures/README.md` — *partial: 26 synthetic nbformat fixtures; real-world exports still needed (tests/fixtures/README.md)*
- [x] T011 [P] Add `scripts/make_fixtures.py` to validate every fixture with nbformat and to regenerate synthetic fixtures (300-cell / 5 MB notebook for benchmarks)

### JSON encoder (test-first)

- [x] T012 [P] Write failing tests `tests/unit/json_spec.lua`: sorted keys, `indent=1`, nested empty `{}`/`[]` formatting, unicode not escaped, control chars escaped like Python, `vim.NIL` → `null`, ints vs floats (`1.0`, `1e-05`), large ints, trailing newline; compare against Python `json.dumps(..., indent=1, sort_keys=True, ensure_ascii=False)` outputs stored as fixtures
- [x] T013 Implement `lua/cellbook/format/json.lua` (decode via `vim.json.decode` with `luanil = {object = false, array = false}` + number-literal preservation strategy from research R3; encode with Python-compatible formatting) until T012 passes

### ipynb parse/serialize (test-first)

- [x] T014 [P] Write failing tests `tests/unit/ipynb_spec.lua`: parse every fixture into the Notebook model; serialize unmodified → byte-identical (SC-001); modified source → only that cell changes; string vs list `source` forms preserved; nbformat 3 → readonly flag; invalid JSON → error with position
- [x] T015 Implement `lua/cellbook/model/cell.lua` and `lua/cellbook/model/notebook.lua` per data-model.md (LuaCATS annotations, id generation, registry by bufnr)
- [x] T016 Implement `lua/cellbook/format/ipynb.lua` (`parse(text) -> Notebook|nil, err`, `serialize(Notebook, cell_sources) -> string`) until T014 passes

### Percent format (test-first)

- [x] T017 [P] Write failing tests `tests/unit/percent_spec.lua`: Notebook → lines (delimiters per cell type, comment prefix from language), lines + delimiter rows → sources (prefix stripping), empty cells, cells whose source contains `# %%` text, languages with different comment strings (python `#`, r `#`, julia `#`, lua `--`)
- [x] T018 Implement `lua/cellbook/format/percent.lua` until T017 passes

### Core infrastructure

- [x] T019 [P] Implement `lua/cellbook/config.lua` (defaults from contracts/commands-keymaps-config.md, `vim.validate`, unknown-key warnings with suggestions) + tests `tests/unit/config_spec.lua`
- [x] T020 [P] Implement `lua/cellbook/events.lua` (User autocmd helpers) 
- [x] T021 Implement `plugin/cellbook.lua`: guard `vim.g.loaded_cellbook`, register `BufReadCmd`/`FileReadCmd`/`BufWriteCmd`/`FileWriteCmd` for `*.ipynb` and the `:Cellbook` command, all via lazy `require`
- [x] T022 [P] Add `tests/bench/startup_spec.lua` asserting plugin sourcing cost < 1 ms

**Checkpoint**: format layer complete; round-trip passes on the whole corpus (SC-001).

---

## Phase 3: User Story 1 — Open, edit, and save losslessly (P1) 🎯 MVP

**Goal**: `:e x.ipynb` → editable buffer with clear cells; `:w` writes valid, minimal-diff nbformat.
**Independent Test**: quickstart S1 + S2; integration tests below.

### Tests (write first)

- [x] T030 [P] [US1] `tests/integration/attach_spec.lua`: open fixture → buffer lines equal `percent.to_lines`; filetype = kernel language; `buftype=acwrite`; `:w` unmodified → byte-identical; malformed JSON → readonly raw view and `:w` refuses
- [x] T031 [P] [US1] `tests/integration/tracker_spec.lua`: typing inside cells keeps boundaries; deleting a delimiter line merges cells; undo restores; pasting text containing `# %%` inside a cell does not create cells until `:Cellbook sync`/save rules apply; two windows same buffer
- [x] T032 [P] [US1] `tests/integration/save_spec.lua`: edit cell → only that cell's `source` differs (JSON diff); add cell → new id (nbformat ≥ 4.5) at correct index; delete cell → removed; outputs of untouched cells preserved; `save.strip_outputs = true` removes outputs and execution counts

### Implementation

- [x] T033 [US1] Implement `lua/cellbook/buffer/attach.lua`: read file (`vim.uv.fs_read`), parse, set lines without undo history (`undolevels=-1` trick), set `filetype`, `buftype=acwrite`, `modified=false`; raw read-only fallback on errors; `BufWriteCmd` → serialize → atomic write (temp file + rename) → `modified=false` → `CellbookSaved`
- [x] T034 [US1] Implement `lua/cellbook/buffer/tracker.lua`: one extmark per delimiter (namespace `cellbook.cells`), `nvim_buf_attach` `on_lines` to mark dirty cells and detect deleted/created delimiters, `read_cells()` returning ordered `{cell, start_row, end_row}`, rebuild-from-text after undo/redo
- [x] T035 [US1] Implement `lua/cellbook/buffer/decor.lua`: delimiter line decoration (cell type label, execution count, state icon) via `virt_text`/`conceal`, markdown comment-prefix conceal, window-local `conceallevel=2`, `concealcursor=""` in notebook windows
- [x] T036 [US1] Implement basic `lua/cellbook/buffer/ops.lua`: add cell above/below (code/markdown), delete cell, in single undo blocks
- [ ] T037 [P] [US1] Add `queries/python/injections.scm` markdown injection for markdown-cell comment lines (guarded so it only applies in notebook buffers via a buffer-local predicate or directive); fallback extmark highlighting when Treesitter injection is unavailable — *deferred: extmark highlighting fallback implemented; a Python injection query would affect all .py buffers*
- [x] T038 [US1] Wire minimal `:Cellbook add|delete|raw|info` in `lua/cellbook/commands.lua`
- [x] T039 [P] [US1] Document open/save behavior, `buftype=acwrite`, conceal settings in `doc/cellbook.txt`

**Checkpoint**: US1 independently usable → tag `v0.1.0-alpha` (private testers only).

---

## Phase 4: User Story 2 — Run cells, text outputs (P1)

**Goal**: execute cells against a real kernel, stream text outputs inline, non-blocking.
**Independent Test**: quickstart S3; e2e tests below.

### Tests (write first)

- [x] T040 [P] [US2] `tests/python/test_bridge.py`: hello/fatal handshake, `list_kernelspecs`, `start_kernel`, `execute` ordering (iopub before reply), `interrupt`, `restart`, `shutdown`, exit on stdin close, invalid request handling
- [x] T041 [P] [US2] `tests/unit/bridge_framing_spec.lua`: NDJSON chunk reassembly (partial lines, multiple lines per chunk, large lines > 1 MB), request/response correlation, event dispatch
- [x] T042 [P] [US2] `tests/unit/outputs_spec.lua`: stream merging, `\r` progress handling, `clear_output(wait)`, `update_display_data` by display_id, conversion to nbformat on save
- [x] T043 [P] [US2] `tests/unit/ansi_spec.lua`: SGR parsing (bold, 16/256/truecolor, reset), traceback samples from IPython
- [x] T044 [P] [US2] `tests/e2e/execute_spec.lua`: run all on fixture → expected outputs/execution counts; streaming loop stays responsive (measure `vim.uv.hrtime` around simulated keystrokes); error stops run-all; outputs saved

### Implementation

- [x] T045 [US2] Implement `python/cellbook_bridge.py` per contracts/bridge-protocol.md (asyncio loop, `AsyncKernelManager`, stdin reader thread or `asyncio` stream, msg_id → cell_id map, flush per line, stderr logging)
- [x] T046 [US2] Implement `lua/cellbook/kernel/specs.lua`: python discovery order (config → `$VIRTUAL_ENV` → `$CONDA_PREFIX` → `python3` → `python`), cached `list_kernelspecs`
- [x] T047 [US2] Implement `lua/cellbook/kernel/bridge.lua`: `vim.system` spawn with `stdin=true`, line buffering, `vim.json.decode`, request ids + callbacks with timeouts, event emitter, stderr to log buffer
- [x] T048 [US2] Implement `lua/cellbook/kernel/session.lua`: state machine, FIFO queue, run_state updates, cancel-on-error, `CellbookKernelStarted/StateChanged/CellExecuted` events
- [x] T049 [US2] Implement `lua/cellbook/model/outputs.lua`: iopub → Output entities, MIME selection by `mime_priority`, nbformat conversion
- [x] T050 [US2] Implement `lua/cellbook/render/ansi.lua` (cached dynamic highlight groups) and `lua/cellbook/render/text.lua` (virt_lines below cell end, truncation marker, throttled re-render ≤ every 30 ms per cell)
- [x] T051 [US2] Implement running-state decoration in `decor.lua` (spinner via `vim.uv` timer, elapsed time, stale marker when source edited after run)
- [x] T052 [US2] Expose `run_cell`, `run_cell_and_next`, `run_all`, `run_above`, `run_below`, `run_range`, `interrupt`, `restart`, `shutdown` in `lua/cellbook/init.lua` + `:Cellbook` subcommands
- [x] T053 [US2] Implement `lua/cellbook/lsp.lua`: diagnostic display filter for magic/shell lines and `%%` cells; `CellbookMagic` highlighting
- [x] T054 [US2] Add `examples/demo.ipynb` (pure Python + pandas/matplotlib sections) used by quickstart and the demo GIF

**Checkpoint**: open → run → save loop works → tag `v0.2.0` (soft launch: 10–20 testers from Discord/Matrix/Reddit DMs).

---

## Phase 5: User Story 3 — Rich outputs (P2) 🚀 Public launch

**Goal**: images, DataFrames, long outputs handled well; record the demo.
**Independent Test**: quickstart S4.

### Tests

- [x] T060 [P] [US3] `tests/unit/image_select_spec.lua`: adapter selection (auto order, explicit, `none`), `supports(mime)`, cache file naming by sha256
- [x] T061 [P] [US3] `tests/integration/render_spec.lua` (screenshot tests via `mini.test` child + `screenshot()`): text truncation, placeholder line, full-output split contents, hide/show outputs

### Implementation

- [x] T062 [US3] Implement `lua/cellbook/render/image.lua`: base64 decode (`vim.base64.decode`) to `stdpath("cache")/cellbook/<sha256>.<ext>` (written with `vim.uv` async fs), adapter registry, visible-range rendering with `WinScrolled`/`WinResized` debounce 50 ms
- [x] T063 [P] [US3] Implement `lua/cellbook/render/adapters/snacks.lua` (snacks image placement API)
- [x] T064 [P] [US3] Implement `lua/cellbook/render/adapters/image_nvim.lua`
- [x] T065 [P] [US3] Implement `lua/cellbook/render/adapters/placeholder.lua` (`[image/png W×H — open]`, `vim.ui.open`)
- [x] T066 [US3] Implement `open_output` (scratch split, `filetype=cellbook_output`, ANSI highlighted) and `toggle_output` (per cell / all)
- [x] T067 [US3] Expose `register_renderer` public API
- [ ] T068 [US3] README v1: pitch, demo GIF (recorded with VHS/asciinema-agg in Ghostty/kitty), install snippets (lazy.nvim, vim.pack, rocks.nvim), feature list, "How is this different from molten/jupytext/jupynium?" FAQ, requirements table — *partial: README written; demo GIF still to record*
- [ ] T069 [US3] Tag `v0.3.0` and execute launch plan (ROADMAP.md → Launch)

**Checkpoint**: public launch.

---

## Phase 6: User Story 4 — Navigation and cell management (P2)

- [x] T070 [P] [US4] `tests/integration/keymaps_spec.lua`: `]c`/`[c` (+ diff-mode fallback), `ic`/`ac` in o/x modes, run keymaps, all `<localleader>` actions; `keymaps=false` maps nothing; remap via table
- [x] T071 [P] [US4] `tests/integration/ops_spec.lua`: move up/down, split, merge above/below, convert type (outputs dropped), each undoable in one `u`
- [x] T072 [US4] Complete `lua/cellbook/buffer/ops.lua` (move, split, merge, set type)
- [x] T073 [US4] Implement `lua/cellbook/keymaps.lua` (buffer-local, `desc` for which-key, text objects via `vim.keymap.set({"o","x"}, ...)`)
- [x] T074 [US4] Implement `lua/cellbook/status.lua` + `cb.statusline()`; document lualine/heirline/mini.statusline snippets
- [ ] T075 [P] [US4] Update `doc/cellbook.txt` keymaps section; tag `v0.4.0` + release post — *docs done; release tag pending*

---

## Phase 7: User Story 5 — Kernel management (P3)

- [x] T080 [P] [US5] `tests/e2e/kernels_spec.lua`: select second kernelspec → metadata updated; kernel death (`os._exit(1)` in a cell) → dead state + restart prompt; `VimLeavePre` leaves no `ipykernel`/bridge processes (check via `vim.uv` process list or `pgrep`)
- [x] T081 [US5] Implement `select_kernel` (`vim.ui.select`, writes `metadata.kernelspec` + `language_info` on next save, re-sets filetype if language changed)
- [x] T082 [US5] Dead-kernel handling and restart flows (`restart`, `restart run_all`), `kernel.autostart`, `kernel.shutdown_on_close` (BufWipeout/BufDelete of last notebook buffer)
- [x] T083 [US5] `VimLeavePre` cleanup: send `shutdown` to all sessions, wait up to 1 s with `vim.wait`, then kill
- [x] T084 [P] [US5] `:Cellbook log` buffer and `:Cellbook info` float; tag `v0.5.0`

---

## Phase 8: User Story 6 — Health + Polish → v1.0

- [x] T090 [US6] Implement `lua/cellbook/health.lua`: Neovim version, python path + version, `jupyter_client` import (run bridge with `--check`), kernelspecs list, image backend availability, terminal graphics hints (`$TERM`, `$TERM_PROGRAM`, tmux `allow-passthrough`), `<S-CR>` terminal support INFO, each failure with exact fix command
- [ ] T091 [P] [US6] `tests/integration/health_spec.lua` with mocked environments for each failure case — *covered manually; mocked-environment tests still to write*
- [x] T092 [P] `tests/bench/open_spec.lua` (5 MB / 300 cells < 200 ms) and `tests/bench/stream_spec.lua` (keystroke latency < 16 ms during 1,000 lines/s); run in CI as non-blocking job with results in the job summary
- [x] T093 Performance pass on hot paths found by benchmarks (tracker `on_lines`, virt_lines re-render, JSON encode)
- [x] T094 [P] Complete `doc/cellbook.txt` (every command, option, API, highlight, event) and generate `:h cellbook` tags in CI
- [ ] T095 [P] Usability test: 5 users install from README to first run (SC-002), fix friction points
- [ ] T096 Run full quickstart S1–S7 manually on Linux and macOS; tag `v1.0.0`
- [ ] T097 Open PR to LazyVim adding a `lang.jupyter` extra (or `editor.cellbook`), PR to `rockerBOO/awesome-neovim`, submit to dotfyle and This Week in Neovim

---

## Dependencies & Execution Order

```text
Phase 1 Setup ──► Phase 2 Foundational ──► US1 ──► US2 ──► US3 (public launch)
                                                   │
                                                   ├──► US4 (needs US1 ops; can start after US1, parallel to US2/US3)
                                                   └──► US5 (needs US2 session)
US6 health can start once the bridge exists (after T045); polish last.
```

- US1 depends only on Phase 2.
- US2 depends on US1 (cells/tracker) for routing outputs.
- US3 depends on US2 (outputs exist).
- US4 depends on US1 only → good parallel track.
- US5 depends on US2.

## Parallel opportunities

- Phase 2: T012, T014, T017 (tests) in parallel; T019, T020, T022 in parallel.
- US2: bridge (T045, Python) and Lua framing/outputs/ansi (T047, T049, T050) in parallel once T041–T043 exist.
- US3: adapters T063/T064/T065 fully parallel.

## Implementation strategy

1. **MVP = Phase 1–3 (US1)** → use it yourself daily for a week before adding execution.
2. **US2** turns it into a real notebook tool; soft-launch to testers for feedback on setup friction.
3. **US3** gives the visual "wow" → public launch at v0.3 with demo GIF.
4. **US4–US6** ship as frequent minor releases, each with its own short clip and r/neovim post (steady star steps instead of one spike).
5. Never ship a release with an open `data-loss` issue.
