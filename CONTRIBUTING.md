# Contributing to cellbook.nvim

Thanks for helping! This project is spec-driven: read
[`.specify/memory/constitution.md`](.specify/memory/constitution.md) and the feature
spec in [`specs/001-notebook-core/`](specs/001-notebook-core/) first.

## Setup

```sh
git clone https://github.com/j4flmao/cellbook.nvim && cd cellbook.nvim
uv sync                                  # pytest, ruff, nbformat, jupyter_client, ipykernel
uv run scripts/make_fixtures.py --bench  # (re)generate synthetic fixtures + benchmark notebook
```

## Tests

```sh
./scripts/test.sh            # Lua unit + integration (mini.test is cloned into .tests/)
./scripts/test.sh e2e        # real kernels (uses uv or a Python with ipykernel)
./scripts/test.sh bench      # performance budgets
uv run pytest                # bridge protocol tests
```

On Windows run `scripts/test.sh` from Git Bash.

## Style

```sh
stylua --check lua plugin tests
selene lua plugin
uv run ruff check && uv run ruff format --check
```

## Rules

- The format layer (`lua/cellbook/format/`) is **test-first**. Every bug that corrupts or
  alters a notebook adds a regression fixture under `tests/fixtures/notebooks/` before the fix.
- `format/` and `model/` must not use Neovim UI APIs.
- No hard dependency on other plugins; no `pynvim`.
- Every user-facing command, option, highlight group, event and API function is documented in
  `doc/cellbook.txt` and the README.
- Conventional Commits (`feat:`, `fix:`, `perf:`, `docs:`, `test:`), squash-merge.
- Issues labelled `data-loss` are fixed before any feature work.
