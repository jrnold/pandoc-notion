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

-- Every block from real Notion JSON carries an id, so the reader's class-less
-- carrier Div is the common case. A list item wrapped in one must still be
-- recognised as a to_do, with its marker stripped and its text in rich_text.
local wrapped_todo = writer.convert({ pandoc.BulletList({
  { pandoc.Div(pandoc.Blocks({ pandoc.Plain({
      pandoc.Str("\u{2612}"), pandoc.Space(), pandoc.Str("done") }) }),
      pandoc.Attr("blockid456", {}, {})) } }) })
t.eq(wrapped_todo[1].type, "to_do", "a wrapped item is still a to_do")
t.eq(wrapped_todo[1].to_do.checked, true, "with its checked state")
t.eq(wrapped_todo[1].to_do.rich_text[1].text.content, "done",
     "and its text in rich_text, marker stripped")
t.eq(wrapped_todo[1].to_do.children, nil, "not demoted into a child block")

-- A wrapped item's colour still reaches the payload.
local wrapped_color = writer.convert({ pandoc.BulletList({
  { pandoc.Div(pandoc.Blocks({ pandoc.Plain({ pandoc.Str("x") }) }),
      pandoc.Attr("", {}, { { "color", "red" } })) } }) })
t.eq(wrapped_color[1].bulleted_list_item.color, "red",
     "the carrier Div's colour reaches the item payload")

-- Design doc 4.1: id is omitted by default so output is directly postable.
writer.set_options({ preserve_ids = false })
t.eq(one(pandoc.Para({ pandoc.Str("x") }, pandoc.Attr("abc", {}, {}))).id, nil,
     "id is omitted by default")
writer.set_options({ preserve_ids = true })
t.eq(one(pandoc.Div({}, pandoc.Attr("abc", { "breadcrumb" }, {}))).id, "abc",
     "and emitted under the opt-in")

-- preserve_ids must recover the id from the carrier, not just the colour.
t.eq(writer.convert({ pandoc.Div(pandoc.Blocks({ pandoc.Para({ pandoc.Str("x") }) }),
       pandoc.Attr("para-1", {}, {})) })[1].id, "para-1",
     "preserve_ids recovers a paragraph id from the carrier Div")
t.eq(writer.convert({ pandoc.BulletList({
  { pandoc.Div(pandoc.Blocks({ pandoc.Plain({ pandoc.Str("x") }) }),
      pandoc.Attr("item-1", {}, {})) } }) })[1].id, "item-1",
     "and a list item id")
writer.set_options({ preserve_ids = false })
t.eq(writer.convert({ pandoc.Div(pandoc.Blocks({ pandoc.Para({ pandoc.Str("x") }) }),
       pandoc.Attr("para-1", {}, {})) })[1].id, nil,
     "and still omits it by default")

-- Every array must be a pandoc.List, or Notion rejects it (design doc 2.1).
t.eq(json.encode(writer.convert({})), "[]", "an empty document encodes as []")
t.eq(json.encode(one(pandoc.Para({}))[  "paragraph" ].rich_text), "[]",
     "an empty rich_text encodes as [], not {}")
t.eq(json.encode(one(pandoc.Div({}, pandoc.Attr("", { "breadcrumb" }, {}))).breadcrumb),
     "{}", "an empty payload object encodes as {}")

-- ---- structural and lossy (Task 11) ----
require "notion.block.writer_custom"

-- Degradation is silent at default verbosity, and INFO fires ONLY on a genuine
-- drop (design doc 8). Silence is therefore a requirement, not an absence, and
-- has to be asserted as strictly as the output. pandoc.log.info is a plain
-- function on a table, so it can be counted in-process -- no subprocess and no
-- entry point needed.
local function count_logs(fn)
  local real, n = pandoc.log.info, 0
  pandoc.log.info = function() n = n + 1 end
  local ok, err = pcall(fn)
  pandoc.log.info = real
  if not ok then error(err) end
  return n
end

-- Tables.
local tbl = one(pandoc.Table(
  pandoc.Caption(pandoc.Blocks({})),
  { { pandoc.AlignDefault, nil }, { pandoc.AlignDefault, nil } },
  pandoc.TableHead({ pandoc.Row({
    pandoc.Cell({ pandoc.Plain({ pandoc.Str("Status") }) }),
    pandoc.Cell({ pandoc.Plain({ pandoc.Str("Owner") }) }) }) }),
  { pandoc.TableBody({ pandoc.Row({
    pandoc.Cell({ pandoc.Plain({ pandoc.Str("Doing") }) }),
    pandoc.Cell({ pandoc.Plain({ pandoc.Str("Ada") }) }) }) }, {}, 0) },
  pandoc.TableFoot()))
