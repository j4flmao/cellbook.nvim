local outputs = require("cellbook.model.outputs")
local json = require("cellbook.format.json")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function cell()
  return { outputs = {} }
end

T["stream messages with the same name merge"] = function()
  local c = cell()
  outputs.apply(c, "stream", { name = "stdout", text = "a\n" })
  outputs.apply(c, "stream", { name = "stdout", text = "b\n" })
  outputs.apply(c, "stream", { name = "stderr", text = "err\n" })
  outputs.apply(c, "stream", { name = "stdout", text = "c\n" })
  eq(#c.outputs, 3)
  eq(c.outputs[1].text, "a\nb\n")
  eq(c.outputs[2].name, "stderr")
end

T["carriage returns overwrite the current line"] = function()
  local c = cell()
  outputs.apply(c, "stream", { name = "stdout", text = "start\n 10%" })
  outputs.apply(c, "stream", { name = "stdout", text = "\r 50%" })
  outputs.apply(c, "stream", { name = "stdout", text = "\r100%\ndone\n" })
  eq(c.outputs[1].text, "start\n100%\ndone\n")
  eq(outputs.fix_cr("a\r\nb"), "a\nb")
end

T["clear_output(wait) clears on the next output"] = function()
  local c = cell()
  outputs.apply(c, "stream", { name = "stdout", text = "old" })
  outputs.apply(c, "clear_output", { wait = true })
  eq(#c.outputs, 1)
  outputs.apply(c, "stream", { name = "stdout", text = "new" })
  eq(#c.outputs, 1)
  eq(c.outputs[1].text, "new")
  outputs.apply(c, "clear_output", { wait = false })
  eq(#c.outputs, 0)
end

T["update_display_data replaces by display_id"] = function()
  local c = cell()
  outputs.apply(
    c,
    "display_data",
    { data = { ["text/plain"] = "v1" }, metadata = {}, transient = { display_id = "d1" } }
  )
  local function find(id)
    local r = {}
    for _, o in ipairs(c.outputs) do
      if o.display_id == id then
        r[#r + 1] = o
      end
    end
    return r
  end
  outputs.apply(
    cell(),
    "update_display_data",
    { data = { ["text/plain"] = "v2" }, metadata = {}, transient = { display_id = "d1" } },
    find
  )
  eq(c.outputs[1].data["text/plain"], "v2")
end

T["conversion to nbformat"] = function()
  local s = outputs.to_nbformat({ type = "stream", name = "stdout", text = "a\nb" })
  eq(json.encode(s), '{\n "name": "stdout",\n "output_type": "stream",\n "text": [\n  "a\\n",\n  "b"\n ]\n}')
  local r = outputs.to_nbformat(
    { type = "execute_result", data = { ["text/plain"] = "1\n2", ["image/png"] = "AAA\n" }, metadata = {} },
    7
  )
  eq(r.execution_count, 7)
  eq(r.data["text/plain"], { "1\n", "2" })
  eq(r.data["image/png"], "AAA\n")
  eq(json.is_object(r.metadata), true)
  local e = outputs.to_nbformat({ type = "error", ename = "E", evalue = "v", traceback = {} })
  eq(json.encode(e.traceback), "[]")
  -- transient is never written
  eq(r.transient, nil)
end

T["MIME selection"] = function()
  local prio = { "image/png", "image/jpeg", "image/svg+xml", "text/markdown", "text/plain" }
  eq(outputs.select_mime({ data = { ["text/html"] = "<b>", ["text/plain"] = "t" } }, prio), "text/plain")
  eq(outputs.select_mime({ data = { ["image/png"] = "x", ["text/plain"] = "t" } }, prio), "image/png")
  eq(
    outputs.select_mime({ data = { ["image/svg+xml"] = "x", ["text/plain"] = "t" } }, prio, function()
      return false
    end),
    "text/plain"
  )
  eq(outputs.select_mime({ data = { ["text/html"] = "x" } }, prio), nil)
end

T["png size"] = function()
  local bytes = "\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\2\128\0\0\1\224"
  local w, h = outputs.png_size(bytes)
  eq(w, 640)
  eq(h, 480)
end

return T
