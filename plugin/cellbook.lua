-- cellbook.nvim: Jupyter notebooks in Neovim.
-- Only autocommands and the :Cellbook command are registered here; every module
-- is required lazily, so startup cost stays well below 1 ms.
if vim.g.loaded_cellbook then
  return
end
vim.g.loaded_cellbook = true

if vim.fn.has("nvim-0.11") == 0 then
  vim.api.nvim_echo({ { "cellbook.nvim requires Neovim >= 0.11", "WarningMsg" } }, true, {})
  return
end

local group = vim.api.nvim_create_augroup("cellbook", { clear = true })

vim.api.nvim_create_autocmd("BufReadCmd", {
  group = group,
  pattern = "*.ipynb",
  nested = true,
  callback = function(ev)
    require("cellbook.buffer.attach").read(ev.buf, ev.match)
  end,
})

vim.api.nvim_create_autocmd("FileReadCmd", {
  group = group,
  pattern = "*.ipynb",
  nested = true,
  callback = function(ev)
    require("cellbook.buffer.attach").file_read(ev.buf, ev.match)
  end,
})

-- Non-notebook buffers written to *.ipynb (notebook buffers have buffer-local handlers).
vim.api.nvim_create_autocmd({ "BufWriteCmd", "FileWriteCmd" }, {
  group = group,
  pattern = "*.ipynb",
  nested = true,
  callback = function(ev)
    if vim.b[ev.buf].cellbook then
      return
    end
    local attach = require("cellbook.buffer.attach")
    if require("cellbook.model.notebook").get(ev.buf) then
      return
    end
    if ev.event == "FileWriteCmd" then
      attach.write_range(ev.buf, ev.match)
    else
      attach.write(ev.buf, ev.match)
    end
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    if package.loaded["cellbook.kernel.session"] then
      require("cellbook.kernel.session").shutdown_all(1000)
    end
  end,
})

vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = function()
    if package.loaded["cellbook.buffer.decor"] then
      require("cellbook.buffer.decor").setup_highlights()
      require("cellbook.render.ansi").reset()
      require("cellbook.render.blocks").reset()
    end
  end,
})

local scroll_timer
vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
  group = group,
  callback = function()
    if not package.loaded["cellbook.model.notebook"] then
      return
    end
    if scroll_timer then
      scroll_timer:stop()
    else
      scroll_timer = vim.uv.new_timer()
    end
    scroll_timer:start(
      50,
      0,
      vim.schedule_wrap(function()
        for _, nb in ipairs(require("cellbook.model.notebook").all()) do
          if not nb.readonly and not nb.detached then
            require("cellbook.render.image").render_visible(nb)
          end
        end
      end)
    )
  end,
})

vim.api.nvim_create_user_command("Cellbook", function(cmd)
  require("cellbook.commands").dispatch(cmd)
end, {
  nargs = "*",
  range = true,
  desc = "cellbook.nvim notebook commands",
  complete = function(arglead, cmdline)
    return require("cellbook.commands").complete(arglead, cmdline)
  end,
})
