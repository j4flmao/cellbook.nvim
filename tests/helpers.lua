-- Shared test helpers (loaded with dofile from specs).
local H = {}

H.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
H.fixtures = H.root .. "/tests/fixtures/notebooks"

function H.read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

function H.write(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

function H.fixture_list()
  local list = vim.fn.globpath(H.fixtures, "*.ipynb", false, true)
  table.sort(list)
  return list
end

---Copy a fixture to a temp file and return its path.
function H.tmp_copy(name)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local dst = dir .. "/" .. name
  H.write(dst, H.read(H.fixtures .. "/" .. name))
  return dst
end

---Open a notebook file in the current window.
function H.open(path)
  vim.cmd("silent edit " .. vim.fn.fnameescape(path))
  return require("cellbook.model.notebook").get(0)
end

---Close the current undo block (scripted edits are otherwise one undo step).
function H.undo_break()
  vim.cmd("let &undolevels = &undolevels")
end

function H.refresh(nb)
  require("cellbook.buffer.tracker").refresh(nb or require("cellbook.model.notebook").get(0))
end

function H.lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

---Decoded JSON of a file (plain tables via vim.json).
function H.json(path)
  return vim.json.decode(H.read(path))
end

function H.wipe_all()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
end

---Text of rendered output lines for a cell (without the output gutter and the
---spacer line below the cell).
function H.view_text(cell)
  local out = {}
  for _, l in ipairs(cell.view and cell.view.lines or {}) do
    local s = {}
    for i, ch in ipairs(l) do
      if not (i == 1 and type(ch[2]) == "string" and ch[2]:find("^CellbookOutputGutter")) then
        s[#s + 1] = ch[1]
      end
    end
    out[#out + 1] = table.concat(s)
  end
  if out[#out] == "" then
    out[#out] = nil
  end
  return out
end

return H
