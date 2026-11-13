# /// script
# requires-python = ">=3.9"
# dependencies = ["nbformat>=5.9"]
# ///
"""Generate and validate the synthetic fixture corpus.

Usage (with uv):

    uv run scripts/make_fixtures.py            # (re)generate synthetic fixtures + validate all
    uv run scripts/make_fixtures.py --check    # validate only
    uv run scripts/make_fixtures.py --bench    # also write the 5 MB / 300-cell benchmark notebook

Synthetic fixtures are written exactly the way Jupyter writes notebooks
(``nbformat.write``), so they are byte-for-byte what JupyterLab would produce.
Real-world exports (JupyterLab, VS Code, Colab, Kaggle) go next to them by hand;
see tests/fixtures/README.md.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import struct
import sys
import zlib
from pathlib import Path

import nbformat
from nbformat import v4

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "fixtures" / "notebooks"
BENCH = ROOT / "tests" / "fixtures" / "bench"


def png(width: int, height: int, rgb=(200, 60, 60)) -> bytes:
    """A tiny valid PNG (solid colour)."""

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    row = b"\x00" + bytes(rgb) * width
    raw = row * height
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def png_b64(width=64, height=48) -> str:
    return base64.b64encode(png(width, height)).decode("ascii") + "\n"


PY_META = {
    "kernelspec": {"display_name": "Python 3 (ipykernel)", "language": "python", "name": "python3"},
    "language_info": {
        "codemirror_mode": {"name": "ipython", "version": 3},
        "file_extension": ".py",
        "mimetype": "text/x-python",
        "name": "python",
        "nbconvert_exporter": "python",
        "pygments_lexer": "ipython3",
        "version": "3.12.4",
    },
}


def nb_new(minor: int = 5, **meta) -> nbformat.NotebookNode:
    nb = v4.new_notebook()
    nb.nbformat_minor = minor
    nb.metadata.update(json.loads(json.dumps(PY_META)))
    nb.metadata.update(meta)
    return nb


def strip_ids(nb):
    for c in nb.cells:
        c.pop("id", None)
    return nb


def code(src, outputs=(), count=None, **kw):
    c = v4.new_code_cell(src, execution_count=count, **kw)
    c.outputs = list(outputs)
    return c


def stream(text, name="stdout"):
    return v4.new_output("stream", name=name, text=text)


def result(data, count, metadata=None):
    return v4.new_output("execute_result", data=data, execution_count=count, metadata=metadata or {})


def display(data, metadata=None):
    return v4.new_output("display_data", data=data, metadata=metadata or {})


def error(ename, evalue, tb):
    return v4.new_output("error", ename=ename, evalue=evalue, traceback=tb)


def fixtures() -> dict[str, nbformat.NotebookNode]:
    out: dict[str, nbformat.NotebookNode] = {}

    nb = nb_new()
    nb.cells = [
        v4.new_markdown_cell("# Basic notebook\n\nSome *markdown* text."),
        code("x = 1\ny = 2\nx + y", [result({"text/plain": "3"}, 1)], 1),
        code("print('hello')", [stream("hello\n")], 2),
        code(""),
    ]
    out["jupyterlab_basic"] = nb

    nb = nb_new()
    out["empty_notebook"] = nb

    nb = nb_new()
    nb.cells = [code("")]
    out["single_empty_cell"] = nb

    for minor in range(0, 5):
        nb = nb_new(minor)
        nb.cells = [
            v4.new_markdown_cell("Notebook with nbformat 4.%d" % minor),
            code("a = [1, 2, 3]\nsum(a)", [result({"text/plain": "6"}, 3)], 3),
        ]
        strip_ids(nb)
        out["nbformat_4_%d" % minor] = nb

    nb = nb_new()
    nb.cells = [
        v4.new_markdown_cell("Unicode: tiếng Việt, 日本語, emoji 🎉, math ∑ ∫ ≠"),
        code("s = 'héllo wörld — “quotes”'\nprint(s)", [stream("héllo wörld — “quotes”\n")], 1),
        code("'\\u0000 control \\x1b[31m'", [result({"text/plain": "'\\x00 control \\x1b[31m'"}, 2)], 2),
    ]
    out["unicode"] = nb

    nb = nb_new()
    nb.cells = [
        code(
            "import matplotlib.pyplot as plt\nplt.plot([1, 3, 2])",
            [
                result({"text/plain": "[<matplotlib.lines.Line2D at 0x7f>]"}, 1),
                display(
                    {"image/png": png_b64(), "text/plain": "<Figure size 640x480 with 1 Axes>"},
                    {"needs_background": "light"},
                ),
            ],
            1,
        )
    ]
    out["image_output"] = nb

    nb = nb_new()
    html = '<div>\n<table border="1" class="dataframe">\n  <tr><th>a</th></tr>\n  <tr><td>1</td></tr>\n</table>\n</div>'
    nb.cells = [
        code(
            "import pandas as pd\npd.DataFrame({'a': [1]})",
            [result({"text/html": html, "text/plain": "   a\n0  1"}, 1)],
            1,
        )
    ]
    out["dataframe_html"] = nb

    nb = nb_new()
    nb.cells = [
        code(
            "1/0",
            [
                error(
                    "ZeroDivisionError",
                    "division by zero",
                    [
                        "\x1b[0;31m---------------------------------------------------------------------------\x1b[0m",
                        "\x1b[0;31mZeroDivisionError\x1b[0m                         Traceback (most recent call last)",
                        "Cell \x1b[0;32mIn[1], line 1\x1b[0m\n\x1b[0;32m----> 1\x1b[0m \x1b[38;5;241m1\x1b[39m\x1b[38;5;241m/\x1b[39m\x1b[38;5;241m0\x1b[39m\n",
                        "\x1b[0;31mZeroDivisionError\x1b[0m: division by zero",
                    ],
                )
            ],
            1,
        )
    ]
    out["error_traceback"] = nb

    nb = nb_new()
    nb.cells = [
        code("for i in range(2000): print(i)", [stream("".join("%d\n" % i for i in range(2000)))], 1),
        code("import sys; print('warn', file=sys.stderr)", [stream("warn\n", "stderr")], 2),
    ]
    out["long_stream"] = nb

    nb = nb_new()
    nb.metadata["widgets"] = {
        "application/vnd.jupyter.widget-state+json": {
            "state": {
                "abc": {
                    "model_name": "IntSliderModel",
                    "model_module": "@jupyter-widgets/controls",
                    "state": {"value": 5},
                }
            },
            "version_major": 2,
            "version_minor": 0,
        }
    }
    nb.cells = [
        code(
            "import ipywidgets as w\nw.IntSlider(5)",
            [
                result(
                    {
                        "application/vnd.jupyter.widget-view+json": {
                            "model_id": "abc",
                            "version_major": 2,
                            "version_minor": 0,
                        },
                        "text/plain": "IntSlider(value=5)",
                    },
                    1,
                )
            ],
            1,
        )
    ]
    out["widgets"] = nb

    nb = nb_new()
    cell = v4.new_markdown_cell("![img](attachment:pixel.png)")
    cell.attachments = {"pixel.png": {"image/png": base64.b64encode(png(1, 1)).decode()}}
    nb.cells = [cell]
    out["attachments"] = nb

    nb = nb_new()
    nb.cells = [
        v4.new_raw_cell("raw text\n  indented\n", metadata={"format": "text/restructuredtext"}),
        v4.new_markdown_cell("## Heading\n\n- item\n- item 2\n"),
        code("# %%\n# %% [markdown]\nx = '# %%'", [], None),
    ]
    out["raw_and_delimiters"] = nb

    nb = nb_new()
    nb.metadata["custom"] = {
        "float": 1.0,
        "small": 1e-05,
        "big": 12345678901234567890,
        "neg": -0.5,
        "exp": 1.5e300,
        "list": [],
        "obj": {},
    }
    nb.cells = [
        code("pass", [], None, metadata={"tags": ["parameters"], "jupyter": {"source_hidden": True}, "scrolled": False})
    ]
    out["metadata_numbers"] = nb

    nb = nb_new()
    nb.cells = [
        code("%matplotlib inline\n!pip install x\nx?\nimport os", [], None),
        code("%%bash\necho hi", [stream("hi\n")], 1),
    ]
    out["magics"] = nb

    nb = nb_new()
    nb.cells = [
        code(
            "from IPython.display import display, Markdown\ndisplay(Markdown('**bold**'))",
            [display({"text/markdown": "**bold**", "text/plain": "<IPython.core.display.Markdown object>"})],
            1,
        )
    ]
    out["markdown_output"] = nb

    nb = nb_new()
    svg = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">\n<rect width="10" height="10" fill="red"/>\n</svg>'
    nb.cells = [code("svg", [display({"image/svg+xml": svg, "text/plain": "<SVG>"})], 1)]
    out["svg_output"] = nb

    nb = nb_new()
    nb.metadata = {"kernelspec": {"display_name": "R", "language": "R", "name": "ir"}, "language_info": {"name": "R"}}
    nb.cells = [
        v4.new_markdown_cell("R notebook"),
        code("x <- c(1, 2)\nmean(x)", [result({"text/plain": "[1] 1.5"}, 1)], 1),
    ]
    out["r_kernel"] = nb

    nb = nb_new()
    nb.metadata = {}
    nb.cells = [code("print(1)")]
    out["no_kernelspec"] = nb

    nb = nb_new()
    nb.cells = [code("x = %d" % i, [result({"text/plain": str(i)}, i + 1)], i + 1) for i in range(60)]
    out["many_cells"] = nb

    return out


def write(nb, path: Path) -> None:
    nbformat.validate(nb)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as f:
        nbformat.write(nb, f)


def special_files() -> None:
    """Fixtures that nbformat.write cannot produce directly."""
    basic = (FIXTURES / "jupyterlab_basic.ipynb").read_bytes()
    (FIXTURES / "crlf_line_endings.ipynb").write_bytes(basic.replace(b"\n", b"\r\n"))
    # VS Code style: source as a single string is legal nbformat; keep a hand-written file.
    doc = json.loads(basic)
    doc["cells"][1]["source"] = "x = 1\ny = 2\nx + y"
    (FIXTURES / "string_source.ipynb").write_text(
        json.dumps(doc, indent=1, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n"
    )
    # Non-canonical formatting (indent=2, unsorted): must still round-trip unchanged.
    (FIXTURES / "noncanonical_indent2.ipynb").write_text(
        json.dumps(doc, indent=2) + "\n", encoding="utf-8", newline="\n"
    )


def broken_files() -> None:
    bad = ROOT / "tests" / "fixtures" / "broken"
    bad.mkdir(parents=True, exist_ok=True)
    (bad / "invalid_json.ipynb").write_text('{"cells": [}\n', encoding="utf-8")
    (bad / "nbformat3.ipynb").write_text(
        json.dumps({"nbformat": 3, "nbformat_minor": 0, "worksheets": [], "metadata": {}}, indent=1) + "\n",
        encoding="utf-8",
    )
    (bad / "invalid_utf8.ipynb").write_bytes(
        b'{"cells": [], "metadata": {"x": "\xff\xfe"}, "nbformat": 4, "nbformat_minor": 5}\n'
    )


def bench() -> None:
    nb = nb_new()
    img = base64.b64encode(os.urandom(130_000)).decode("ascii") + "\n"  # incompressible payload
    cells = []
    for i in range(300):
        if i % 10 == 0:
            cells.append(v4.new_markdown_cell("## Section %d\n\nText for section %d." % (i, i)))
        elif i % 7 == 0:
            cells.append(code("plot(%d)" % i, [display({"image/png": img, "text/plain": "<Figure>"})], i))
        else:
            src = "\n".join("value_%d_%d = %d * %d" % (i, j, i, j) for j in range(8))
            cells.append(code(src, [stream("".join("line %d\n" % k for k in range(40)))], i))
    nb.cells = cells
    write(nb, BENCH / "bench_300_cells.ipynb")
    size = (BENCH / "bench_300_cells.ipynb").stat().st_size
    print("bench notebook: %.1f MB" % (size / 1e6))


def check() -> int:
    failures = 0
    for path in sorted(FIXTURES.glob("*.ipynb")):
        try:
            nbformat.validate(nbformat.read(str(path), as_version=4))
        except Exception as exc:  # noqa: BLE001
            failures += 1
            print("INVALID %s: %s" % (path.name, exc))
    print("validated %d fixtures, %d invalid" % (len(list(FIXTURES.glob("*.ipynb"))), failures))
    return 1 if failures else 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="validate only")
    ap.add_argument("--bench", action="store_true", help="also write the benchmark notebook")
    args = ap.parse_args(argv)
    if not args.check:
        for name, nb in fixtures().items():
            write(nb, FIXTURES / (name + ".ipynb"))
        special_files()
        broken_files()
        if args.bench:
            bench()
    return check()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
