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

local attr = require "notion.attr"

-- Collapse fence runs into single `code` nodes and drop blanks.
local function collapse(nodes)
  local out, i = {}, 1
  while i <= #nodes do
    local n = nodes[i]
    if n.kind == "fence_open" then
      local body, j = {}, i + 1
      while j <= #nodes and nodes[j].kind == "fence_body" do
        body[#body + 1] = nodes[j].text
        j = j + 1
      end
      out[#out + 1] = { kind = "code", indent = n.indent, info = n.text,
                        text = table.concat(body, "\n"),
                        attrs = {}, attr_order = {}, children = {} }
      -- skip the closing fence when present; an unterminated fence just ends
      if j <= #nodes and nodes[j].kind == "fence_close" then j = j + 1 end
      i = j
    elseif n.kind == "blank" then
      i = i + 1
    else
      out[#out + 1] = n
      i = i + 1
    end
  end
  return out
end

-- Build the tree. `stack` holds open containers; indentation nests everything
-- else. Returns the roots.
function M.parse(text)
  local nodes = collapse(M.classify(text))
  local roots = {}
  local open = {}          -- open tag containers, innermost last

  local function current_children()
    if #open > 0 then return open[#open].children end
    return roots
  end

  -- Attach `node` by indentation within `list`, descending into the last
  -- sibling chain until the depth matches.
  local function attach(list, node, depth)
    local target, level = list, 0
    while level < depth and #target > 0 do
      target = target[#target].children
      level = level + 1
    end
    target[#target + 1] = node
  end

  local base_depth = {}    -- indent depth at which each open container started

  for _, n in ipairs(nodes) do
    if n.kind == "tag_close" then
      if #open > 0 and open[#open].tag == n.tag then
        table.remove(open)
        table.remove(base_depth)
      else
        -- Unbalanced: recover as literal text.
        attach(current_children(),
               { kind = "text", text = n.text ~= "" and n.text or ("</" .. n.tag .. ">"),
                 attrs = {}, attr_order = {}, children = {} },
               0)
      end
    else
      local text, attrs, order
      if n.kind == "code" then
        text, attrs, order = n.text, {}, {}
      elseif n.kind == "tag_open" or n.kind == "self_closing" or n.kind == "tag_inline" then
        local body = n.text:match("^<[%w_%-]+%s*(.-)%s*/?>") or ""
        attrs, order = attr.parse(body)
        text = n.text
      else
        -- Inside a tag-balanced container, nesting comes from tag balance,
        -- not indentation, so leading spaces there are purely cosmetic
        -- (Notion's own docs space-indent container children).
        local raw = n.text
        if #open > 0 then raw = raw:gsub("^ +", "") end
        text, attrs, order = attr.peel(raw)
      end

      local node = { kind = n.kind, tag = n.tag, info = n.info, text = text,
                     attrs = attrs, attr_order = order, children = {} }

      -- Inside a tag container, indentation is cosmetic: attach directly.
      if #open > 0 then
        local rel = n.indent - base_depth[#base_depth] - 1
        attach(open[#open].children, node, rel > 0 and rel or 0)
      else
        attach(roots, node, n.indent)
      end

      if n.kind == "tag_open" then
        open[#open + 1] = node
        base_depth[#base_depth + 1] = n.indent
      end
    end
  end

  return roots
end

return M
