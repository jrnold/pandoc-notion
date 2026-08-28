-- Put this script's own directory on package.path. Pandoc does NOT do this:
-- package.path contains only the system paths and ./?.lua.
local dir = PANDOC_SCRIPT_FILE:match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. package.path

local tree   = require "notion.reader.tree"
local blocks = require "notion.reader.blocks"

function Reader(input, opts)
  return pandoc.Pandoc(blocks.convert(tree.parse(tostring(input))))
end
