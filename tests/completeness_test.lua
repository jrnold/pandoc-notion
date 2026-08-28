local t  = require "support.assert"
local wb = require "notion.writer.blocks"
local wi = require "notion.writer.inlines"

-- Pandoc does not expose its constructors as enumerable tables, so this list
-- is explicit and pinned to PANDOC_API_VERSION 1.23.1.2.
local BLOCKS = {
  "BlockQuote", "BulletList", "CodeBlock", "DefinitionList", "Div", "Figure",
  "Header", "HorizontalRule", "LineBlock", "OrderedList", "Para", "Plain",
  "RawBlock", "Table",
}

local INLINES = {
  "Cite", "Code", "Emph", "Image", "LineBreak", "Link", "Math", "Note",
  "Quoted", "RawInline", "SmallCaps", "SoftBreak", "Space", "Span", "Str",
  "Strikeout", "Strong", "Subscript", "Superscript", "Underline",
}

for _, name in ipairs(BLOCKS) do
  t.truthy(wb.handlers[name] ~= nil, "writer handles Block " .. name)
end
for _, name in ipairs(INLINES) do
  t.truthy(wi.handlers[name] ~= nil, "writer handles Inline " .. name)
end

t.eq(#BLOCKS, 14, "block constructor list is complete for this pandoc version")
t.eq(#INLINES, 20, "inline constructor list is complete for this pandoc version")
