local t      = require "support.assert"
local schema = require "notion.schema"
local writer = require "notion.block.writer"
local reader = require "notion.block.reader"
require "notion.block.writer_custom"
require "notion.block.reader_custom"

-- ---- Axis 1: every pandoc constructor is handled by the writer ----
-- pandoc.Block itself is not enumerable, but .constructor is. Enumerating it
-- live is what makes this check self-maintaining across pandoc versions.
for name in pairs(pandoc.Block.constructor) do
  t.truthy(writer.HANDLERS[name] ~= nil,
           "writer handles Block constructor " .. name)
end

-- Inline constructors are handled inside richtext.from_inlines rather than a
-- dispatch table, so assert behaviourally: every one must survive conversion
-- without raising.
local SAMPLE_INLINES = {
  Str = pandoc.Str("x"), Space = pandoc.Space(),
  SoftBreak = pandoc.SoftBreak(), LineBreak = pandoc.LineBreak(),
  Emph = pandoc.Emph({ pandoc.Str("x") }),
  Strong = pandoc.Strong({ pandoc.Str("x") }),
  Underline = pandoc.Underline({ pandoc.Str("x") }),
  Strikeout = pandoc.Strikeout({ pandoc.Str("x") }),
  Superscript = pandoc.Superscript({ pandoc.Str("2") }),
  Subscript = pandoc.Subscript({ pandoc.Str("2") }),
  SmallCaps = pandoc.SmallCaps({ pandoc.Str("x") }),
  Quoted = pandoc.Quoted("DoubleQuote", { pandoc.Str("x") }),
  Cite = pandoc.Cite({ pandoc.Str("x") }, {}),
  Code = pandoc.Code("x"),
  Math = pandoc.Math("InlineMath", "x"),
  RawInline = pandoc.RawInline("latex", "\\x"),
  Link = pandoc.Link({ pandoc.Str("x") }, "https://e.com"),
  Image = pandoc.Image({ pandoc.Str("x") }, "https://e.com/i.png"),
  Note = pandoc.Note({ pandoc.Para({ pandoc.Str("x") }) }),
  Span = pandoc.Span({ pandoc.Str("x") }),
}

local richtext = require "notion.block.richtext"
for name in pairs(pandoc.Inline.constructor) do
  local sample = SAMPLE_INLINES[name]
  t.truthy(sample ~= nil, "the completeness test has a sample for Inline " .. name)
  if sample then
    local ok = pcall(richtext.from_inlines, { sample })
    t.truthy(ok, "richtext.from_inlines handles Inline constructor " .. name)
  end
end

-- ---- Axis 2: every documented Notion type is handled by the reader ----
-- Pinned to the design doc 3.1 list, so a newly documented type fails loudly
-- rather than silently falling through to `unknown`.
local DOCUMENTED_TYPES = {
  "audio", "bookmark", "breadcrumb", "bulleted_list_item", "callout",
  "child_database", "child_page", "code", "column", "column_list", "divider",
  "embed", "equation", "file", "heading_1", "heading_2", "heading_3",
  "heading_4", "image", "link_preview", "meeting_notes", "mention",
  "numbered_list_item", "paragraph", "pdf", "quote", "synced_block", "tab",
  "table", "table_of_contents", "table_row", "template", "to_do", "toggle",
  "transcription", "unsupported", "video",
}

t.eq(#DOCUMENTED_TYPES, 37, "the pinned list is the documented 37")

for _, ntype in ipairs(DOCUMENTED_TYPES) do
  local handled = reader.CUSTOM[ntype] ~= nil or schema.NOTION_INDEX[ntype] ~= nil
  t.truthy(handled, "reader handles Notion type " .. ntype)
end

-- Cross-check both directions, so a type added to one and not the other fails.
local pinned = {}
for _, ntype in ipairs(DOCUMENTED_TYPES) do pinned[ntype] = true end
for ntype in pairs(schema.NOTION_INDEX) do
  t.truthy(pinned[ntype], ntype .. " is in NOTION_INDEX and must be in the pinned list")
end
