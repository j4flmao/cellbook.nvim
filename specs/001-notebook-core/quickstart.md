# Quickstart: Notebook Core

Two audiences: **users** (validate the feature end to end) and **contributors** (run the project locally). Each scenario maps to a user story so this file doubles as the manual acceptance script before each release.

## Prerequisites

- Neovim ≥ 0.11 (`nvim --version`)
- Python ≥ 3.9 with Jupyter client and a kernel:
  ```sh
  python3 -m pip install jupyter_client ipykernel
  ```
- Optional, for images: a terminal with kitty graphics support (kitty, WezTerm, Ghostty) and `folke/snacks.nvim` (image enabled) or `3rd/image.nvim`
- Optional, for the demo notebook: `python3 -m pip install pandas matplotlib`

## Install

lazy.nvim:

```lua
{ "j4flmao/cellbook.nvim" }
```

Neovim 0.12 built-in `vim.pack`:

```lua
vim.pack.add({ "https://github.com/j4flmao/cellbook.nvim" })
```

No `setup()` call required. Then run:

```vim
:checkhealth cellbook
```

All core checks should be OK.

## Validation scenarios

### S1 — Lossless open/save (US1)

```sh
cp tests/fixtures/notebooks/jupyterlab_basic.ipynb /tmp/s1.ipynb
nvim /tmp/s1.ipynb    # then :w and :q
cmp tests/fixtures/notebooks/jupyterlab_basic.ipynb /tmp/s1.ipynb && echo "round-trip OK"
```

Expected: `round-trip OK`.

### S2 — Edit and validate (US1)

1. Open `/tmp/s1.ipynb`, change a line in cell 2, press `<localleader>b` to add a cell, type `x = 42`, `:w`.
2. Run:
   ```sh
   python3 -c "import nbformat; nbformat.validate(nbformat.read('/tmp/s1.ipynb', 4)); print('valid')"
   ```
Expected: `valid`; `git diff --no-index` against the original shows only the changed source and the new cell.

### S3 — Run cells (US2)

1. Open `examples/demo.ipynb`.
2. On the first code cell press `<S-CR>` (or `:Cellbook run_next`).
3. Expected: header shows a spinner, then `[1]`; output appears below; cursor moves to the next cell; the statusline shows `python3 ● idle`.
4. Run a cell containing `import time\nfor i in range(10): print(i); time.sleep(1)` and keep typing in another cell while it streams — typing must stay smooth.
5. Run `1/0` → red traceback under the cell, header marked error.
6. Run a long `time.sleep(60)` cell, press `<localleader>i` → cell marked interrupted.

### S4 — Rich outputs (US3)

1. In a graphics-capable terminal with snacks.nvim image enabled, run:
   ```python
   import matplotlib.pyplot as plt

   plt.plot([1, 3, 2])
   plt.show()
   ```
   Expected: the plot renders under the cell.
2. Disable the backend (`image = { backend = "none" }`) and re-run → placeholder `[image/png 640×480 — open]`; `<localleader>o` opens it in the system viewer.
3. Run `print("\n".join(map(str, range(1000))))` → 30 lines + `… 970 more lines`; `<localleader>o` opens the full output in a split.

### S5 — Navigation (US4)

`]c`, `[c`, `vic`, `dac` then `u`, `<localleader>k`/`j`, `<localleader>s`, `<localleader>J`, `<localleader>m`. After each, `:w` and re-validate with nbformat (S2 step 2).

### S6 — Kernels (US5)

1. Create a second kernel: `python3 -m venv /tmp/venv && /tmp/venv/bin/pip install ipykernel && /tmp/venv/bin/python -m ipykernel install --user --name s6venv`.
2. `:Cellbook kernel` → choose `s6venv`; run `import sys; sys.executable` → path under `/tmp/venv`.
3. `:qa` → `ps aux | grep -E "ipykernel|cellbook_bridge"` shows nothing.

### S7 — Health (US6)

In a container without `jupyter_client`: `:checkhealth cellbook` shows ERROR with the exact pip command.

## Contributor setup

```sh
git clone https://github.com/j4flmao/cellbook.nvim && cd cellbook.nvim
python3 -m venv .venv && . .venv/bin/activate
pip install -r python/requirements-dev.txt   # jupyter_client ipykernel nbformat pytest ruff
./scripts/test.sh            # mini.test: unit + integration
./scripts/test.sh e2e        # needs ipykernel
pytest tests/python
stylua --check lua tests && selene lua
```

Try the plugin from the checkout without installing:

```sh
nvim -u tests/minimal_init.lua examples/demo.ipynb
```
