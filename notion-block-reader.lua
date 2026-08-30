-- Put this script's own directory on package.path. Pandoc does NOT do this:
-- package.path contains only the system paths and ./?.lua. Note this fails
-- through a symlink, since PANDOC_SCRIPT_FILE reports the link path -- invoke
-- by real path.
local dir = PANDOC_SCRIPT_FILE:match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. package.path

local json     = require "notion.block.json"
local envelope = require "notion.block.envelope"
local props    = require "notion.block.props"
local reader   = require "notion.block.reader"
require "notion.block.reader_custom"   -- registers the irregular types

function Reader(input, opts)
  local blocks, page = envelope.unwrap(json.decode_or_diagnose(tostring(input)))
  local doc = pandoc.Pandoc(reader.convert(blocks))
  if page then
    for key, value in pairs(props.to_meta(json.get(page, "properties"))) do
      doc.meta[key] = value
    end
  end
  return doc
end
