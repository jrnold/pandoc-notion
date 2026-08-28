local schema = require "notion.schema"

local M = {}

function M.lines(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n$", "")
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  return out
end

-- Depth is a count of leading TABS only. Spaces are never indentation.
local function split_indent(line)
  local tabs = line:match("^\t*")
  return #tabs, line:sub(#tabs + 1)
end

-- Classify a non-fence line that starts with '<'. Returns kind, tag or nil.
local function tag_kind(body)
  local closing = body:match("^</([%w_%-]+)>%s*$")
  if closing then
    if not schema.is_known_tag(closing) then return nil end
    return "tag_close", closing
  end
  local tag = body:match("^<([%w_%-]+)[%s/>]")
  if not tag or not schema.is_known_tag(tag) then return nil end
  if body:match("/>%s*$") then return "self_closing", tag end
  if body:match("</" .. tag .. ">%s*$") then return "tag_inline", tag end
  return "tag_open", tag
end

function M.classify(text)
  local out, fence = {}, nil
  for _, raw in ipairs(M.lines(text)) do
    local depth, body = split_indent(raw)
    if fence then
      local close = body:match("^(`+)%s*$")
      if close and #close >= #fence.marker then
        out[#out + 1] = { kind = "fence_close", indent = fence.indent, text = "" }
        fence = nil
      else
        -- Literal: strip only the fence's own indentation, interpret nothing.
        out[#out + 1] = { kind = "fence_body", indent = fence.indent,
                          text = raw:sub(fence.indent + 1) }
      end
    else
      local marker, info = body:match("^(```+)%s*(.-)%s*$")
      if marker then
        fence = { marker = marker, indent = depth }
        out[#out + 1] = { kind = "fence_open", indent = depth, text = info }
      elseif body == "" then
        out[#out + 1] = { kind = "blank", indent = depth, text = "" }
      else
        local kind, tag = tag_kind(body)
        out[#out + 1] = { kind = kind or "text", tag = tag,
                          indent = depth, text = body }
      end
    end
  end
  return out
end

return M
