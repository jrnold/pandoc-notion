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

local function map_digits(text, table_)
  local out = {}
  for c in text:gmatch(".") do out[#out + 1] = table_[c] or c end
  return table.concat(out)
end

-- Read an Attr's key/value list into a ` k="v" …` suffix (no braces): the
-- format tag attributes use, as opposed to attr.render's `{…}` prose suffix.
local function tag_attrs(attributes, fallback_order)
  local a, order = attr.from_attr(attributes)
  if #order == 0 then order = fallback_order or {} end
  return attr.render(a, order):gsub("^ {", ""):gsub("}$", "")
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
  SmallCaps  = function(el) return render(el.content):upper() end,
  Subscript  = function(el) return map_digits(render(el.content), SUB) end,
  Superscript= function(el) return map_digits(render(el.content), SUP) end,
  Cite       = function(el) return render(el.content) end,
  Note       = function() return "" end,   -- handled by the block writer
  RawInline  = function(el)
                 if el.format == "html" then return el.text end
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
