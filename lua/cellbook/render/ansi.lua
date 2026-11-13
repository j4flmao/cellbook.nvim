---ANSI SGR escape sequences → highlight chunks. Highlight groups are created
---on demand and cached (`CellbookAnsi_<fg>_<bg>_<attrs>`).
local M = {}

local base16 = {
  [0] = "#000000",
  "#cd3131",
  "#0dbc79",
  "#e5e510",
  "#2472c8",
  "#bc3fbc",
  "#11a8cd",
  "#e5e5e5",
  "#666666",
  "#f14c4c",
  "#23d18b",
  "#f5f543",
  "#3b8eea",
  "#d670d6",
  "#29b8db",
  "#ffffff",
}

---@param n integer 0..255
---@return string hex
function M.color256(n)
  if n < 16 then
    local tc = vim.g["terminal_color_" .. n]
    return type(tc) == "string" and tc or base16[n]
  elseif n < 232 then
    n = n - 16
    local steps = { 0, 95, 135, 175, 215, 255 }
    local r = steps[math.floor(n / 36) + 1]
    local g = steps[math.floor(n / 6) % 6 + 1]
    local b = steps[n % 6 + 1]
    return ("#%02x%02x%02x"):format(r, g, b)
  end
  local v = 8 + (n - 232) * 10
  return ("#%02x%02x%02x"):format(v, v, v)
end

---@class cellbook.AnsiState
---@field fg string?
---@field bg string?
---@field bold boolean?
---@field italic boolean?
---@field underline boolean?
---@field reverse boolean?
---@field dim boolean?
---@field strike boolean?

local cache = {}

---Reset cached highlight groups (after `:colorscheme`).
function M.reset()
  cache = {}
end

---@param st cellbook.AnsiState
---@param base string? base highlight group
---@return string? group
function M.group(st, base)
  if not (st.fg or st.bg or st.bold or st.italic or st.underline or st.reverse or st.dim or st.strike) then
    return base
  end
  local key = table.concat({
    st.fg or "",
    st.bg or "",
    st.bold and "b" or "",
    st.italic and "i" or "",
    st.underline and "u" or "",
    st.reverse and "r" or "",
    st.dim and "d" or "",
    st.strike and "s" or "",
  }, "_")
  local name = cache[key]
  if name then
    return name
  end
  name = "CellbookAnsi_" .. key:gsub("#", ""):gsub("[^%w_]", "")
  local spec = {
    fg = st.fg,
    bg = st.bg,
    bold = st.bold,
    italic = st.italic,
    underline = st.underline,
    reverse = st.reverse,
    strikethrough = st.strike,
  }
  if st.dim and not st.fg then
    spec.link = nil
    spec.fg = vim.api.nvim_get_hl(0, { name = "Comment", link = false }).fg
  end
  vim.api.nvim_set_hl(0, name, spec)
  cache[key] = name
  return name
end

---Apply SGR parameters to a state.
---@param st cellbook.AnsiState
---@param params string e.g. "1;31"
function M.apply_sgr(st, params)
  if params == "" then
    params = "0"
  end
  local codes = {}
  for p in (params .. ";"):gmatch("([^;:]*)[;:]") do
    codes[#codes + 1] = tonumber(p) or 0
  end
  local i = 1
  while i <= #codes do
    local c = codes[i]
    if c == 0 then
      for k in pairs(st) do
        st[k] = nil
      end
    elseif c == 1 then
      st.bold = true
    elseif c == 2 then
      st.dim = true
    elseif c == 3 then
      st.italic = true
    elseif c == 4 then
      st.underline = true
    elseif c == 7 then
      st.reverse = true
    elseif c == 9 then
      st.strike = true
    elseif c == 22 then
      st.bold, st.dim = nil, nil
    elseif c == 23 then
      st.italic = nil
    elseif c == 24 then
      st.underline = nil
    elseif c == 27 then
      st.reverse = nil
    elseif c == 29 then
      st.strike = nil
    elseif c >= 30 and c <= 37 then
      st.fg = M.color256(c - 30)
    elseif c == 38 or c == 48 then
      local key = c == 38 and "fg" or "bg"
      if codes[i + 1] == 5 and codes[i + 2] then
        st[key] = M.color256(math.max(0, math.min(255, codes[i + 2])))
        i = i + 2
      elseif codes[i + 1] == 2 and codes[i + 4] then
        st[key] = ("#%02x%02x%02x"):format(
          math.min(255, codes[i + 2]),
          math.min(255, codes[i + 3]),
          math.min(255, codes[i + 4])
        )
        i = i + 4
      end
    elseif c == 39 then
      st.fg = nil
    elseif c >= 40 and c <= 47 then
      st.bg = M.color256(c - 40)
    elseif c == 49 then
      st.bg = nil
    elseif c >= 90 and c <= 97 then
      st.fg = M.color256(c - 90 + 8)
    elseif c >= 100 and c <= 107 then
      st.bg = M.color256(c - 100 + 8)
    end
    i = i + 1
  end
end

---Parse one line with ANSI escapes into chunks `{text, hl_group}`.
---The state carries over to following lines (tracebacks span lines).
---@param line string
---@param st cellbook.AnsiState
---@param base string? base highlight group
---@param enabled boolean? convert colors (default true); false strips escapes
---@return table[] chunks
function M.parse_line(line, st, base, enabled)
  local chunks = {}
  local pos = 1
  local len = #line
  while pos <= len do
    local s, e, params, final = line:find("\27%[([%d;:?]*)([%a@])", pos)
    local osc_s, osc_e = line:find("\27%].-\7", pos)
    if not osc_s then
      osc_s, osc_e = line:find("\27%].-\27\\", pos)
    end
    if osc_s and (not s or osc_s < s) then
      if osc_s > pos then
        chunks[#chunks + 1] = { line:sub(pos, osc_s - 1), M.group(st, base) }
      end
      pos = osc_e + 1
    elseif s then
      if s > pos then
        chunks[#chunks + 1] = { line:sub(pos, s - 1), M.group(st, base) }
      end
      if final == "m" and enabled ~= false then
        M.apply_sgr(st, params)
      end
      pos = e + 1
    else
      chunks[#chunks + 1] = { line:sub(pos), M.group(st, base) }
      break
    end
  end
  -- stray ESC / other control chars are not printable in virtual text
  for _, ch in ipairs(chunks) do
    ch[1] = ch[1]:gsub("\27", ""):gsub("\t", "    "):gsub("[%z\1-\8\11-\31]", "")
  end
  if #chunks == 0 then
    chunks[1] = { "", base }
  end
  return chunks
end

---Strip all escape sequences.
---@param s string
---@return string
function M.strip(s)
  s = s:gsub("\27%[[%d;:?]*[%a@]", ""):gsub("\27%].-\7", "")
  return s
end

return M
