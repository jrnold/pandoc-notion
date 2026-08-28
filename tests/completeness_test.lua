local t  = require "support.assert"
local wb = require "notion.writer.blocks"
local wi = require "notion.writer.inlines"

-- pandoc.Block and pandoc.Inline themselves yield nothing under pairs(), but
-- their `.constructor` sub-tables do enumerate every constructor pandoc
-- actually has. That gives us two independent checks, both kept:
--   1. The live enumeration is the primary, self-maintaining guard: every
--      constructor pandoc has right now must get a handler, so a future
--      pandoc bump that adds a new construct fails the suite automatically,
--      without anyone having to remember to update a list.
--   2. The pinned list below documents the expected set for this pandoc
--      version (PANDOC_API_VERSION 1.23.1.2) and is asserted equal, in both
--      directions, to the live enumeration -- so a version bump that changes
--      the set is a loud failure naming exactly what changed, rather than a
--      silent expansion (or shrinkage) of coverage nobody notices.
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

-- 1. Primary check: every constructor pandoc actually has must have a
-- handler. Iterates the live `.constructor` tables, not the pinned lists.
for name in pairs(pandoc.Block.constructor) do
  t.truthy(wb.handlers[name] ~= nil, "writer handles Block " .. name)
end
for name in pairs(pandoc.Inline.constructor) do
  t.truthy(wi.handlers[name] ~= nil, "writer handles Inline " .. name)
end

-- 2. The pinned list matches pandoc's live enumeration exactly, in both
-- directions: nothing pinned that pandoc lacks, nothing pandoc has that
-- isn't pinned.
local function assert_matches_pandoc(pinned_list, live_ctors, label)
  local pinned = {}
  for _, name in ipairs(pinned_list) do pinned[name] = true end

  for name in pairs(live_ctors) do
    t.truthy(pinned[name], label .. " constructor list includes " .. name)
  end
  for _, name in ipairs(pinned_list) do
    t.truthy(live_ctors[name] ~= nil, label .. " constructor " .. name .. " still exists in pandoc")
  end
end

assert_matches_pandoc(BLOCKS, pandoc.Block.constructor, "Block")
assert_matches_pandoc(INLINES, pandoc.Inline.constructor, "Inline")

-- 3. Existing per-constructor handler assertions against the pinned list,
-- so a missing handler still fails naming the specific constructor even if
-- the live-enumeration check above were ever removed.
for _, name in ipairs(BLOCKS) do
  t.truthy(wb.handlers[name] ~= nil, "writer handles Block " .. name)
end
for _, name in ipairs(INLINES) do
  t.truthy(wi.handlers[name] ~= nil, "writer handles Inline " .. name)
end

t.eq(#BLOCKS, 14, "block constructor list is complete for this pandoc version")
t.eq(#INLINES, 20, "inline constructor list is complete for this pandoc version")
