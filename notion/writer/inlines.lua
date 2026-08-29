local escape = require "notion.escape"
local attr   = require "notion.attr"
local schema = require "notion.schema"

local M = {}

-- Unicode sub/superscript digits, the `plain` writer's strategy. NFM's HTML
-- vocabulary is closed, so <sub>/<sup> would reach Notion as literal text.
local SUB = { ["0"]="\226\130\128", ["1"]="\226\130\129", ["2"]="\226\130\130",
              ["3"]="\226\130\131", ["4"]="\226\130\132", ["5"]="\226\130\133",
              ["6"]="\226\130\134", ["7"]="\226\130\135", ["8"]="\226\130\136",
              ["9"]="\226\130\137" }
local SUP = { ["0"]="\226\129\176", ["1"]="\194\185",     ["2"]="\194\178",
              ["3"]="\194\179",     ["4"]="\226\129\180", ["5"]="\226\129\181",
              ["6"]="\226\129\182", ["7"]="\226\129\183", ["8"]="\226\129\184",
              ["9"]="\226\129\185" }

local render     -- forward declaration

-- Map each character through `table_`, leaving anything unmapped as itself.
-- Per spec §8 this is an APPROXIMATION, not a drop -- the spec's own table
-- says "Unicode equivalents where they exist, else literal text" -- so an
-- unmapped character is deliberately NOT logged: `x~abc~` still writes
-- `xabc`, with every character intact.
local function map_digits(text, table_)
  local out = {}
  for c in text:gmatch(".") do out[#out + 1] = table_[c] or c end
  return table.concat(out)
end

-- Read an Attr's key/value list into a ` k="v" …` suffix (leading space, no
-- braces): the format tag attributes use, as opposed to attr.render's `{…}`
-- prose suffix. Shared with writer/blocks.lua -- see attr.tag_attrs.
local function tag_attrs(attributes)
  return attr.tag_attrs(attr.from_attr(attributes))
end

-- The tag name a raw HTML fragment opens, closes, or self-closes as -- used
-- only to decide whether it is in NFM's closed vocabulary, per raw_tag in
-- reader/inlines.lua. Exported because writer/blocks.lua needs the identical
-- test for RawBlock and must not keep a second copy of it.
function M.html_tag_name(text)
  return text:match("^</([%w_%-]+)>%s*$") or text:match("^<([%w_%-]+)[%s/>]")
end
local html_tag_name = M.html_tag_name

local function span(el)
  local classes = {}
  for _, c in ipairs(el.classes) do classes[c] = true end

  if classes.citation then
    return "[^" .. (el.attributes.url or "") .. "]"
  end
  if classes.emoji then
    return ":" .. (el.attributes["data-emoji"] or "") .. ":"
  end
  if classes.mention then
    for _, c in ipairs(el.classes) do
      if schema.MENTION_TAGS[c] then
        local body = tag_attrs(el.attributes)
        local inner = render(el.content)
        if inner == "" then return "<" .. c .. body .. "/>" end
        return "<" .. c .. body .. ">" .. inner .. "</" .. c .. ">"
      end
    end
  end
  -- plain attribute span, e.g. inline color. Any class that got this far is
  -- none NFM knows (the citation/emoji/mention branches above returned
  -- already) and NFM's <span> carries attributes only, so the class has
  -- nowhere to go: a genuine drop, logged per spec Sec 8.
  if #el.classes > 0 then
    pandoc.log.info('Not rendering Span class "' .. el.classes[1]
                    .. '" (NFM <span> carries attributes, not classes)')
  end
  local body = tag_attrs(el.attributes)
  if body == "" then return render(el.content) end
  return "<span" .. body .. ">" .. render(el.content) .. "</span>"
end

local handlers = {
  Str        = function(el) return escape.escape(el.text) end,
  Space      = function() return " " end,
  SoftBreak  = function() return " " end,
  LineBreak  = function() return "<br>" end,
  Strong     = function(el) return "**" .. render(el.content) .. "**" end,
  Emph       = function(el) return "*" .. render(el.content) .. "*" end,
  Strikeout  = function(el) return "~~" .. render(el.content) .. "~~" end,
  Underline  = function(el) return '<span underline="true">' .. render(el.content) .. "</span>" end,
  -- Content is literal, never backslash-escaped -- but a backtick INSIDE it
  -- would close the span early and re-read as something else, so the span is
  -- fenced with a run one longer than the longest run it contains (the
  -- standard markdown remedy), padded with spaces when the content itself
  -- starts or ends with a backtick. Content with no backtick is unaffected:
  -- a one-backtick fence, no padding, exactly as before. Reachable only from
  -- foreign-format input; NFM's own reader never yields such a Code.
  Code       = function(el)
                 local longest = 0
                 for run in el.text:gmatch("`+") do
                   if #run > longest then longest = #run end
                 end
                 if longest == 0 then return "`" .. el.text .. "`" end
                 local fence = string.rep("`", longest + 1)
                 local pad = (el.text:sub(1, 1) == "`" or el.text:sub(-1) == "`") and " " or ""
                 return fence .. pad .. el.text .. pad .. fence
               end,
  Math       = function(el)
                 if el.mathtype == "DisplayMath" then return "$$" .. el.text .. "$$" end
                 return "$" .. el.text .. "$"
               end,
  Link       = function(el) return "[" .. render(el.content) .. "](" .. el.target .. ")" end,
  Image      = function(el) return "![" .. render(el.caption) .. "](" .. el.src .. ")" end,
  Span       = span,
  Quoted     = function(el)
                 local q = el.quotetype == "SingleQuote" and "'" or '"'
                 return q .. render(el.content) .. q
               end,
  -- Byte-wise ASCII :upper() -- non-ASCII letters pass through unchanged
  -- rather than uppercasing, since Lua's stdlib has no Unicode case mapping
  -- and this project takes on no dependency to get one.
  SmallCaps  = function(el) return render(el.content):upper() end,
  Subscript  = function(el) return map_digits(render(el.content), SUB) end,
  Superscript= function(el) return map_digits(render(el.content), SUP) end,
  Cite       = function(el) return render(el.content) end,
  Note       = function() return "" end,   -- handled by the block writer
  RawInline  = function(el)
                 if el.format == "html" then
                   local tag = html_tag_name(el.text)
                   if tag and schema.is_known_tag(tag) then return el.text end
                 end
                 pandoc.log.info("Not rendering RawInline (Format \"" .. el.format .. "\")")
                 return ""
               end,
}

render = function(ils)
  local out = {}
  for _, il in ipairs(ils or {}) do
    local h = handlers[il.t]
    if h then out[#out + 1] = h(il)
    else out[#out + 1] = pandoc.utils.stringify(il) end
  end
  return table.concat(out)
end

M.render = render
M.handlers = handlers
return M
