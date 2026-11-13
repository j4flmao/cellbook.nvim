-- Minimal init for tests and for trying the plugin from a checkout:
--   nvim -u tests/minimal_init.lua examples/demo.ipynb
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local mini = root .. "/.tests/mini.nvim"
if not vim.uv.fs_stat(mini) then
  vim.fn.system({ "git", "clone", "--filter=blob:none", "--depth", "1", "https://github.com/nvim-mini/mini.nvim", mini })
end
vim.opt.runtimepath:prepend(mini)

vim.o.swapfile = false
vim.o.shada = ""
vim.g.maplocalleader = "\\"

vim.cmd("runtime plugin/cellbook.lua")

if #vim.api.nvim_list_uis() == 0 then
  require("mini.test").setup()
end
