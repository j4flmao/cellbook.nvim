-- Real kernel execution (needs uv, or a Python with jupyter_client + ipykernel).
local H = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
local cb = require("cellbook")
local eq = MiniTest.expect.equality

local executed = {}
local au

local function wait_executed(n, timeout)
  return vim.wait(timeout or 180000, function()
    return #executed >= n
  end, 20)
end

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      au = vim.api.nvim_create_autocmd("User", {
        pattern = "CellbookCellExecuted",
        callback = function(ev)
          executed[#executed + 1] = ev.data
        end,
      })
    end,
    pre_case = function()
      executed = {}
      require("cellbook.config").setup({})
    end,
    post_case = function()
      require("cellbook.kernel.session").shutdown_all(3000)
      H.wipe_all()
    end,
    post_once = function()
      vim.api.nvim_del_autocmd(au)
    end,
  },
})

T["run all writes outputs and execution counts"] = function()
  local path = H.tmp_copy("jupyterlab_basic.ipynb")
  local nb = H.open(path)
  cb.run_all(0)
  eq(wait_executed(2), true)
  vim.wait(200)
  eq(executed[1].status, "ok")
  eq(executed[1].execution_count, 1)
  eq(H.view_text(nb.cells[2]), { "3" })
  eq(H.view_text(nb.cells[3]), { "hello" })
  eq(vim.bo.modified, true)
  vim.cmd("silent write")
  local doc = H.json(path)
  eq(doc.cells[2].execution_count, 1)
  eq(doc.cells[2].outputs[1].data["text/plain"], { "3" })
  eq(doc.cells[3].outputs[1], { name = "stdout", output_type = "stream", text = { "hello\n" } })
end

T["streaming keeps Neovim responsive"] = function()
  local nb = H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  vim.api.nvim_buf_set_lines(
    0,
    9,
    10,
    false,
    { "import time", "for i in range(20):", "    print(i, flush=True); time.sleep(0.05)" }
  )
  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  cb.run_cell(0)
  vim.wait(120000, function()
    return nb.cells[3].run_state == "running"
  end, 10)
  local worst = 0
  while nb.cells[3].run_state == "running" do
    local t = vim.uv.hrtime()
    vim.api.nvim_buf_set_lines(0, 5, 6, false, { "x = " .. tostring(t % 100) })
    vim.wait(5)
    worst = math.max(worst, (vim.uv.hrtime() - t) / 1e6 - 5)
  end
  eq(worst < 50, true)
  vim.wait(200)
  eq(#H.view_text(nb.cells[3]), 20)
end

T["an error stops run-all"] = function()
  local nb = H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  vim.api.nvim_buf_set_lines(0, 5, 8, false, { "1/0" })
  cb.run_all(0)
  eq(wait_executed(1), true)
  vim.wait(300)
  eq(nb.cells[2].run_state, "error")
  eq(nb.cells[3].run_state, "cancelled")
  local lines = H.view_text(nb.cells[2])
  eq(lines[#lines], "ZeroDivisionError: division by zero")
end

T["interrupt"] = function()
  local nb = H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  vim.api.nvim_buf_set_lines(0, 9, 10, false, { "while True: pass" })
  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  cb.run_cell(0)
  vim.wait(120000, function()
    return nb.cells[3].run_state == "running"
  end, 20)
  vim.wait(800)
  cb.interrupt(0)
  eq(wait_executed(1, 20000), true)
  eq(nb.cells[3].run_state, "interrupted")
end

T["restart clears state; dead kernel is detected"] = function()
  local nb = H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  cb.run_cell(0, 2)
  eq(wait_executed(1), true)
  cb.restart(0)
  vim.wait(60000, function()
    return nb.session and nb.session.state == "idle"
  end, 20)
  vim.api.nvim_buf_set_lines(0, 9, 10, false, { "x" })
  cb.run_cell(0, 3)
  eq(wait_executed(2), true)
  eq(nb.cells[3].run_state, "error")
  vim.api.nvim_buf_set_lines(0, 9, 10, false, { "import os; os._exit(1)" })
  cb.run_cell(0, 3)
  vim.wait(20000, function()
    return nb.session.state == "dead"
  end, 20)
  eq(nb.session.state, "dead")
end

T["no orphan processes after shutdown"] = function()
  local nb = H.open(H.tmp_copy("jupyterlab_basic.ipynb"))
  cb.run_cell(0, 2)
  eq(wait_executed(1), true)
  local b = nb.session.bridge
  require("cellbook.kernel.session").shutdown_all(5000)
  vim.wait(5000, function()
    return b.exited
  end, 20)
  eq(b.exited, true)
end

return T
