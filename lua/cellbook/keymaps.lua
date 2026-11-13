---Buffer-local default keymaps and `ic`/`ac` text objects.
local config = require("cellbook.config")

local M = {}

---Select a cell linewise (operator-pending or visual mode).
---@param around boolean include the delimiter line
function M.select_cell(around)
  local nb = require("cellbook.model.notebook").get(0)
  if not nb or nb.readonly then
    return
  end
  local _, r = require("cellbook.buffer.tracker").current(nb)
  if not r then
    return
  end
  local s = around and r.start or r.start + 1
  local e = r.stop
  if e < s then
    -- empty cell body: nothing to select
    if vim.fn.mode():find("[vV\22]") then
      vim.cmd("normal! \27")
    end
    return
  end
  if vim.fn.mode():find("[vV\22]") then
    vim.cmd("normal! \27")
  end
  vim.cmd(("normal! %dGV%dG"):format(s + 1, e + 1))
end

---@return table<string, {fn: function, expr: boolean?}>
local function actions()
  local cb = require("cellbook")
  return {
    next_cell = {
      fn = function()
        if vim.wo.diff then
          vim.cmd("normal! " .. vim.v.count1 .. "]c")
          return
        end
        cb.goto_cell(0, vim.v.count1)
      end,
    },
    prev_cell = {
      fn = function()
        if vim.wo.diff then
          vim.cmd("normal! " .. vim.v.count1 .. "[c")
          return
        end
        cb.goto_cell(0, -vim.v.count1)
      end,
    },
    inner_cell = {
      fn = function()
        M.select_cell(false)
      end,
    },
    around_cell = {
      fn = function()
        M.select_cell(true)
      end,
    },
    run_and_next = {
      fn = function()
        cb.run_cell_and_next(0)
      end,
    },
    run_cell_stay = {
      fn = function()
        cb.run_cell(0)
      end,
    },
    run_selection = {
      fn = function()
        local s, e = vim.fn.line("v"), vim.fn.line(".")
        vim.cmd("normal! \27")
        cb.run_range(0, math.min(s, e), math.max(s, e))
      end,
    },
    run_cell = {
      fn = function()
        cb.run_cell(0)
      end,
    },
    run_all = {
      fn = function()
        cb.run_all(0)
      end,
    },
    add_above = {
      fn = function()
        cb.add_cell(0, { where = "above", type = "code" })
      end,
    },
    add_below = {
      fn = function()
        cb.add_cell(0, { where = "below", type = "code" })
      end,
    },
    toggle_type = {
      fn = function()
        cb.toggle_cell_type(0)
      end,
    },
    delete_cell = {
      fn = function()
        cb.delete_cell(0)
      end,
    },
    move_up = {
      fn = function()
        cb.move_cell(0, -1)
      end,
    },
    move_down = {
      fn = function()
        cb.move_cell(0, 1)
      end,
    },
    split_cell = {
      fn = function()
        cb.split_cell(0)
      end,
    },
    merge_below = {
      fn = function()
        cb.merge_cell(0, "below")
      end,
    },
    clear_output = {
      fn = function()
        cb.clear_output(0)
      end,
    },
    clear_all = {
      fn = function()
        cb.clear_output(0, { all = true })
      end,
    },
    open_output = {
      fn = function()
        cb.open_output(0)
      end,
    },
    interrupt = {
      fn = function()
        cb.interrupt(0)
      end,
    },
    restart = {
      fn = function()
        cb.restart(0)
      end,
    },
    select_kernel = {
      fn = function()
        cb.select_kernel(0)
      end,
    },
  }
end

---Apply (or re-apply) mappings to a notebook buffer.
---@param nb cellbook.Notebook
function M.apply(nb)
  local bufnr = nb.bufnr
  local cfg = config.get(bufnr)
  -- remove previously applied mappings
  for _, m in ipairs(nb.applied_keymaps or {}) do
    pcall(vim.keymap.del, m[1], m[2], { buffer = bufnr })
  end
  nb.applied_keymaps = {}
  if cfg.keymaps == false then
    return
  end
  local user = type(cfg.keymaps) == "table" and cfg.keymaps or {}
  local acts = actions()
  for name, def in pairs(config.default_keymaps) do
    local lhs = def[2]
    if user[name] ~= nil then
      lhs = user[name]
    end
    if lhs then
      local modes = type(def[1]) == "table" and def[1] or { def[1] }
      vim.keymap.set(modes, lhs, acts[name].fn, { buffer = bufnr, desc = "Cellbook: " .. def[3], silent = true })
      for _, mode in ipairs(modes) do
        table.insert(nb.applied_keymaps, { mode, lhs })
      end
    end
  end
end

return M
