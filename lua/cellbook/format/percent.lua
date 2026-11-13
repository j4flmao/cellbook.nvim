---Notebook model ↔ buffer lines in "percent" format.
---
---Each cell is one delimiter line followed by its source lines:
---
---    # %%                 code cell
---    # %% [markdown]      markdown cell (source lines prefixed with "# ")
---    # %% [raw]           raw cell (same prefixing)
---
---The comment leader depends on the kernel language. Pure module (no UI APIs).
local M = {}

---Comment leader per language/filetype.
M.comment_leaders = {
  python = "#",
  r = "#",
  julia = "#",
  sh = "#",
  bash = "#",
  zsh = "#",
  ruby = "#",
  perl = "#",
  raku = "#",
  nim = "#",
  elixir = "#",
  powershell = "#",
  ps1 = "#",
  coconut = "#",
  sage = "#",
  stata = "*",
  lua = "--",
  haskell = "--",
  sql = "--",
  ada = "--",
  javascript = "//",
  typescript = "//",
  rust = "//",
  go = "//",
  c = "//",
  cpp = "//",
  java = "//",
  scala = "//",
  kotlin = "//",
  cs = "//",
  fsharp = "//",
  dart = "//",
  swift = "//",
  groovy = "//",
  matlab = "%",
  octave = "%",
  wolfram = "(*",
  ocaml = "(*",
  scheme = ";",
  clojure = ";",
  lisp = ";",
  racket = ";",
}

---Map Jupyter language names to Neovim filetypes.
M.filetypes = {
  ["c++"] = "cpp",
  ["c#"] = "cs",
  ["f#"] = "fsharp",
  csharp = "cs",
  ["q#"] = "qsharp",
  ipython = "python",
  ipython3 = "python",
  python3 = "python",
  bash = "sh",
  zsh = "zsh",
  powershell = "ps1",
  javascript = "javascript",
  typescript = "typescript",
  octave = "octave",
  ["wolfram language"] = "mma",
  ["text/x-python"] = "python",
}

---@param language string
---@return string filetype
function M.filetype_for(language)
  language = (language or "python"):lower()
  return M.filetypes[language] or language
end

---@param language string kernel language or filetype
---@return string
function M.comment_for(language)
  local ft = M.filetype_for(language)
  return M.comment_leaders[ft] or M.comment_leaders[(language or ""):lower()] or "#"
end

local type_tags = { markdown = " [markdown]", raw = " [raw]" }

---@param cell_type string
---@param c string comment leader
---@return string
function M.delimiter(cell_type, c)
  if cell_type == "code" then
    return c .. " %%"
  end
  return c .. " %%" .. (type_tags[cell_type] or " [raw]")
end

---@param line string?
---@param c string
---@return boolean
function M.is_delimiter(line, c)
  if not line then
    return false
  end
  local p = c .. " %%"
  return line:sub(1, #p) == p
end

---Cell type named by a delimiter line ("code" when no tag).
---@param line string
---@param c string
---@return "code"|"markdown"|"raw"
function M.delimiter_type(line, c)
  local rest = line:sub(#c + 4)
  if rest:find("%[markdown%]") or rest:find("%[md%]") then
    return "markdown"
  elseif rest:find("%[raw%]") then
    return "raw"
  end
  return "code"
end

---@param cell_type string
---@return boolean
function M.is_prefixed(cell_type)
  return cell_type ~= "code"
end

---Split a source string on "\n" (always at least one line).
---@param source string
---@return string[]
function M.split(source)
  local lines, n, i = {}, 0, 1
  while true do
    local nl = source:find("\n", i, true)
    n = n + 1
    if not nl then
      lines[n] = source:sub(i)
      return lines
    end
    lines[n] = source:sub(i, nl - 1)
    i = nl + 1
  end
end

---Source text → buffer lines for one cell body.
---@param cell_type string
---@param source string
---@param c string
---@return string[]
function M.source_to_lines(cell_type, source, c)
  local lines = M.split(source)
  if M.is_prefixed(cell_type) then
    for i, l in ipairs(lines) do
      lines[i] = l == "" and c or (c .. " " .. l)
    end
  end
  return lines
end

---Strip the comment prefix of one markdown/raw line.
---@param line string
---@param c string
---@return string
function M.strip_prefix(line, c)
  if line == c then
    return ""
  end
  local p = c .. " "
  if line:sub(1, #p) == p then
    return line:sub(#p + 1)
  end
  return line
end

---Buffer lines of a cell body → source text.
---@param cell_type string
---@param lines string[]
---@param c string
---@return string
function M.lines_to_source(cell_type, lines, c)
  if #lines == 0 then
    return ""
  end
  if M.is_prefixed(cell_type) then
    local out = {}
    for i, l in ipairs(lines) do
      out[i] = M.strip_prefix(l, c)
    end
    return table.concat(out, "\n")
  end
  return table.concat(lines, "\n")
end

---Render a list of cells as buffer lines.
---@param cells {type: string, source: string}[]
---@param c string
---@return string[] lines
---@return integer[] starts 0-based row of each cell delimiter
function M.to_lines(cells, c)
  local lines, starts, n = {}, {}, 0
  for i, cell in ipairs(cells) do
    starts[i] = n
    n = n + 1
    lines[n] = M.delimiter(cell.type, c)
    for _, l in ipairs(M.source_to_lines(cell.type, cell.source or "", c)) do
      n = n + 1
      lines[n] = l
    end
  end
  return lines, starts
end

return M
