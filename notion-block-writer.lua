-- Put this script's own directory on package.path (see the reader entry point).
local dir = PANDOC_SCRIPT_FILE:match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. package.path

local json     = require "notion.block.json"
local richtext = require "notion.block.richtext"
local writer   = require "notion.block.writer"
require "notion.block.writer_custom"

-- Output is a deliberately forgiving superset of the API shape: no limit
-- enforcement, no chunking, no nesting-depth check (design doc 8.2).
function Writer(doc, opts)
  local variables = (opts and opts.variables) or {}
  writer.set_options({ preserve_ids = variables["preserve-ids"] ~= nil })
  richtext.reset_notes()

  local blocks = writer.convert(doc.blocks)

  -- Footnote bodies collected during conversion become endnote blocks at the
  -- end of the document, since Notion has no footnote construct.
  for index, body in ipairs(richtext.notes or {}) do
    local marker = pandoc.Para({ pandoc.Str("[" .. index .. "]") })
    for _, b in ipairs(writer.convert(pandoc.Blocks({ marker }) .. body)) do
      blocks:insert(b)
    end
  end

  return json.encode(blocks)
end