t.eq(tbl.type, "table", "Table becomes table")
t.eq(tbl.table.table_width, 2, "table_width comes from the colspecs")
t.eq(tbl.table.has_column_header, true, "a populated head sets has_column_header")
t.eq(#tbl.table.children, 2, "head and body rows are all table_row children")
t.eq(tbl.table.children[1].type, "table_row", "rows are table_row blocks")
t.eq(tbl.table.children[1].table_row.cells[1][1].text.content, "Status",
     "cells are arrays of rich text")

-- has_row_header comes from row_head_columns.
local rh = one(pandoc.Table(
  pandoc.Caption(pandoc.Blocks({})), { { pandoc.AlignDefault, nil } },
  pandoc.TableHead({}),
  { pandoc.TableBody({ pandoc.Row({
      pandoc.Cell({ pandoc.Plain({ pandoc.Str("x") }) }) }) }, {}, 1) },
  pandoc.TableFoot()))
t.eq(rh.table.has_row_header, true, "row_head_columns sets has_row_header")
t.eq(rh.table.has_column_header, false, "an empty head means no column header")

-- The table-cell rule's boundary: one block per cell is not a drop, silent.
t.eq(count_logs(function()
       one(pandoc.Table(
         pandoc.Caption(pandoc.Blocks({})), { { pandoc.AlignDefault, nil } },
         pandoc.TableHead({}),
         { pandoc.TableBody({ pandoc.Row({
             pandoc.Cell({ pandoc.Plain({ pandoc.Str("x") }) }) }) }, {}, 0) },
         pandoc.TableFoot()))
     end), 0, "a single-block cell is silent")

-- Figures round-trip back to media blocks.
local fig = one(pandoc.Figure(
  pandoc.Blocks({ pandoc.Plain({ pandoc.Link({ pandoc.Str("Cap") },
                                             "https://e.com/v.mp4") }) }),
  pandoc.Caption(pandoc.Blocks({ pandoc.Plain({ pandoc.Str("Cap") }) })),
  pandoc.Attr("", { "video" }, {})))
t.eq(fig.type, "video", "a classed Figure becomes its media type")
t.eq(fig.video.type, "external", "with an external file object")
t.eq(fig.video.external.url, "https://e.com/v.mp4", "carrying the URL")
t.eq(fig.video.caption[1].text.content, "Cap", "and the caption")

-- A plain Figure with an Image is an image block.
local img = one(pandoc.Figure(
  pandoc.Blocks({ pandoc.Plain({ pandoc.Image({ pandoc.Str("A") }, "https://e.com/i.png") }) }),
  pandoc.Caption(pandoc.Blocks({ pandoc.Plain({ pandoc.Str("A") }) })),
  pandoc.Attr()))
t.eq(img.type, "image", "an unclassed Figure defaults to image")
t.eq(img.image.external.url, "https://e.com/i.png", "from the Image target")

-- LineBlock is genuinely native: one paragraph with newlines.
local lb = one(pandoc.LineBlock({
  { pandoc.Str("one") }, { pandoc.Str("two") } }))
t.eq(lb.type, "paragraph", "LineBlock is one paragraph")
t.eq(lb.paragraph.rich_text[1].text.content, "one\ntwo", "lines joined by newline")

-- DefinitionList: bold term, definition as children.
local dl = one(pandoc.DefinitionList({
  { { pandoc.Str("Term") }, { { pandoc.Plain({ pandoc.Str("Meaning") }) } } } }))
t.eq(dl.type, "paragraph", "the term is a paragraph")
t.eq(dl.paragraph.rich_text[1].annotations.bold, true, "with the term bolded")
t.eq(dl.paragraph.children[1].paragraph.rich_text[1].text.content, "Meaning",
     "and the definition as a child block")

-- SmallCaps uppercases.
t.eq(one(pandoc.Para({ pandoc.SmallCaps({ pandoc.Str("quiet") }) }))
       .paragraph.rich_text[1].text.content, "QUIET", "SmallCaps uppercases")

-- Super/subscript use Unicode where it exists.
t.eq(one(pandoc.Para({ pandoc.Str("x"), pandoc.Superscript({ pandoc.Str("2") }) }))
       .paragraph.rich_text[1].text.content, "x²", "superscript 2 has a Unicode form")
t.eq(one(pandoc.Para({ pandoc.Str("H"), pandoc.Subscript({ pandoc.Str("2") }) }))
       .paragraph.rich_text[1].text.content, "H₂", "subscript 2 does too")
t.eq(one(pandoc.Para({ pandoc.Superscript({ pandoc.Str("qz") }) }))
       .paragraph.rich_text[1].text.content, "qz", "no Unicode form falls back to literal")

-- Footnotes: a marker inline, and the body collected for the entry point to
-- flush as endnote blocks later (Task 12).
-- Note numbering is module-level state on richtext, reset per document by the
-- writer entry point. Reset it here too, or an earlier test's notes would
-- shift this one's numbering.
require("notion.block.richtext").reset_notes()
local noted = writer.convert({
  pandoc.Para({ pandoc.Str("text"),
                pandoc.Note({ pandoc.Para({ pandoc.Str("aside") }) }) }) })
-- The marker merges into the preceding run, because it IS text and adjacent
-- runs with identical annotations coalesce (design doc 4.4). Emitting it as a
-- separate run would only be re-merged on the next read.
t.eq(noted[1].paragraph.rich_text[1].text.content, "text[1]",
     "the marker merges into the preceding run")
-- NOT asserted here: that the note BODY becomes an endnote block. Nothing in
-- this task flushes richtext.notes into blocks -- that is the document entry
-- point's job in Task 12, since only it knows when a document is complete.
-- Task 13's degrade test asserts it end to end, through the real entry point.
-- Collection is all this task is responsible for:
t.eq(#require("notion.block.richtext").notes, 1, "the note body is collected for later")

-- Quoted and Cite pass their content through rather than vanishing.
t.eq(one(pandoc.Para({ pandoc.Quoted("DoubleQuote", { pandoc.Str("q") }) }))
       .paragraph.rich_text[1].text.content, '"q"', "Quoted keeps its quotes")

-- A cell containing blocks is flattened, and that IS a real drop, so it logs.
local nested_cell = one(pandoc.Table(
  pandoc.Caption(pandoc.Blocks({})), { { pandoc.AlignDefault, nil } },
  pandoc.TableHead({}),
  { pandoc.TableBody({ pandoc.Row({ pandoc.Cell({
      pandoc.Para({ pandoc.Str("a") }), pandoc.Para({ pandoc.Str("b") }) }) }) }, {}, 0) },
  pandoc.TableFoot()))
t.eq(nested_cell.table.children[1].table_row.cells[1][1].text.content, "a b",
     "a multi-block cell is flattened to rich text")
t.eq(count_logs(function()
       one(pandoc.Table(
         pandoc.Caption(pandoc.Blocks({})), { { pandoc.AlignDefault, nil } },
         pandoc.TableHead({}),
         { pandoc.TableBody({ pandoc.Row({ pandoc.Cell({
             pandoc.Para({ pandoc.Str("a") }), pandoc.Para({ pandoc.Str("b") }) }) }) }, {}, 0) },
         pandoc.TableFoot()))
     end), 1, "a multi-block cell logs exactly once")

-- Raw content in a foreign format is dropped.
t.eq(#writer.convert({ pandoc.RawBlock("latex", "\\vspace{1cm}") }), 0,
     "a foreign RawBlock is dropped")

-- Silent paths: a deterministic fallback is not a drop.
t.eq(count_logs(function() writer.convert({ pandoc.LineBlock({
       { pandoc.Str("one") }, { pandoc.Str("two") } }) }) end), 0, "LineBlock is silent")
t.eq(count_logs(function() writer.convert({ pandoc.DefinitionList({
       { { pandoc.Str("T") }, { { pandoc.Plain({ pandoc.Str("D") }) } } } }) }) end), 0,
     "DefinitionList is silent")
t.eq(count_logs(function() writer.convert({ pandoc.Para({
       pandoc.SmallCaps({ pandoc.Str("quiet") }) }) }) end), 0, "SmallCaps is silent")
t.eq(count_logs(function() writer.convert({ pandoc.Para({
       pandoc.Superscript({ pandoc.Str("2") }) }) }) end), 0, "Superscript is silent")
t.eq(count_logs(function() writer.convert({ pandoc.Para({
       pandoc.Subscript({ pandoc.Str("2") }) }) }) end), 0, "Subscript is silent")
t.eq(count_logs(function()
       require("notion.block.richtext").reset_notes()
       writer.convert({ pandoc.Para({ pandoc.Str("t"),
         pandoc.Note({ pandoc.Para({ pandoc.Str("n") }) }) }) })
     end), 0, "the footnote marker is silent")

-- Genuine drops: exactly one INFO each.
t.eq(count_logs(function() writer.convert({ pandoc.RawBlock("latex", "\\x") }) end), 1,
     "a foreign RawBlock logs exactly once")

-- Reset shared module state so later suites in the same process (tests/run.lua
-- runs every suite in one Lua process) don't inherit this file's note count.
require("notion.block.richtext").reset_notes()
