# Changelog

All notable changes to this project are documented here. Releases are generated
by release-please from Conventional Commits.

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
