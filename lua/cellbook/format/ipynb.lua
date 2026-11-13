---Parse and serialize nbformat 4.x documents. Pure module (no UI APIs).
---
---Round-trip contract: an unmodified notebook serializes to its original bytes.
---Modified notebooks are written with Jupyter's formatting
---(`indent=1`, sorted keys, `ensure_ascii=False`, trailing newline); unchanged cells
---reuse their original JSON values verbatim.
local json = require("cellbook.format.json")
local Cell = require("cellbook.model.cell")
local outputs = require("cellbook.model.outputs")
local percent = require("cellbook.format.percent")

local M = {}

---@class cellbook.ParseError
---@field kind "invalid_utf8"|"invalid_json"|"not_notebook"|"unsupported_version"
---@field message string

---@class cellbook.NotebookData
---@field raw table
---@field nbformat integer
---@field nbformat_minor integer
---@field metadata table
---@field cells cellbook.Cell[]
---@field orig_cells table[]           raw cell objects in original order
---@field language string
---@field comment string               comment leader for markdown/raw lines
---@field original_text string
---@field newline string
---@field bom boolean
---@field meta_dirty boolean

---Validate UTF-8 (fast path for ASCII-only text).
---@param s string
---@return boolean ok, integer? bad_pos
function M.valid_utf8(s)
  local i = s:find("[\128-\255]")
  if not i then
    return true
  end
  local len = #s
  local byte = string.byte
  while i and i <= len do
    local c = byte(s, i)
    local n
    if c < 0x80 then
      n = 0
    elseif c >= 0xC2 and c <= 0xDF then
      n = 1
    elseif c >= 0xE0 and c <= 0xEF then
      n = 2
    elseif c >= 0xF0 and c <= 0xF4 then
      n = 3
    else
      return false, i
    end
    for k = 1, n do
      local cc = byte(s, i + k)
      if not cc or cc < 0x80 or cc > 0xBF then
        return false, i
      end
    end
    if n == 0 then
      i = s:find("[\128-\255]", i + 1)
    else
      i = s:find("[\128-\255]", i + n + 1)
    end
  end
  return true
end

---Resolve the kernel language of a notebook.
---@param metadata table
---@param default string?
---@return string
function M.language_of(metadata, default)
  local ks = type(metadata) == "table" and metadata.kernelspec
  if type(ks) == "table" and type(ks.language) == "string" and ks.language ~= "" then
    return ks.language:lower()
  end
  local li = type(metadata) == "table" and metadata.language_info
  if type(li) == "table" and type(li.name) == "string" and li.name ~= "" then
    return li.name:lower()
  end
  return default or "python"
end

---@param text string
---@return string
local function detect_newline(text)
  local nl = text:find("\n", 1, true)
  if nl and nl > 1 and text:byte(nl - 1) == 13 then
    return "\r\n"
  end
  return "\n"
end

---Parse notebook text.
---@param text string
---@param opts {default_language: string?}?
---@return cellbook.NotebookData? nb
---@return cellbook.ParseError? err
function M.parse(text, opts)
  opts = opts or {}
  local bom = false
  if text:sub(1, 3) == "\239\187\191" then
    bom = true
    text = text:sub(4)
  end
  local ok_utf8, bad = M.valid_utf8(text)
  if not ok_utf8 then
    return nil, { kind = "invalid_utf8", message = ("invalid UTF-8 at byte %d"):format(bad) }
  end
  local doc, err = json.pdecode(text)
  if not doc then
    ---@cast err -nil
    return nil,
      {
        kind = "invalid_json",
        message = ("invalid JSON at line %d, column %d: %s"):format(err.line, err.col, err.message),
      }
  end
  if not json.is_object(doc) then
    return nil, { kind = "not_notebook", message = "top-level JSON value is not an object" }
  end
  local major = json.tonumber(doc.nbformat)
  if major ~= 4 then
    return nil,
      {
        kind = "unsupported_version",
        message = ("nbformat %s is not supported; convert with: jupyter nbconvert --to notebook --nbformat 4 <file>"):format(
          tostring(major)
        ),
      }
  end
  if not json.is_array(doc.cells) then
    return nil, { kind = "not_notebook", message = "notebook has no 'cells' array" }
  end
  if type(doc.metadata) ~= "table" then
    doc.metadata = json.object()
  end
  local language = M.language_of(doc.metadata, opts.default_language)
  local nb = {
    raw = doc,
    nbformat = 4,
    nbformat_minor = json.tonumber(doc.nbformat_minor) or 0,
    metadata = doc.metadata,
    cells = {},
    orig_cells = {},
    language = language,
    comment = percent.comment_for(language),
    original_text = (bom and "\239\187\191" or "") .. text,
    newline = detect_newline(text),
    bom = bom,
    meta_dirty = false,
  }
  for i, raw in ipairs(doc.cells) do
    nb.cells[i] = Cell.from_raw(raw)
    nb.orig_cells[i] = raw
  end
  return nb, nil
