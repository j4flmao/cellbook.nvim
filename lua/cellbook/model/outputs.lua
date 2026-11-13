---Output entities: normalization of nbformat outputs and Jupyter iopub messages,
---MIME selection and conversion back to nbformat. Pure module.
local json = require("cellbook.format.json")

local M = {}

---@alias cellbook.OutputType "stream"|"execute_result"|"display_data"|"error"

---@class cellbook.Output
---@field type cellbook.OutputType|string
---@field raw table?                    original nbformat JSON object (reused verbatim when unchanged)
---@field name string?                  stream name
---@field text string?                  stream text
---@field data table<string, any>?      MIME bundle
---@field metadata table?
---@field display_id string?
---@field ename string?
---@field evalue string?
---@field traceback string[]?
---@field execution_count integer?

---Join a multiline value (string or list of strings).
---@param v any
---@return any
local function join(v)
  if type(v) ~= "table" or json.is_object(v) or getmetatable(v) == json.number_mt then
    return v
  end
  if v[1] == nil and not json.is_array(v) then
    return v
  end
  for _, s in ipairs(v) do
    if type(s) ~= "string" then
      return v
    end
  end
  return table.concat(v)
end
M.join = join

---Python `str.splitlines(True)` restricted to "\n" (nbformat convention).
---@param s string
---@return string[]
function M.split_keepends(s)
  local out, n, i = json.array(), 0, 1
  while i <= #s do
    local nl = s:find("\n", i, true)
    n = n + 1
    if not nl then
      out[n] = s:sub(i)
      break
    end
    out[n] = s:sub(i, nl)
    i = nl + 1
  end
  return out
end

---@param raw table nbformat output object
---@return cellbook.Output
function M.from_raw(raw)
  local t = raw.output_type
  local out = { type = t, raw = raw }
  if t == "stream" then
    out.name = raw.name
    out.text = join(raw.text) or ""
  elseif t == "error" then
    out.ename = raw.ename
    out.evalue = raw.evalue
    out.traceback = raw.traceback or {}
  elseif t == "execute_result" or t == "display_data" then
    out.data = raw.data or json.object()
    out.metadata = raw.metadata
    out.execution_count = json.tonumber(raw.execution_count)
  end
  return out
end

