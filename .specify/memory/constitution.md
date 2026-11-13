<!--
Sync Impact Report
- Version: 0.0.0 → 1.0.0 (initial ratification)
- Principles added: I–VII
- Sections added: Technical Constraints, Development Workflow, Governance
- Templates requiring updates: none (initial version)
- Deferred TODOs: final project name (provisional: cellbook.nvim)
-->

# cellbook.nvim Constitution

cellbook.nvim is a Neovim plugin that lets users open, edit, run, and save Jupyter notebooks (`.ipynb`) natively inside Neovim, with outputs (text, tables, images) rendered inline under each cell.

## Core Principles

### I. Native Notebook, Zero Conversion (NON-NEGOTIABLE)

- Users MUST be able to run `:edit analysis.ipynb` and get an editable notebook immediately. No manual `jupytext` step, no sidecar `.py` files committed by the user, no "export" command.
- Saving MUST write valid nbformat 4.x JSON back to the same `.ipynb` file.
- An unmodified notebook that is opened and saved MUST produce a byte-identical file (Jupyter's own serialization: `indent=1`, sorted keys, trailing newline). Lossless round-trip is the trust contract with users; breaking it is a release blocker.

### II. One-Line Install, Self-Diagnosing Setup

- The happy path is: add the plugin spec, run `:checkhealth cellbook`, follow what it says. Every missing dependency (Python, `jupyter_client`, `ipykernel`, image backend) MUST be detected by `:checkhealth` with an exact fix command.
- The plugin MUST NOT depend on Neovim's Python remote-plugin host (`pynvim`, `:UpdateRemotePlugins`). Kernel communication goes through a standalone bridge process over stdio.
- `setup()` MUST be optional. Calling nothing must give a working default experience.

### III. Neovim-Native Editing

- Code cells MUST be real buffer text with the kernel language's filetype so that LSP, Treesitter, completion, formatters, and the user's existing keymaps all work unchanged.
- Outputs MUST be rendered with extmarks (virtual lines, images via a backend). Outputs are never inserted as editable buffer text.
- The plugin MUST NOT override user keymaps outside notebook buffers, and all default keymaps MUST be buffer-local and disable-able.

### IV. Performance Budgets Are Requirements

- Plugin load cost at startup: < 1 ms (lazy by filetype/`BufReadCmd`; no work until a notebook is opened).
- Opening a 5 MB notebook with 300 cells: < 200 ms to first render on a mid-range laptop.
- Typing latency in a notebook buffer MUST be indistinguishable from a normal buffer: no synchronous work on `TextChanged*` beyond O(changed cells).
- Kernel I/O MUST be fully asynchronous; Neovim MUST never block waiting for a kernel.

### V. Test-First for the Format Layer

- The `.ipynb` parser/serializer and the cell-boundary tracker MUST be developed test-first, with a fixture corpus of real-world notebooks (JupyterLab, VS Code, Colab, Kaggle exports, nbformat 4.0–4.5).
- Every bug report involving a corrupted or altered notebook MUST add a regression fixture before the fix merges.
- CI MUST run on Neovim stable and nightly, on Linux and macOS.

### VI. Small Core, Pluggable Edges

- The core handles: format, cells, kernel bridge, text outputs. Everything else (image rendering, pickers, statusline, completion sources, AI features) lives behind adapters or optional modules.
- Image rendering MUST use existing backends (`snacks.nvim` image, `image.nvim`) via an adapter interface, with a text placeholder fallback. The plugin does not ship its own terminal graphics implementation.
- No hard dependency on any other Neovim plugin.

### VII. Documentation Is a Feature

- Every user-facing command, option, highlight group, and Lua API function MUST be documented in `doc/cellbook.txt` (vimdoc) and in the README.
- The README MUST open with a one-sentence pitch, a demo GIF, and a copy-paste install snippet that works with zero configuration.
- Breaking changes require a migration note and a deprecation period of at least one minor release.

## Technical Constraints

- Minimum Neovim version: 0.11.0. Target: latest stable (0.12.x). Nightly-only APIs MAY be used behind feature detection.
- Languages: Lua (plugin), Python ≥ 3.9 (bridge, standard library + `jupyter_client` only).
- Supported OS: Linux, macOS (tier 1); Windows/WSL (tier 2, best effort, no release blocking).
- Licensing: MIT (Apache-2.0 acceptable). No GPL dependencies vendored.
- No network access except to the local kernel, unless the user explicitly configures a remote Jupyter server (post-1.0).

## Development Workflow

- Spec-driven: every feature starts as a spec under `specs/NNN-name/` (spec → plan → tasks) before code.
- Branch per feature (`NNN-feature-name`), squash-merge with Conventional Commits (`feat:`, `fix:`, `perf:`, `docs:`, `test:`).
- Releases are automated with release-please; semantic versioning; CHANGELOG generated from commits.
- Every release with user-visible changes ships with a short demo clip and an r/neovim post (see ROADMAP.md).
- Issues are triaged weekly; issues tagged `data-loss` are fixed before any feature work.

## Governance

- This constitution supersedes other project practices. Plans (`plan.md`) MUST include a Constitution Check that passes before implementation.
- Amendments require: a written proposal in an issue, an updated version number (MAJOR: principle removed/redefined; MINOR: principle/section added; PATCH: clarification), and an updated Sync Impact Report at the top of this file.
- Complexity that violates a principle MUST be justified in the plan's Complexity Tracking table or rejected.

**Version**: 1.0.0 | **Ratified**: 2026-11-12 | **Last Amended**: 2026-11-12
