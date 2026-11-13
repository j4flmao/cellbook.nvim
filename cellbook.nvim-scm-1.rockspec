rockspec_format = "3.0"
package = "cellbook.nvim"
version = "scm-1"

source = {
  url = "git+https://github.com/j4flmao/cellbook.nvim",
}

description = {
  summary = "Jupyter notebooks in Neovim: open the .ipynb, run it, see the plots.",
  homepage = "https://github.com/j4flmao/cellbook.nvim",
  license = "MIT",
  labels = { "neovim", "jupyter", "ipynb", "notebook" },
}

dependencies = {
  "lua >= 5.1",
}

build = {
  type = "builtin",
  copy_directories = { "doc", "plugin", "python" },
}
