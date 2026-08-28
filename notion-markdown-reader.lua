-- Put this script's own directory on package.path. Pandoc does NOT do this:
-- package.path contains only the system paths and ./?.lua.
local dir = PANDOC_SCRIPT_FILE:match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. package.path

local tree   = require "notion.reader.tree"
local blocks = require "notion.reader.blocks"

-- pandoc expands tabs to opts.tab_stop spaces before any custom Reader ever
-- sees the input, unless --preserve-tabs is passed. Rather than fight that
-- (re-reading source files from disk, tried previously), tree.lua's
-- split_indent now accepts a run of exactly tab_stop spaces as equivalent to
-- one literal tab, so the expanded text nests exactly like the original
-- tab-indented document would have. opts.tab_stop is threaded straight
-- through to tree.parse.
function Reader(input, opts)
  return pandoc.Pandoc(blocks.convert(tree.parse(tostring(input), opts.tab_stop)))
end