---Remove text overwritten by carriage returns (progress bars).
---@param s string
---@return string
function M.fix_cr(s)
  if not s:find("\r", 1, true) then
    return s
  end
  s = s:gsub("\r\n", "\n")
  if not s:find("\r", 1, true) then
    return s
  end
  local lines = {}
  local i = 1
  while true do
    local nl = s:find("\n", i, true)
    local line = s:sub(i, nl and nl - 1 or #s)
    local last_cr
    local p = 1
    while true do
      local cr = line:find("\r", p, true)
      if not cr then
        break
      end
      last_cr = cr
      p = cr + 1
    end
    if last_cr then
      local after = line:sub(last_cr + 1)
      -- a trailing "\r" keeps the previous text until something overwrites it
      if after == "" then
        local prev_cr
        p = 1
        while true do
          local cr = line:find("\r", p, true)
          if not cr or cr == last_cr then
            break
          end
          prev_cr = cr
          p = cr + 1
        end
        after = line:sub((prev_cr or 0) + 1, last_cr) -- keep "\r" so the next chunk overwrites
      end
      line = after
    end
    lines[#lines + 1] = line
    if not nl then
      break
    end
    i = nl + 1
  end
  return table.concat(lines, "\n")
end

---Append stream text, handling "\r" only on the trailing line (O(new text)).
---@param prev string
---@param new string
---@return string
function M.append_stream(prev, new)
  local last_nl
  local p = #prev
  while p > 0 do
    if prev:byte(p) == 10 then
      last_nl = p
      break
    end
    p = p - 1
  end
  local head = last_nl and prev:sub(1, last_nl) or ""
  local tail = last_nl and prev:sub(last_nl + 1) or prev
  return head .. M.fix_cr(tail .. new)
end

---Build an Output from an iopub message.
---@param msg_type string
---@param content table
---@return cellbook.Output?
function M.from_msg(msg_type, content)
  if msg_type == "stream" then
    return { type = "stream", name = content.name or "stdout", text = M.fix_cr(content.text or "") }
  elseif msg_type == "error" then
    return { type = "error", ename = content.ename, evalue = content.evalue, traceback = content.traceback or {} }
  elseif msg_type == "display_data" or msg_type == "execute_result" then
    local transient = type(content.transient) == "table" and content.transient or nil
    return {
      type = msg_type,
      data = content.data or json.object(),
      metadata = content.metadata,
      display_id = transient and transient.display_id or nil,
      execution_count = json.tonumber(content.execution_count),
    }
  end
  return nil
end

---@class cellbook.OutputTarget
---@field outputs cellbook.Output[]
---@field clear_pending boolean?

---Apply one iopub message to a cell's outputs.
---@param cell cellbook.OutputTarget
---@param msg_type string
---@param content table
---@param find_display (fun(display_id: string): cellbook.Output[])?
---@return boolean changed
---@return cellbook.OutputTarget[]? others other cells changed by update_display_data
function M.apply(cell, msg_type, content, find_display)
  if msg_type == "clear_output" then
    if content.wait and content.wait ~= vim.NIL then
      cell.clear_pending = true
      return false
    end
    cell.outputs = {}
    cell.clear_pending = false
    return true
  end

  if msg_type == "update_display_data" then
    local id = type(content.transient) == "table" and content.transient.display_id
    if not id or not find_display then
      return false
    end
    local changed = false
    for _, out in ipairs(find_display(id)) do
      out.data = content.data or json.object()
      out.metadata = content.metadata
      out.raw = nil
      out.table_cache, out.blocks, out.size_cache = nil, nil, nil
      changed = true
    end
    return changed
  end

  local out = M.from_msg(msg_type, content)
  if not out then
    return false
  end
  if cell.clear_pending then
    cell.outputs = {}
    cell.clear_pending = false
  end
  local last = cell.outputs[#cell.outputs]
  if out.type == "stream" and last and last.type == "stream" and last.name == out.name then
    last.text = M.append_stream(last.text or "", content.text or "")
    last.raw = nil
  else
    cell.outputs[#cell.outputs + 1] = out
  end
  return true
end

local split_mimes = { ["image/svg+xml"] = true }

---@param mime string
---@return boolean
function M.is_json_mime(mime)
  return mime == "application/json" or (mime:match("^application/.+%+json$") ~= nil)
end

---nbformat `split_lines` for a MIME bundle.
---@param data table
---@return table
function M.split_bundle(data)
  local out = json.object()
  for mime, value in pairs(data) do
    if type(value) == "string" and (mime:sub(1, 5) == "text/" or split_mimes[mime]) then
      out[mime] = M.split_keepends(value)
    else
      out[mime] = json.deepcopy(value)
    end
  end
  return out
end

local function as_object(t)
  if type(t) ~= "table" then
    return json.object()
  end
  if getmetatable(t) == nil then
    return setmetatable(json.deepcopy(t), json.object_mt)
  end
  return json.deepcopy(t)
end

---Convert an Output to its nbformat JSON object.
---@param out cellbook.Output
---@param execution_count integer|userdata|nil
---@return table
function M.to_nbformat(out, execution_count)
  if out.raw then
    return out.raw
  end
  local t = out.type
  if t == "stream" then
    return json.object({ output_type = "stream", name = out.name or "stdout", text = M.split_keepends(out.text or "") })
  elseif t == "error" then
    local tb = json.array()
    for i, l in ipairs(out.traceback or {}) do
      tb[i] = l
    end
    return json.object({ output_type = "error", ename = out.ename or "", evalue = out.evalue or "", traceback = tb })
  end
  local o = json.object({
    output_type = t,
    data = M.split_bundle(out.data or {}),
    metadata = as_object(out.metadata),
  })
  if t == "execute_result" then
    local ec = execution_count
    if ec == nil then
      ec = out.execution_count
    end
    o.execution_count = ec == nil and vim.NIL or ec
  end
  return o
end

---Get one MIME value as a string (joining multiline lists).
---@param out cellbook.Output
---@param mime string
---@return any
function M.get(out, mime)
  if not out.data then
    return nil
  end
  return join(out.data[mime])
end

---Choose the MIME type to display.
---@param out cellbook.Output
---@param priority string[]
---@param supports (fun(mime: string): boolean)? image support predicate
---@return string? mime
function M.select_mime(out, priority, supports)
  local data = out.data
  if not data then
    return nil
  end
  for _, mime in ipairs(priority) do
    if data[mime] ~= nil then
      if mime == "image/svg+xml" then
        if supports and supports(mime) then
          return mime
        end
      else
        return mime
      end
    end
  end
  if data["text/plain"] ~= nil then
    return "text/plain"
  end
  for mime in pairs(data) do
    if mime:sub(1, 6) == "image/" and mime ~= "image/svg+xml" then
      return mime
    end
  end
  return nil
end

---Read PNG dimensions from decoded bytes.
---@param bytes string
---@return integer? width, integer? height
function M.png_size(bytes)
  if #bytes < 24 or bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    return nil
  end
  local function u32(i)
    local a, b, c, d = bytes:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return u32(17), u32(21)
end

return M
