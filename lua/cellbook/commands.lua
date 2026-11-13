---`:Cellbook {subcommand}` with completion.
local M = {}

local function cb()
  return require("cellbook")
end

---@param ok any
---@param err string?
local function report(ok, err)
  if ok == nil and err then
    vim.notify("cellbook: " .. err, vim.log.levels.WARN)
  end
end

---Floating window with notebook + kernel info.
local function info()
  local Notebook = require("cellbook.model.notebook")
  local nb = Notebook.get(0)
  if not nb then
    return report(nil, "not a notebook buffer")
  end
  local lines = {
    "cellbook.nvim",
    "",
    "File:        " .. vim.fn.fnamemodify(nb.path, ":~"),
  }
  if nb.readonly then
    lines[#lines + 1] = "Read-only:   " .. tostring(nb.readonly_reason)
  else
    local ks = type(nb.metadata) == "table" and nb.metadata.kernelspec or nil
    local counts = { code = 0, markdown = 0, raw = 0 }
    for _, c in ipairs(nb.cells) do
      local t = require("cellbook.buffer.tracker").display_type(c)
      counts[t] = counts[t] + 1
    end
    vim.list_extend(lines, {
      ("nbformat:    %d.%d"):format(nb.nbformat, nb.nbformat_minor),
      ("Cells:       %d (%d code, %d markdown, %d raw)"):format(#nb.cells, counts.code, counts.markdown, counts.raw),
      "Language:    " .. nb.language .. " (filetype " .. nb.filetype .. ")",
      "Kernelspec:  "
        .. (type(ks) == "table" and (tostring(ks.display_name) .. " [" .. tostring(ks.name) .. "]") or "(none)"),
    })
    local s = nb.session
    if s then
      vim.list_extend(lines, {
        "",
        "Kernel:      " .. tostring(s.display_name or s.kernel_name or "-"),
        "State:       " .. s.state,
        "Queue:       " .. #s.queue .. (s.current and " (+1 running)" or ""),
        "Python:      " .. tostring(s.python or "-") .. (s.python_version and (" (" .. s.python_version .. ")") or ""),
        "Bridge PID:  " .. tostring(s.bridge and s.bridge:pid() or "-"),
      })
    else
      vim.list_extend(lines, { "", "Kernel:      not started (runs on first execution)" })
    end
    local adapter, why = require("cellbook.render.image").select(require("cellbook.config").get(nb.bufnr).image.backend)
    lines[#lines + 1] = "Images:      " .. (adapter and adapter.name or ("placeholder (" .. tostring(why) .. ")"))
  end
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.api.nvim_strwidth(l))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = math.min(width + 2, vim.o.columns - 4),
    height = #lines,
    row = math.floor((vim.o.lines - #lines) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Cellbook ",
  })
  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf })
end

---Raw JSON (current serialization) read-only in a split.
local function raw()
  local nb = require("cellbook.model.notebook").get(0)
  if not nb then
    return report(nil, "not a notebook buffer")
  end
  local text
  if nb.readonly then
    text = nb.raw_text or ""
  else
    text = require("cellbook.buffer.attach").serialize(nb)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "json"
  pcall(vim.api.nvim_buf_set_name, buf, "cellbook://raw/" .. vim.fn.fnamemodify(nb.path, ":t"))
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, buf)
end

local function refresh()
  local nb = require("cellbook.model.notebook").get(0)
  if not nb or nb.readonly then
    return report(nil, "not a notebook buffer")
  end
  require("cellbook.render.image").reset()
  require("cellbook.render.ansi").reset()
  require("cellbook.buffer.decor").setup_highlights()
  local tracker = require("cellbook.buffer.tracker")
  tracker.flush(nb)
  require("cellbook.buffer.decor").full(nb)
  require("cellbook.render.text").render_all(nb)
  require("cellbook.keymaps").apply(nb)
end

---@class cellbook.Subcommand
---@field run fun(args: string[], cmd: table)
---@field complete string[]?
---@field desc string

