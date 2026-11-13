# Changelog

All notable changes to this project are documented here. Releases are generated
by release-please from Conventional Commits.

## 1.0.0 (2026-11-13)


### Features

* cellbook.nvim — Jupyter notebooks in Neovim ([088bb0c](https://github.com/j4flmao/cellbook.nvim/commit/088bb0c0102ad74f3fe4a87b934fdef6dd462357))


### Bug Fixes

* first cell output lost on fast machines; CI on Linux/macOS ([f55ed05](https://github.com/j4flmao/cellbook.nvim/commit/f55ed058740015de8891addb098ab4ee5f12dc45))
* saving through symlinked paths; selene warnings ([e1d882d](https://github.com/j4flmao/cellbook.nvim/commit/e1d882de1249bba664d29f7e35fd4fadd558ac63))

## [Unreleased]

### Added

- Native `.ipynb` editing: `BufReadCmd`/`BufWriteCmd`/`FileReadCmd`/`FileWriteCmd`,
  percent-format buffer, byte-identical round-trip, Jupyter-compatible JSON encoder.
- Extmark-based cell tracking; undo/redo restores cells together with their outputs.
- Cell operations: add, delete, move, split, merge, change type; `]c`/`[c`, `ic`/`ac`.
- Kernel execution through a stdio NDJSON bridge (`jupyter_client`), uv-first Python discovery.
- "Select Kernel": Python environments (.venv, conda, uv, PATH) and Jupyter kernelspecs,
  remembered per notebook.
- Notebook UI: code cells as cards, rendered markdown cells, clickable toolbar in the winbar.
- Text outputs as virtual lines with ANSI colours, truncation and a full-output split.
- pandas DataFrames rendered as box tables, split into column blocks when wide.
- Images: snacks.nvim / image.nvim adapters, a built-in Sixel renderer (Windows Terminal,
  WezTerm, foot…) and a true-colour block-character fallback.
- `:Cellbook` command, Lua API, `User` events, statusline component, `:checkhealth cellbook`.
