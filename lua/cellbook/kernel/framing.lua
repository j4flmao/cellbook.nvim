---NDJSON framing: reassemble newline-delimited messages from arbitrary chunks.
---Pure module (unit tested).
local M = {}

---@class cellbook.Framer
---@field parts string[]
local Framer = {}
Framer.__index = Framer

---@return cellbook.Framer
function M.new()
  return setmetatable({ parts = {} }, Framer)
end

---Feed a chunk; returns the complete lines it finished (without "\n" / "\r\n").
---@param chunk string
---@return string[] lines
function Framer:feed(chunk)
  local lines = {}
  local start = 1
  while true do
    local nl = chunk:find("\n", start, true)
    if not nl then
      break
    end
    local piece = chunk:sub(start, nl - 1)
    local line
    if #self.parts > 0 then
      self.parts[#self.parts + 1] = piece
      line = table.concat(self.parts)
      self.parts = {}
    else
      line = piece
    end
    if line:byte(-1) == 13 then
      line = line:sub(1, -2)
    end
    if line ~= "" then
      lines[#lines + 1] = line
    end
    start = nl + 1
  end
  if start <= #chunk then
    self.parts[#self.parts + 1] = chunk:sub(start)
  end
  return lines
end

---Bytes buffered without a terminating newline yet.
---@return integer
function Framer:pending()
  local n = 0
  for _, p in ipairs(self.parts) do
    n = n + #p
  end
  return n
end

return M
