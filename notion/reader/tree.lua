local schema = require "notion.schema"

local M = {}

function M.lines(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n$", "")
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  return out
end

-- Depth is a count of leading indent levels, consumed left to right so mixed
-- leading whitespace works. One level is EITHER a literal tab OR a run of
-- exactly `tab_stop` spaces -- pandoc expands tabs to `tab_stop` spaces
-- before any custom Reader ever sees the input (unless --preserve-tabs is
-- passed), so accepting that many spaces as equivalent to one tab is what
-- keeps tab-nested documents working when read through the normal CLI path.
-- Whatever is left after the last full level (a short run of spaces, or
-- anything else) stays in the line's text -- it is never itself a partial
-- indent level.
local function split_indent(line, tab_stop)
  local depth, i = 0, 1
  local run = string.rep(" ", tab_stop)
  while true do
    if line:sub(i, i) == "\t" then
      depth, i = depth + 1, i + 1
    elseif line:sub(i, i + tab_stop - 1) == run then
      depth, i = depth + 1, i + tab_stop
    else
      break
    end
  end
  return depth, line:sub(i)
end

-- Escape a tag name for safe interpolation into a Lua pattern: '-' is a
-- lazy-quantifier metacharacter in patterns, not a literal, so hyphenated
-- tags (meeting-notes, mention-*) must be escaped before use in a match.
local function pat_escape(tag)
  return (tag:gsub("%-", "%%-"))
end

-- Classify a non-fence line that starts with '<' (leading spaces already
-- skipped by the caller). Returns kind, tag or nil.
local function tag_kind(body)
  local closing = body:match("^</([%w_%-]+)>%s*$")
  if closing then
    if not schema.is_known_tag(closing) then return nil end
    return "tag_close", closing
  end
  local tag = body:match("^<([%w_%-]+)[%s/>]")
  if not tag or not schema.is_known_tag(tag) then return nil end
  local pat = pat_escape(tag)
  -- Inline-close must be checked before the generic self-closing suffix:
  -- a still-open container line can legitimately end in "...trailing/>"
  -- from unrelated content further down the line.
  if body:match("</" .. pat .. ">%s*$") then return "tag_inline", tag end
  -- Anchored on the opening tag itself, so a '/>' that belongs to some
  -- other embedded tag later in the line can't be mistaken for this one
  -- self-closing (requires no '>' between the tag name and the '/>').
  if body:match("^<" .. pat .. "[^>]*/>%s*$") then return "self_closing", tag end
  -- Only tags in schema.CONTAINERS may open a multi-line container; any
  -- other known tag that is neither self-closing nor inline-closed is
  -- malformed here and recovered as literal text.
  if schema.CONTAINERS[tag] then return "tag_open", tag end
  return nil
end

function M.classify(text, tab_stop)
  -- A tab_stop of 0 (or anything non-positive/non-numeric) would make
  -- split_indent's space-run match the empty string, which matches at the
  -- same position forever -- an infinite loop. The CLI can't reach this
  -- (pandoc itself rejects --tab-stop=0), but tree.parse is a public
  -- library entry point other callers -- including our own tests -- can
  -- call directly, so it must not hang on a bad argument.
  tab_stop = (type(tab_stop) == "number" and tab_stop > 0) and tab_stop or 4
  local out, fence = {}, nil
  for _, raw in ipairs(M.lines(text)) do
    if fence then
      -- Literal: strip only the fence's own recorded prefix, and only when
      -- the line actually starts with it; interpret nothing else. Fence
      -- BODIES never go through split_indent/tab_stop conversion -- that is
      -- what "ensure code is preserved" means here. A fence body line like
      -- `    return 1` must keep all four of those spaces verbatim; only the
      -- fence's own recorded prefix (its opening line's literal leading
      -- whitespace) is stripped, exactly as before this change.
      local after = raw
      if raw:sub(1, #fence.prefix) == fence.prefix then
        after = raw:sub(#fence.prefix + 1)
      end
      local close = after:match("^(`+)%s*$")
      if close and #close >= #fence.marker then
        out[#out + 1] = { kind = "fence_close", indent = fence.indent, text = "" }
        fence = nil
      else
        out[#out + 1] = { kind = "fence_body", indent = fence.indent, text = after }
      end
    else
      local depth, body = split_indent(raw, tab_stop)
      -- Fence and tag detection skip leading SPACES too (on top of the tabs
      -- already stripped into `depth`): nesting inside tag-balanced
      -- containers is cosmetic, so a space-indented tag or fence must still
      -- be recognised. Plain text keeps its spaces (handled below).
      local detect = body:gsub("^ +", "")
      local marker, info = detect:match("^(```+)%s*(.-)%s*$")
      if marker then
        fence = { marker = marker, indent = depth, prefix = raw:match("^[ \t]*") }
        out[#out + 1] = { kind = "fence_open", indent = depth, text = info }
      elseif body == "" then
        out[#out + 1] = { kind = "blank", indent = depth, text = "" }
      else
        local kind, tag = tag_kind(detect)
        if kind then
          out[#out + 1] = { kind = kind, tag = tag, indent = depth, text = detect }
        else
          out[#out + 1] = { kind = "text", indent = depth, text = body }
        end
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
      -- The fence's info string is an ordinary attribute-list-bearing line
      -- (```lua {color="blue"} ```), so peel it the same way any other line
      -- is peeled: the language stays in `info`, the attributes move to
      -- attrs/attr_order for blocks.lua's attr_of to pick up.
      local lang, attrs, order = attr.peel(n.text)
      out[#out + 1] = { kind = "code", indent = n.indent, info = lang,
                        text = table.concat(body, "\n"),
                        attrs = attrs, attr_order = order, children = {} }
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
function M.parse(text, tab_stop)
  local nodes = collapse(M.classify(text, tab_stop))
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
      -- Named line_text, not text: `text` is M.parse's own argument (the whole
      -- document), and shadowing it here made the two indistinguishable at a
      -- glance in a function that manipulates both.
      local line_text, attrs, order
      if n.kind == "code" then
        -- collapse() already peeled the fence's info string, carrying the
        -- attributes on the collapsed node itself.
        line_text, attrs, order = n.text, n.attrs, n.attr_order
      elseif n.kind == "tag_open" or n.kind == "self_closing" or n.kind == "tag_inline" then
        local body = n.text:match("^<[%w_%-]+%s*(.-)%s*/?>") or ""
        attrs, order = attr.parse(body)
        line_text = n.text
      else
        -- Inside a tag-balanced container, nesting comes from tag balance,
        -- not indentation, so leading spaces there are purely cosmetic
        -- (Notion's own docs space-indent container children).
        local raw = n.text
        if #open > 0 then raw = raw:gsub("^ +", "") end
        line_text, attrs, order = attr.peel(raw)
      end

      local node = { kind = n.kind, tag = n.tag, info = n.info, text = line_text,
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
