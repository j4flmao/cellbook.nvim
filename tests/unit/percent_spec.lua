local percent = require("cellbook.format.percent")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["delimiters per type"] = function()
  eq(percent.delimiter("code", "#"), "# %%")
  eq(percent.delimiter("markdown", "#"), "# %% [markdown]")
  eq(percent.delimiter("raw", "#"), "# %% [raw]")
  eq(percent.delimiter("markdown", "--"), "-- %% [markdown]")
  eq(percent.delimiter_type("# %% [markdown]", "#"), "markdown")
  eq(percent.delimiter_type("# %% [md]", "#"), "markdown")
  eq(percent.delimiter_type("# %%", "#"), "code")
  eq(percent.delimiter_type("# %% [raw]", "#"), "raw")
  eq(percent.is_delimiter("# %% title", "#"), true)
  eq(percent.is_delimiter("#%%", "#"), false)
end

T["comment leaders by language"] = function()
  eq(percent.comment_for("python"), "#")
  eq(percent.comment_for("R"), "#")
  eq(percent.comment_for("julia"), "#")
  eq(percent.comment_for("lua"), "--")
  eq(percent.comment_for("c++"), "//")
  eq(percent.comment_for("unknown-lang"), "#")
  eq(percent.filetype_for("C++"), "cpp")
  eq(percent.filetype_for("python"), "python")
end

T["to_lines"] = function()
  local lines, starts = percent.to_lines({
    { type = "markdown", source = "# Title\n\ntext" },
    { type = "code", source = "x = 1\nx" },
    { type = "code", source = "" },
    { type = "raw", source = "raw\n" },
  }, "#")
  eq(
    lines,
    { "# %% [markdown]", "# # Title", "#", "# text", "# %%", "x = 1", "x", "# %%", "", "# %% [raw]", "# raw", "#" }
  )
  eq(starts, { 0, 4, 7, 9 })
end

T["lines_to_source inverts source_to_lines"] = function()
  local cases = { "", "a", "a\n", "a\n\nb", "  indented\n# heading", "#notprefixed", "\n\n" }
  for _, t in ipairs({ "code", "markdown", "raw" }) do
    for _, src in ipairs(cases) do
      local lines = percent.source_to_lines(t, src, "#")
      eq(percent.lines_to_source(t, lines, "#"), src)
    end
  end
end

T["lines without the prefix are content"] = function()
  eq(percent.lines_to_source("markdown", { "# a", "typed", "#" }, "#"), "a\ntyped\n")
  eq(percent.lines_to_source("markdown", {}, "#"), "")
end

T["sources containing delimiter text"] = function()
  local lines = percent.source_to_lines("code", "# %%\nx = '# %%'", "#")
  eq(lines, { "# %%", "x = '# %%'" })
  eq(percent.lines_to_source("code", lines, "#"), "# %%\nx = '# %%'")
end

return T
