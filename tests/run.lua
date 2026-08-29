local dir = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/../?.lua;" .. dir .. "/?.lua;" .. package.path

local t = require "support.assert"

local suites = {
  "unit.escape_test",
  "unit.attr_test",
  "unit.schema_test",
  "unit.block_json_test",
  "unit.block_richtext_test",
  "unit.tree_classify_test",
  "unit.tree_nest_test",
  "unit.tree_fix_test",
  "unit.reader_inlines_test",
  "unit.reader_blocks_test",
  "unit.reader_entry_test",
  "unit.writer_inlines_test",
  "unit.writer_blocks_test",
  "roundtrip_test",
  "crossformat_test",
  "pipe_table_test",
  "tab_in_fence_test",
  "colgroup_test",
  "normalization_test",
  "completeness_test",
  "degrade_test",
  "golden_test",
  "unit.batching_test",
}

for _, s in ipairs(suites) do require(s) end

os.exit(t.report())
