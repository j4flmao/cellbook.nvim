---Cell entity. Pure module.
local json = require("cellbook.format.json")
local outputs = require("cellbook.model.outputs")

local M = {}

---@alias cellbook.CellType "code"|"markdown"|"raw"
---@alias cellbook.RunState "idle"|"queued"|"running"|"done"|"error"|"interrupted"|"cancelled"

---@class cellbook.Cell
---@field id string?                    nbformat cell id (nil for nbformat_minor < 5)
---@field type cellbook.CellType|string
---@field mark integer?                 extmark id on the delimiter line
---@field raw table?                    original JSON object (nil for new cells)
---@field orig_source string            source text at load/last save
---@field source string                 source text (only authoritative while no buffer is attached)
---@field snapshot string?              last known buffer text of the body (for undo/redo re-adoption)
---@field outputs cellbook.Output[]
---@field outputs_dirty boolean
---@field execution_count integer|userdata  integer or vim.NIL
---@field run_state cellbook.RunState
---@field run_started_at number?
---@field run_duration_ms number?
---@field run_source string?            source text at execution start (for the stale marker)
---@field collapsed_output boolean
---@field clear_pending boolean?
---@field view table?                   render state (never serialized)

local ID_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789"
local seeded = false

---Generate a fresh nbformat-compliant cell id, unique within `existing`.
---@param existing table<string, any>?
---@return string
function M.new_id(existing)
  if not seeded then
    local seed = os.time()
    if vim and vim.uv then
      seed = seed + vim.uv.hrtime() % 1000003
    end
    math.randomseed(seed)
    seeded = true
  end
  while true do
    local t = {}
    for i = 1, 8 do
      local k = math.random(1, #ID_CHARS)
      t[i] = ID_CHARS:sub(k, k)
    end
    local id = table.concat(t)
    if not existing or not existing[id] then
      return id
    end
  end
end

---@param id any
---@return boolean
function M.valid_id(id)
  return type(id) == "string" and #id >= 1 and #id <= 64 and id:match("^[%w_-]+$") ~= nil
end

---@param raw table nbformat cell
---@return cellbook.Cell
function M.from_raw(raw)
  local src = raw.source
  local text
  if type(src) == "string" then
    text = src
  elseif type(src) == "table" then
    text = table.concat(src)
  else
    text = ""
  end
  local cell = {
    id = type(raw.id) == "string" and raw.id or nil,
    type = raw.cell_type or "raw",
    raw = raw,
    orig_source = text,
    source = text,
    snapshot = nil,
    outputs = {},
    outputs_dirty = false,
    execution_count = vim.NIL,
    run_state = "idle",
    collapsed_output = false,
  }
  if cell.type == "code" then
    local ec = raw.execution_count
    cell.execution_count = (ec == nil) and vim.NIL or json.tonumber(ec)
    if type(raw.outputs) == "table" then
      for i, o in ipairs(raw.outputs) do
        cell.outputs[i] = outputs.from_raw(o)
      end
    end
  end
  return cell
end

---Create a new cell.
---@param cell_type cellbook.CellType
---@param opts {id: string?, source: string?}?
---@return cellbook.Cell
function M.new(cell_type, opts)
  opts = opts or {}
  return {
    id = opts.id,
    type = cell_type,
    raw = nil,
    orig_source = "",
    source = opts.source or "",
    outputs = {},
    outputs_dirty = false,
    execution_count = vim.NIL,
    run_state = "idle",
    collapsed_output = false,
  }
end

---Copy of a cell with a different type (used by "change type", keeps id/metadata).
---Converting away from code drops outputs and execution_count (nbformat rule).
---@param cell cellbook.Cell
---@param new_type cellbook.CellType
---@return cellbook.Cell
function M.retyped(cell, new_type)
  local c = {}
  for k, v in pairs(cell) do
    c[k] = v
  end
  c.type = new_type
  c.mark = nil
  c.view = nil
  c.outputs = {}
  c.outputs_dirty = cell.type == "code" and #cell.outputs > 0
  c.execution_count = vim.NIL
  c.run_state = "idle"
  c.run_source = nil
  return c
end

---Whether the cell's outputs are non-empty.
---@param cell cellbook.Cell
function M.has_outputs(cell)
  return cell.type == "code" and #cell.outputs > 0
end

return M
