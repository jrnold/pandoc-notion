local dir = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/../?.lua;" .. dir .. "/?.lua;" .. package.path

local t = require "support.assert"

local suites = {
  "unit.escape_test",
  "unit.attr_test",
  "unit.schema_test",
  "unit.tree_classify_test",
  "unit.tree_nest_test",
  "unit.tree_fix_test",
  "unit.reader_inlines_test",
  "unit.reader_blocks_test",
  "unit.reader_entry_test",
  "unit.writer_inlines_test",
  "unit.writer_blocks_test",
  "roundtrip_test",
  "tab_in_fence_test",
}

for _, s in ipairs(suites) do require(s) end

os.exit(t.report())
