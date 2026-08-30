local t      = require "support.assert"
local json   = require "notion.block.json"
local writer = require "notion.block.writer"

local function one(block) return writer.convert({ block })[1] end
local function text_of(b) return b[b.type].rich_text[1].text.content end

-- Paragraph.
local para = one(pandoc.Para({ pandoc.Str("hi") }))
t.eq(para.object, "block", "every block declares object=block")
t.eq(para.type, "paragraph", "Para becomes paragraph")
t.eq(text_of(para), "hi", "carrying its text")
t.eq(para[para.type].color, "default", "and an explicit default colour")

-- Plain is a paragraph too.
t.eq(one(pandoc.Plain({ pandoc.Str("x") })).type, "paragraph", "Plain becomes paragraph")

-- Headings, including level 4, which the API really has.
for level = 1, 4 do
  t.eq(one(pandoc.Header(level, { pandoc.Str("H") })).type, "heading_" .. level,
       "Header " .. level)
end
-- Levels beyond 4 clamp, matching NFM's h5/h6 -> h4.
t.eq(one(pandoc.Header(5, { pandoc.Str("H") })).type, "heading_4", "H5 clamps to heading_4")
t.eq(one(pandoc.Header(6, { pandoc.Str("H") })).type, "heading_4", "H6 clamps to heading_4")

-- is_toggleable round-trips through the Header's native Attr.
local toggle_h = one(pandoc.Header(2, { pandoc.Str("H") },
                                  pandoc.Attr("", {}, { { "toggle", "true" } })))
t.eq(toggle_h.heading_2.is_toggleable, true, "toggle=true becomes is_toggleable")

-- Quote, divider, code.
t.eq(one(pandoc.BlockQuote({ pandoc.Para({ pandoc.Str("q") }) })).type, "quote", "BlockQuote")
t.eq(one(pandoc.HorizontalRule()).type, "divider", "HorizontalRule")
local code = one(pandoc.CodeBlock("print(1)", pandoc.Attr("", { "python" }, {})))
t.eq(code.type, "code", "CodeBlock")
t.eq(code.code.language, "python", "the class becomes the language")
t.eq(code.code.rich_text[1].text.content, "print(1)", "content is literal")
t.eq(one(pandoc.CodeBlock("x")).code.language, "plain text",
     "a class-less CodeBlock is plain text")

-- Lists.
local bullets = writer.convert({ pandoc.BulletList({
  { pandoc.Plain({ pandoc.Str("a") }) }, { pandoc.Plain({ pandoc.Str("b") }) } }) })
