local t   = require "support.assert"
local nfm = require "support.nfm"

-- <colgroup>/<col> color has no home in pandoc's Table model (ColSpec is
-- just {alignment, width}), so it is genuinely dropped rather than merely
-- degraded -- notion/reader/blocks.lua logs this at INFO per spec Sec 8
-- (log_colgroup_colors). That drop is stable but can never be
-- byte-identical, so tests/corpus/blocks/table-colgroup.nfm is listed in
-- roundtrip_test.lua's KNOWN_NOT_BYTE_IDENTICAL. This test pins the two
-- halves of that known behavior directly: the colgroup is dropped from the
-- rendered output, AND the drop is actually logged rather than silently
-- disappearing.

local path = nfm.ROOT .. "/tests/corpus/blocks/table-colgroup.nfm"
local src  = nfm.read_file(path):gsub("\n$", "")

local out, err = nfm.to_nfm_with_log(src)
out = out:gsub("\n$", "")

t.eq(out, "<table>\n\t<tr>\n\t\t<td>A</td>\n\t\t<td>B</td>\n\t</tr>\n</table>",
  "the colgroup (and its column color) is dropped from the rendered table")

t.truthy(err:find("Not rendering column color", 1, true) ~= nil,
  "the drop is logged at INFO, not silently discarded")
