local dir = PANDOC_SCRIPT_FILE:match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. package.path

local blocks = require "notion.writer.blocks"

-- `_opts` is unused: pandoc fixes the signature.
function Writer(doc, _opts)
  return blocks.render_document(doc)
end