---@type table<string, cellbook.Subcommand>
M.subcommands = {
  run = {
    desc = "Run current cell (with a range: run selected lines)",
    run = function(_, cmd)
      if cmd.range > 0 then
        report(cb().run_range(0, cmd.line1, cmd.line2))
      else
        report(cb().run_cell(0))
      end
    end,
  },
  run_next = {
    desc = "Run cell and move to next",
    run = function()
      report(cb().run_cell_and_next(0))
    end,
  },
  run_all = {
    desc = "Run all cells",
    run = function()
      report(cb().run_all(0))
    end,
  },
  run_above = {
    desc = "Run cells above the current one",
    run = function()
      report(cb().run_above(0))
    end,
  },
  run_below = {
    desc = "Run current and following cells",
    run = function()
      report(cb().run_below(0))
    end,
  },
  interrupt = {
    desc = "Interrupt the kernel",
    run = function()
      report(cb().interrupt(0))
    end,
  },
  restart = {
    desc = "Restart the kernel (`restart run_all` to run all afterwards)",
    complete = { "run_all" },
    run = function(args)
      report(cb().restart(0, { run_all = args[1] == "run_all" }))
    end,
  },
  shutdown = {
    desc = "Shut down the kernel",
    run = function()
      report(cb().shutdown(0))
    end,
  },
  kernel = {
    desc = "Select kernel",
    run = function()
      report(cb().select_kernel(0))
    end,
  },
  add = {
    desc = "Add cell: add [above|below] [code|markdown|raw]",
    complete = { "above", "below", "code", "markdown", "raw" },
    run = function(args)
      local opts = { where = "below", type = "code" }
      for _, a in ipairs(args) do
        if a == "above" or a == "below" then
          opts.where = a
        elseif a == "code" or a == "markdown" or a == "raw" then
          opts.type = a
        else
          return report(nil, "invalid argument: " .. a)
        end
      end
      report(cb().add_cell(0, opts))
    end,
  },
  delete = {
    desc = "Delete cell",
    run = function()
      report(cb().delete_cell(0))
    end,
  },
  move = {
    desc = "Move cell: move up|down",
    complete = { "up", "down" },
    run = function(args)
      if args[1] ~= "up" and args[1] ~= "down" then
        return report(nil, "usage: :Cellbook move up|down")
      end
      report(cb().move_cell(0, args[1] == "up" and -1 or 1))
    end,
  },
  split = {
    desc = "Split cell at cursor",
    run = function()
      report(cb().split_cell(0))
    end,
  },
  merge = {
    desc = "Merge cell: merge [below|above]",
    complete = { "below", "above" },
    run = function(args)
      report(cb().merge_cell(0, args[1] == "above" and "above" or "below"))
    end,
  },
  type = {
    desc = "Change cell type: type code|markdown|raw",
    complete = { "code", "markdown", "raw" },
    run = function(args)
      if not args[1] then
        return report(cb().toggle_cell_type(0))
      end
      report(cb().set_cell_type(0, args[1]))
    end,
  },
  clear = {
    desc = "Clear output (`clear all` for every cell)",
    complete = { "all" },
    run = function(args)
      report(cb().clear_output(0, { all = args[1] == "all" }))
    end,
  },
  toggle = {
    desc = "Hide/show output (`toggle all` for every cell)",
    complete = { "all" },
    run = function(args)
      report(cb().toggle_output(0, { all = args[1] == "all" }))
    end,
  },
  open = {
    desc = "Open full output",
    run = function()
      report(cb().open_output(0))
    end,
  },
  info = { desc = "Show notebook and kernel info", run = info },
  log = {
    desc = "Open the bridge/kernel log",
    run = function()
      require("cellbook.log").open()
    end,
  },
  raw = { desc = "Show the notebook JSON read-only", run = raw },
  refresh = { desc = "Re-render decorations and outputs", run = refresh },
  sync = {
    desc = "Turn typed delimiter lines into cells",
    run = function()
      local nb = require("cellbook.model.notebook").get(0)
      if not nb or nb.readonly then
        return report(nil, "not a notebook buffer")
      end
      require("cellbook.buffer.tracker").sync(nb)
    end,
  },
}

---@return string[]
function M.names()
  local names = vim.tbl_keys(M.subcommands)
  table.sort(names)
  return names
end

---@param cmd table nvim_create_user_command callback argument
function M.dispatch(cmd)
  local args = vim.deepcopy(cmd.fargs)
  local name = table.remove(args, 1)
  if not name then
    local names = M.names()
    vim.ui.select(names, {
      prompt = "Cellbook",
      format_item = function(n)
        return ("%-10s %s"):format(n, M.subcommands[n].desc)
      end,
    }, function(choice)
      if choice then
        M.subcommands[choice].run({}, cmd)
      end
    end)
    return
  end
  local sub = M.subcommands[name]
  if not sub then
    vim.notify(
      ("cellbook: unknown subcommand '%s'. Valid: %s"):format(name, table.concat(M.names(), ", ")),
      vim.log.levels.ERROR
    )
    return
  end
  sub.run(args, cmd)
end

---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
  local parts = vim.split((cmdline:gsub("^%s*%S+%s*", "")), "%s+", { trimempty = true })
  local completing_first = #parts == 0 or (#parts == 1 and arglead ~= "")
  local function filter(list)
    return vim.tbl_filter(function(s)
      return s:sub(1, #arglead) == arglead
    end, list)
  end
  if completing_first then
    return filter(M.names())
  end
  local sub = M.subcommands[parts[1]]
  return sub and sub.complete and filter(sub.complete) or {}
end

return M
