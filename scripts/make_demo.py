# /// script
# requires-python = ">=3.9"
# dependencies = ["nbformat>=5.9"]
# ///
"""Write examples/demo.ipynb (used by the quickstart and the README demo GIF).

uv run scripts/make_demo.py
"""

from pathlib import Path

import nbformat
from nbformat import v4

ROOT = Path(__file__).resolve().parent.parent

nb = v4.new_notebook()
nb.metadata = {
    "kernelspec": {"display_name": "Python 3 (ipykernel)", "language": "python", "name": "python3"},
    "language_info": {"name": "python"},
}
nb.cells = [
    v4.new_markdown_cell(
        "# cellbook.nvim demo\n\nRun a cell with `<S-CR>` (or `<localleader>r`), run everything with `<localleader>R`."
    ),
    v4.new_code_cell("import sys\nprint(f'Python {sys.version.split()[0]}')\n6 * 7"),
    v4.new_markdown_cell("## Streaming output\n\nKeep typing while this runs."),
    v4.new_code_cell("import time\nfor i in range(5):\n    print(f'step {i}', flush=True)\n    time.sleep(0.4)"),
    v4.new_markdown_cell("## Errors\n\nTracebacks keep their colours."),
    v4.new_code_cell("1 / 0"),
    v4.new_markdown_cell("## DataFrames (needs `pandas`)"),
    v4.new_code_cell(
        "import pandas as pd\ndf = pd.DataFrame({'city': ['Hanoi', 'Hue', 'Saigon'], 'temp': [24.5, 27.1, 31.0]})\ndf"
    ),
    v4.new_markdown_cell("## Plots (needs `matplotlib` and an image backend: snacks.nvim or image.nvim)"),
    v4.new_code_cell("import matplotlib.pyplot as plt\nplt.plot([1, 3, 2, 4])\nplt.title('cellbook.nvim')\nplt.show()"),
]
path = ROOT / "examples" / "demo.ipynb"
path.parent.mkdir(exist_ok=True)
nbformat.validate(nb)
with path.open("w", encoding="utf-8", newline="\n") as f:
    nbformat.write(nb, f)
print("wrote", path)
