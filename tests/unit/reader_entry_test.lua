local t = require "support.assert"

-- pandoc expands tabs to opts.tab_stop spaces before ANY custom reader ever
-- sees the input (unless --preserve-tabs is passed), which would otherwise
-- silently defeat NFM's tab-only nesting model. notion-markdown-reader.lua
-- handles this by threading opts.tab_stop through to tree.parse, whose
-- split_indent now accepts a run of exactly tab_stop spaces as equivalent to
-- one literal tab (see tests/unit/tree_classify_test.lua and
-- tree_nest_test.lua for the unit-level coverage of that). These tests
-- exercise the real CLI end to end via pandoc.pipe, because the bug -- and
-- its fix -- only manifest through pandoc's own Reader(input, opts) calling
-- convention, not through tree.parse called directly on a string.

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
-- and not (the original bug's failure mode) a Code span.
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
-- passed: pandoc leaves the literal tab in place, split_indent already
-- treats a literal tab as one level regardless of tab_stop, so the result
-- must match exactly.
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

-- Input with no backing file (stdin) still parses rather than erroring.
do
  local ok, out = run_reader({}, TOGGLE_NFM)
  t.truthy(ok, "stdin input still parses: " .. tostring(out))
  t.truthy(ok and out:find("Header", 1, true) ~= nil,
           "stdin input still produces real pandoc output")
end

-- Code preservation, the critical case: fenced code must NOT be touched by
-- the tab_stop->indent-level conversion, at top level and nested one level
-- inside a container, with and without --preserve-tabs.
local FENCE_TOP = "```python\ndef f():\n    return 1\n```\n"
local FENCE_NESTED = '<callout icon="X">\n\t```python\n\tdef f():\n\t    return 1\n\t```\n</callout>\n'

for _, case in ipairs({
  { name = "top-level fence",         nfm = FENCE_TOP,    preserve = false },
  { name = "top-level fence (-pt)",   nfm = FENCE_TOP,    preserve = true  },
  { name = "callout-nested fence",    nfm = FENCE_NESTED, preserve = false },
  { name = "callout-nested fence (-pt)", nfm = FENCE_NESTED, preserve = true },
}) do
  local path = write_temp(case.nfm)
  local args = case.preserve and { "--preserve-tabs", path } or { path }
  local ok, out = run_reader(args)
  os.remove(path)
  t.truthy(ok, case.name .. " does not error: " .. tostring(out))
  if ok then
    t.truthy(out:find('"def f():\\n    return 1"', 1, true) ~= nil,
             case.name .. ": the 4-space Python body survives byte-for-byte")
  end
end

-- --tab-stop is honored end to end: with --tab-stop=8, 8 spaces is one
-- indent level and 4 spaces is not.
do
  local path = write_temp("Parent\n        Child\n")
  local ok, out = run_reader({ "--tab-stop=8", path })
  os.remove(path)
  t.truthy(ok, "--tab-stop=8 with 8 spaces does not error: " .. tostring(out))
  t.truthy(ok and out:find("Div", 1, true) ~= nil,
           "--tab-stop=8: 8 spaces nests Child, producing a wrapping Div")
  t.truthy(ok and out:find('"Child"', 1, true) ~= nil and out:find("Code (", 1, true) == nil,
           "--tab-stop=8: Child is real nested content (Str), not a Code span")
end

-- At --tab-stop=8, 4 spaces is NOT a full indent level, so Child does not
-- nest under a Div. The previous version of this assertion only checked
-- for the absence of "Div", which also passed while the comment beside it
-- claimed the shape was `Para [ Str "Child" ]` -- it is not. The 4 leftover
-- spaces (< tab_stop, so never consumed as an indent level, and NFM
-- preserves unconsumed leading whitespace as literal text -- see the
-- "leading spaces are NOT indentation" case in tree_classify_test.lua) then
-- reach inlines.read still attached to "Child", and pandoc's own
-- markdown_strict indented-code-block convention turns a 4-space-indented
-- line into a CodeBlock, which blocks_to_inlines flattens to an inline Code
-- span. This can only surface at a non-default --tab-stop: under the
-- default of 4, split_indent always consumes every full run of spaces, so
-- a leftover run this long never happens. Documenting the actual observed
-- shape here rather than the wrong one the old comment implied; whether
-- this quirk is worth closing (it would need a change in inlines.lua,
-- outside this fix's file scope) is a separate, open question -- flagged
-- in the task report rather than fixed here.
do
  local path = write_temp("Parent\n    Child\n")
  local ok, out = run_reader({ "--tab-stop=8", path })
  os.remove(path)
  t.truthy(ok, "--tab-stop=8 with 4 spaces does not error: " .. tostring(out))
  t.truthy(ok and out:find("Div", 1, true) == nil,
           "--tab-stop=8: 4 spaces is NOT one level, so Child does not nest under a Div")
  t.truthy(ok and out:find("Code (", 1, true) ~= nil,
           "--tab-stop=8: the actual shape is a Code span (markdown_strict's own " ..
           "indented-code-block rule), not the plain Str the old comment claimed")
end
