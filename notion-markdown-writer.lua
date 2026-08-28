local dir = PANDOC_SCRIPT_FILE:match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. package.path

local blocks = require "notion.writer.blocks"

function Writer(doc, opts)
  return blocks.render_document(doc)
end