end

---A new, empty notebook (used for `:e new.ipynb`).
---@param language string?
---@return cellbook.NotebookData
function M.empty(language)
  language = language or "python"
  local doc = json.object({
    cells = json.array(),
    metadata = json.object(),
    nbformat = 4,
    nbformat_minor = 5,
  })
  if language == "python" then
    doc.metadata.language_info = json.object({ name = "python" })
  end
  local nb = {
    raw = doc,
    nbformat = 4,
    nbformat_minor = 5,
    metadata = doc.metadata,
    cells = {},
    orig_cells = {},
    language = language,
    comment = percent.comment_for(language),
    original_text = nil,
    newline = "\n",
    bom = false,
    meta_dirty = true,
  }
  local cell = Cell.new("code", { id = Cell.new_id() })
  nb.cells[1] = cell
  return nb
end

---@param src string
---@param template any original source value (string or list)
local function source_value(src, template)
  if type(template) == "string" then
    return src
  end
  return outputs.split_keepends(src)
end

---Shallow copy of a JSON object keeping its metatable.
local function shallow(t)
  local c = {}
  for k, v in pairs(t) do
    c[k] = v
  end
  return setmetatable(c, json.object_mt)
end

---@class cellbook.SerializeOpts
---@field strip_outputs boolean?

---Build the JSON object for one cell.
---@param cell cellbook.Cell
---@param source string
---@param opts cellbook.SerializeOpts
---@return table raw
---@return boolean changed
local function build_cell(cell, source, opts)
  local raw = cell.raw
  local source_changed = source ~= cell.orig_source
  local type_changed = raw ~= nil and raw.cell_type ~= cell.type
  local strip = opts.strip_outputs
    and cell.type == "code"
    and raw ~= nil
    and (
      (type(raw.outputs) == "table" and #raw.outputs > 0)
      or (raw.execution_count ~= nil and raw.execution_count ~= vim.NIL)
    )
  if raw and not source_changed and not type_changed and not cell.outputs_dirty and not strip then
    return raw, false
  end

  local o = raw and shallow(raw) or json.object()
  o.cell_type = cell.type
  if raw and not source_changed then
    o.source = raw.source
  else
    o.source = source_value(source, raw and raw.source)
  end
  if o.metadata == nil then
    o.metadata = json.object()
  end
  if cell.id then
    o.id = cell.id
  end
  if cell.type == "code" then
    if opts.strip_outputs then
      o.outputs = json.array()
      o.execution_count = vim.NIL
    elseif cell.outputs_dirty or not raw or type_changed then
      local arr = json.array()
      for i, out in ipairs(cell.outputs) do
        arr[i] = outputs.to_nbformat(out, cell.execution_count)
      end
      o.outputs = arr
      o.execution_count = cell.execution_count == nil and vim.NIL or cell.execution_count
    end
    if o.outputs == nil then
      o.outputs = json.array()
    end
    if o.execution_count == nil then
      o.execution_count = vim.NIL
    end
  else
    o.outputs = nil
    o.execution_count = nil
  end
  return o, true
end

---Serialize a notebook.
---@param nb cellbook.NotebookData
---@param sources string[] current source text per cell (aligned with nb.cells)
---@param opts cellbook.SerializeOpts?
---@return string text
---@return table[] raw_cells built cell objects (pass to `commit`)
function M.serialize(nb, sources, opts)
  opts = opts or {}
  local any_changed = nb.meta_dirty or #nb.cells ~= #nb.orig_cells or nb.original_text == nil
  local raw_cells = json.array()
  for i, cell in ipairs(nb.cells) do
    local raw, changed = build_cell(cell, sources[i] or cell.source or "", opts)
    raw_cells[i] = raw
    if changed or raw ~= nb.orig_cells[i] then
      any_changed = true
    end
  end
  if not any_changed then
    return nb.original_text, raw_cells
  end
  local doc = shallow(nb.raw)
  doc.cells = raw_cells
  doc.metadata = nb.metadata
  local text = json.encode(doc, { indent = 1, newline = nb.newline }) .. nb.newline
  if nb.bom then
    text = "\239\187\191" .. text
  end
  return text, raw_cells
end

---Record a successful save: the written text becomes the new baseline.
---@param nb cellbook.NotebookData
---@param text string
---@param raw_cells table[]
---@param sources string[]
function M.commit(nb, text, raw_cells, sources)
  nb.original_text = text
  nb.meta_dirty = false
  nb.raw.cells = raw_cells
  nb.orig_cells = {}
  for i, cell in ipairs(nb.cells) do
    local raw = raw_cells[i]
    nb.orig_cells[i] = raw
    cell.raw = raw
    cell.orig_source = sources[i] or cell.source or ""
    cell.outputs_dirty = false
    if cell.type == "code" and type(raw.outputs) == "table" then
      for j, out in ipairs(cell.outputs) do
        if raw.outputs[j] then
          out.raw = raw.outputs[j]
        end
      end
    end
  end
end

return M
