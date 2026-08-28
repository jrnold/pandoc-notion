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

-- Returns the mapped text plus whether every character had a mapping. A
-- caller-visible `false` means the styling itself had to be dropped (not
-- merely approximated) for at least one character -- e.g. `x~abc~` has no
-- NFM subscript equivalent for letters -- so callers log it.
local function map_digits(text, table_)
  local out, all_mapped = {}, true
  for c in text:gmatch(".") do
    if table_[c] then out[#out + 1] = table_[c]
    else all_mapped = false; out[#out + 1] = c end
  end
  return table.concat(out), all_mapped
end

-- Read an Attr's key/value list into a ` k="v" …` suffix (no braces): the
-- format tag attributes use, as opposed to attr.render's `{…}` prose suffix.
local function tag_attrs(attributes, fallback_order)
  local a, order = attr.from_attr(attributes)
  if #order == 0 then order = fallback_order or {} end
  return attr.render(a, order):gsub("^ {", ""):gsub("}$", "")
end

-- The tag name a raw HTML fragment opens, closes, or self-closes as -- used
-- only to decide whether it is in NFM's closed vocabulary, per raw_tag in
-- reader/inlines.lua.
local function html_tag_name(text)
  return text:match("^</([%w_%-]+)>%s*$") or text:match("^<([%w_%-]+)[%s/>]")
end

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
      local def = schema.MENTION_TAGS[c]
      if def then
        local body = tag_attrs(el.attributes, def.attrs)
        local inner = render(el.content)
        if inner == "" then return "<" .. c .. " " .. body .. "/>" end
        return "<" .. c .. " " .. body .. ">" .. inner .. "</" .. c .. ">"
      end
    end
  end
  -- plain attribute span, e.g. inline color
  local body = tag_attrs(el.attributes)
  if body == "" then return render(el.content) end
  return "<span " .. body .. ">" .. render(el.content) .. "</span>"
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
  Code       = function(el) return "`" .. el.text .. "`" end,   -- literal, never escaped
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
  Subscript  = function(el)
                 local text, ok = map_digits(render(el.content), SUB)
                 if not ok then
                   pandoc.log.info("Not rendering Subscript (non-digit content has no NFM equivalent)")
                 end
                 return text
               end,
  Superscript= function(el)
                 local text, ok = map_digits(render(el.content), SUP)
                 if not ok then
                   pandoc.log.info("Not rendering Superscript (non-digit content has no NFM equivalent)")
                 end
                 return text
               end,
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
