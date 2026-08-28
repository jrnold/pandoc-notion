local t = require "support.assert"

-- pandoc expands tabs to opts.tab_stop spaces before ANY custom reader ever
-- sees the input (unless --preserve-tabs is passed), which would otherwise
-- silently defeat NFM's tab-only nesting model. notion-markdown-reader.lua
-- works around this by re-reading each source's raw bytes straight off
-- disk. These tests exercise the real CLI end to end -- via pandoc.pipe --
-- because the bug only manifests through pandoc's own Reader(input, opts)
-- calling convention, not through tree.parse called directly on a string.

local TOGGLE_NFM = '# Toggle {toggle="true"}\n\tChild line\n'

local function write_temp(content)
  local path = os.tmpname()
  local fh = assert(io.open(path, "w"))
  fh:write(content)
  fh:close()
  return path
end

local function run_reader(args, stdin)
  local ok, out = pcall(pandoc.pipe, "pandoc",
    { "-f", "./notion-markdown-reader.lua", "-t", "native", table.unpack(args) },
    stdin or "")
  return ok, out
end

-- A tab-nested file read through the entry point yields real nesting: the
-- child must be a block INSIDE the toggle-heading Div, not a sibling Header
-- and not (the bug's actual failure mode) a Code span.
do
  local path = write_temp(TOGGLE_NFM)
  local ok, out = run_reader({ path })
  os.remove(path)
  t.truthy(ok, "reading a tab-nested file does not error: " .. tostring(out))
  if ok then
    t.truthy(out:find('"toggle-heading"', 1, true) ~= nil,
             "tab-nested child is wrapped in the toggle-heading Div")
    t.truthy(out:find("Code (", 1, true) == nil,
             "tab-nested child is NOT a Code span (the bug's failure mode)")
    t.truthy(out:find('"Child"', 1, true) ~= nil,
             "tab-nested child's text survives as real content")
  end
end

-- The same content through the reader still works when --preserve-tabs IS
-- passed -- no double-handling (e.g. re-reading a file whose tabs were
-- never expanded in the first place must not corrupt them further).
do
  local path = write_temp(TOGGLE_NFM)
  local ok, out = run_reader({ "--preserve-tabs", path })
  os.remove(path)
  t.truthy(ok, "reading with --preserve-tabs does not error: " .. tostring(out))
  if ok then
    t.truthy(out:find('"toggle-heading"', 1, true) ~= nil,
             "--preserve-tabs: child still nests under toggle-heading")
    t.truthy(out:find("Code (", 1, true) == nil,
             "--preserve-tabs: child is still not a Code span")
  end
end

-- A source that is not a readable file (stdin has no path, so `.name` is
-- "") still parses rather than erroring -- it just falls back to whatever
-- text pandoc handed over, tabs expanded or not.
do
  local ok, out = run_reader({}, TOGGLE_NFM)
  t.truthy(ok, "an unreadable-file source (stdin) still parses: " .. tostring(out))
  t.truthy(ok and out:find("Header", 1, true) ~= nil,
           "stdin input still produces real pandoc output")
end