t.eq(#bullets, 2, "a BulletList becomes two sibling blocks")
t.eq(bullets[1].type, "bulleted_list_item", "of type bulleted_list_item")

local ordered = writer.convert({ pandoc.OrderedList({
  { pandoc.Plain({ pandoc.Str("a") }) } },
  pandoc.ListAttributes(5, "Decimal", "Period")) })
t.eq(ordered[1].type, "numbered_list_item", "OrderedList")
t.eq(ordered[1].numbered_list_item.list_start_index, 5, "start becomes list_start_index")

-- The checkbox convention becomes a to_do, with the marker stripped.
local todos = writer.convert({ pandoc.BulletList({
  { pandoc.Plain({ pandoc.Str("\u{2610}"), pandoc.Space(), pandoc.Str("task") }) },
  { pandoc.Plain({ pandoc.Str("\u{2612}"), pandoc.Space(), pandoc.Str("done") }) } }) })
t.eq(todos[1].type, "to_do", "an unchecked marker makes a to_do")
t.eq(todos[1].to_do.checked, false, "unchecked")
t.eq(todos[1].to_do.rich_text[1].text.content, "task", "the marker is stripped from the text")
t.eq(todos[2].to_do.checked, true, "checked")

-- Divs dispatch on class.
local callout = one(pandoc.Div({ pandoc.Para({ pandoc.Str("note") }) },
  pandoc.Attr("", { "callout" }, { { "icon", "💡" }, { "color", "blue_bg" } })))
t.eq(callout.type, "callout", "the callout class")
t.eq(callout.callout.icon.emoji, "💡", "icon becomes an emoji object")
t.eq(callout.callout.color, "blue_background", "_bg becomes _background")
t.eq(callout.callout.rich_text[1].text.content, "note", "leading text becomes rich_text")

t.eq(one(pandoc.Div({}, pandoc.Attr("", { "breadcrumb" }, {}))).type, "breadcrumb",
     "breadcrumb")
t.eq(one(pandoc.Div({}, pandoc.Attr("", { "table-of-contents" }, {}))).type,
     "table_of_contents", "table_of_contents")
t.eq(one(pandoc.Div({}, pandoc.Attr("", { "unknown" }, { { "alt", "widget" } }))).type,
     "unsupported", "unknown maps back to unsupported")

-- Reuse: the page/database classes map back to child_page/child_database.
t.eq(one(pandoc.Div({}, pandoc.Attr("", { "page" }, { { "title", "Sub" } }))).type,
     "child_page", "the page class becomes child_page")
t.eq(one(pandoc.Div({}, pandoc.Attr("", { "meeting-notes" }, {}))).type, "meeting_notes",
     "meeting-notes becomes meeting_notes, not transcription")

-- Synced blocks: two classes, one type, distinguished by synced_from.
t.eq(one(pandoc.Div({}, pandoc.Attr("", { "synced-block" }, {}))).synced_block.synced_from,
     pandoc.json.null, "an original has a null synced_from")
local ref = one(pandoc.Div({}, pandoc.Attr("", { "synced-block-reference" },
                                           { { "url", "b-1" } })))
t.eq(ref.synced_block.synced_from.block_id, "b-1", "a reference names its source")

-- A class-less attribute-only Div is the colour wrapper: unwrap it.
local wrapped = one(pandoc.Div({ pandoc.Para({ pandoc.Str("hi") }) },
                               pandoc.Attr("", {}, { { "color", "red" } })))
t.eq(wrapped.type, "paragraph", "the wrapper does not survive as a block")
t.eq(wrapped.paragraph.color, "red", "its colour lands on the block inside")

-- An unrecognized class is unwrapped, its children kept (design doc 8).
local mystery = writer.convert({ pandoc.Div({ pandoc.Para({ pandoc.Str("kept") }) },
                                            pandoc.Attr("", { "mystery" }, {})) })
t.eq(#mystery, 1, "an unknown class yields its children")
t.eq(mystery[1].type, "paragraph", "unwrapped, not dropped")

-- Nested children go inside the type payload (design doc 3.4).
local nested = one(pandoc.Div({ pandoc.Para({ pandoc.Str("head") }),
                                pandoc.Para({ pandoc.Str("kid") }) },
                              pandoc.Attr("", { "callout" }, {})))
t.eq(#nested.callout.children, 1, "the trailing block becomes a child")
t.eq(nested.callout.children[1].type, "paragraph", "converted normally")

-- Design doc 4.1: id is omitted by default so output is directly postable.
writer.set_options({ preserve_ids = false })
t.eq(one(pandoc.Para({ pandoc.Str("x") }, pandoc.Attr("abc", {}, {}))).id, nil,
     "id is omitted by default")
writer.set_options({ preserve_ids = true })
t.eq(one(pandoc.Div({}, pandoc.Attr("abc", { "breadcrumb" }, {}))).id, "abc",
     "and emitted under the opt-in")
writer.set_options({ preserve_ids = false })

-- Every array must be a pandoc.List, or Notion rejects it (design doc 2.1).
t.eq(json.encode(writer.convert({})), "[]", "an empty document encodes as []")
t.eq(json.encode(one(pandoc.Para({}))[  "paragraph" ].rich_text), "[]",
     "an empty rich_text encodes as [], not {}")
t.eq(json.encode(one(pandoc.Div({}, pandoc.Attr("", { "breadcrumb" }, {}))).breadcrumb),
     "{}", "an empty payload object encodes as {}")
