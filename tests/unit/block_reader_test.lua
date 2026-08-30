local t      = require "support.assert"
local reader = require "notion.block.reader"

local function run(s) return { type = "text", text = { content = s },
                               annotations = {}, plain_text = s } end
local function native(blocks)
  return pandoc.write(pandoc.Pandoc(blocks), "native")
end

-- Paragraph: the plainest path.
t.eq(native(reader.convert({
       { object = "block", type = "paragraph",
         paragraph = { rich_text = { run("hi") }, color = "default" } } })),
     native({ pandoc.Para({ pandoc.Str("hi") }) }),
     "an uncoloured paragraph is a bare Para")

-- Design doc 4.2: attributes wrap only when the node has nowhere native to put
-- them. An ordinary paragraph must stay ordinary.
local colored = reader.convert({
  { type = "paragraph", paragraph = { rich_text = { run("hi") }, color = "blue_background" } } })
t.eq(colored[1].t, "Div", "a coloured paragraph gains a wrapper Div")
t.eq(colored[1].attributes.color, "blue_bg", "and the colour is translated")
t.eq(colored[1].classes, pandoc.List({}), "the wrapper is class-less")

-- Design doc 4.1: the id lands in the Attr identifier slot; other server
-- metadata is dropped.
local with_id = reader.convert({
  { type = "callout", id = "c02fc1d3-db8b-45c5-a222-27595b15aea7",
    created_time = "2026-08-01T00:00:00Z",
    last_edited_by = { object = "user", id = "u-1" },
    callout = { rich_text = { run("note") }, icon = { type = "emoji", emoji = "💡" },
                color = "blue" } } })
t.eq(with_id[1].identifier, "c02fc1d3-db8b-45c5-a222-27595b15aea7", "id is preserved")
t.eq(with_id[1].classes, pandoc.List({ "callout" }), "callout class")
t.eq(with_id[1].attributes.icon, "💡", "emoji icon is flattened to its character")
t.eq(with_id[1].attributes.color, "blue", "colour is carried")
t.eq(with_id[1].attributes.created_time, nil, "server metadata is dropped")

-- Quote and divider.
t.eq(native(reader.convert({ { type = "quote", quote = { rich_text = { run("q") } } } })),
     native({ pandoc.BlockQuote({ pandoc.Para({ pandoc.Str("q") }) }) }), "quote")
t.eq(native(reader.convert({ { type = "divider", divider = {} } })),
     native({ pandoc.HorizontalRule() }), "divider")

-- Block equation is display math.
t.eq(native(reader.convert({
       { type = "equation", equation = { expression = "e=mc^2" } } })),
     native({ pandoc.Para({ pandoc.Math("DisplayMath", "e=mc^2") }) }), "block equation")

-- Children are followed from the type payload...
local nested = reader.convert({
  { type = "callout", has_children = true,
    callout = { rich_text = { run("outer") },
                children = { { type = "paragraph",
                               paragraph = { rich_text = { run("inner") } } } } } } })
t.eq(#nested[1].content, 2, "callout holds its own text plus one child block")
t.eq(pandoc.utils.stringify(nested[1].content[2]), "inner", "the child is converted")

-- ...and from the top level, since Notion's own docs disagree about placement.
local top = reader.convert({
  { type = "callout", has_children = true,
    callout = { rich_text = { run("outer") } },
    children = { { type = "paragraph", paragraph = { rich_text = { run("inner") } } } } } })
t.eq(#top[1].content, 2, "top-level children are followed too")

-- Design doc 6.4: an unknown type degrades visibly instead of crashing.
local unknown = reader.convert({ { type = "some_future_type", some_future_type = {} } })
t.eq(unknown[1].classes, pandoc.List({ "unknown" }), "unknown type gets the unknown class")
t.eq(unknown[1].attributes.alt, "some_future_type", "and names the type it was")

-- Notion's own "unsupported" type maps to the same class.
local unsupported = reader.convert({
  { type = "unsupported", unsupported = { block_type = "mystery" } } })
t.eq(unsupported[1].classes, pandoc.List({ "unknown" }), "unsupported is unknown")

-- Design doc 6.5: recovery, never fatal.
t.eq(#reader.convert({ { object = "block", id = "x" } }), 0,
     "a block with no type is skipped")
t.eq(#reader.convert({ { type = "paragraph" } }), 1,
     "a missing payload still yields an (empty) block")
t.eq(#reader.convert({}), 0, "an empty array yields no blocks")

-- Design doc 6.3: unhydrated input is emitted with an empty body, not an error.
local unhydrated = reader.convert({
  { type = "callout", has_children = true, id = "u-1",
    callout = { rich_text = { run("outer") } } } })
t.eq(#unhydrated[1].content, 1, "an unhydrated container keeps only its own content")

-- Reuse: these three fold onto classes the NFM pair already defines.
t.eq(reader.convert({ { type = "child_page", id = "p-1",
                        child_page = { title = "Sub" } } })[1].classes,
     pandoc.List({ "page" }), "child_page reuses the page class")
t.eq(reader.convert({ { type = "transcription", transcription = {} } })[1].classes,
     pandoc.List({ "meeting-notes" }), "transcription reuses meeting-notes")

-- A custom-flagged type with no registered handler degrades visibly, not into
-- a generic Div that would silently swallow its content.
local unregistered = reader.convert({ { type = "code",
  code = { rich_text = { run("print(1)") }, language = "python" } } })
t.eq(unregistered[1].classes, pandoc.List({ "unknown" }),
     "a custom type with no handler becomes unknown, not a generic Div")
t.eq(unregistered[1].attributes.alt, "code", "and names the type it was")

-- design doc 4.1 applies to every block type, including those whose pandoc
-- node has no Attr slot of its own.
local id_divider = reader.convert({ { type = "divider", id = "d-1", divider = {} } })
t.eq(id_divider[1].t, "Div", "a divider with an id wraps to carry it")
t.eq(id_divider[1].identifier, "d-1", "preserving the id")
t.eq(id_divider[1].content[1].t, "HorizontalRule", "around the rule itself")
t.eq(reader.convert({ { type = "divider", divider = {} } })[1].t, "HorizontalRule",
     "an id-less divider stays a bare HorizontalRule")

-- The six JSON-only classes.
t.eq(reader.convert({ { type = "bookmark",
                        bookmark = { url = "https://e.com", caption = {} } } })[1].attributes.url,
     "https://e.com", "bookmark carries its url")
t.eq(reader.convert({ { type = "breadcrumb", breadcrumb = {} } })[1].classes,
     pandoc.List({ "breadcrumb" }), "breadcrumb")

-- Bug 3: bookmark's inline content lives under "caption", not "rich_text" --
-- rich_text_key must redirect the generic reader path to read it.
local bookmarked = reader.convert({ { type = "bookmark",
  bookmark = { url = "https://e.com", caption = { run("A bookmark caption") } } } })
t.eq(pandoc.utils.stringify(bookmarked[1]), "A bookmark caption",
     "the caption becomes the bookmark Div's content, not dropped")

-- ---- irregular types (Task 8) ----
require "notion.block.reader_custom"

-- Headings, including heading_4, which the API really does have.
for level = 1, 4 do
  local h = reader.convert({ { type = "heading_" .. level,
    ["heading_" .. level] = { rich_text = { run("H") } } } })
  t.eq(h[1].t, "Header", "heading_" .. level .. " is a Header")
  t.eq(h[1].level, level, "heading_" .. level .. " keeps its level")
end

-- A toggle heading with no children needs no wrapper: the flag has a native
-- home on the Header's own Attr.
local toggle_h = reader.convert({ { type = "heading_2",
  heading_2 = { rich_text = { run("H") }, is_toggleable = true } } })
t.eq(toggle_h[1].t, "Header", "a childless toggle heading stays a Header")
t.eq(toggle_h[1].attributes.toggle, "true", "and carries toggle=true")

-- With children it needs the wrapper, since a Header cannot contain blocks.
local toggle_kids = reader.convert({ { type = "heading_2", has_children = true,
  heading_2 = { rich_text = { run("H") }, is_toggleable = true,
                children = { { type = "paragraph", paragraph = { rich_text = { run("k") } } } } } } })
t.eq(toggle_kids[1].classes, pandoc.List({ "toggle-heading" }), "wrapped in toggle-heading")
t.eq(toggle_kids[1].content[1].t, "Header", "the Header is the first child")

-- Consecutive list items group into ONE list.
local bullets = reader.convert({
  { type = "bulleted_list_item", bulleted_list_item = { rich_text = { run("a") } } },
  { type = "bulleted_list_item", bulleted_list_item = { rich_text = { run("b") } } } })
t.eq(#bullets, 1, "two adjacent bullets make one list")
t.eq(bullets[1].t, "BulletList", "of type BulletList")
t.eq(#bullets[1].content, 2, "with two items")

local numbers = reader.convert({
  { type = "numbered_list_item", numbered_list_item = { rich_text = { run("a") } } },
  { type = "numbered_list_item", numbered_list_item = { rich_text = { run("b") } } } })
t.eq(numbers[1].t, "OrderedList", "numbered items make an OrderedList")

-- A non-list block breaks the run.
local split = reader.convert({
  { type = "bulleted_list_item", bulleted_list_item = { rich_text = { run("a") } } },
  { type = "divider", divider = {} },
  { type = "bulleted_list_item", bulleted_list_item = { rich_text = { run("b") } } } })
t.eq(#split, 3, "a divider splits the run into two lists")

-- list_start_index becomes the OrderedList start.
local started = reader.convert({ { type = "numbered_list_item",
  numbered_list_item = { rich_text = { run("a") }, list_start_index = 5 } } })
t.eq(started[1].listAttributes.start, 5, "list_start_index becomes start")

-- to_do uses the checkbox convention pandoc's task_lists extension defines.
local todo = reader.convert({
  { type = "to_do", to_do = { rich_text = { run("task") }, checked = false } },
  { type = "to_do", to_do = { rich_text = { run("done") }, checked = true } } })
t.eq(todo[1].t, "BulletList", "to_do items are bullets")
t.eq(pandoc.utils.stringify(todo[1].content[1]):sub(1, 3), "\u{2610}", "unchecked is U+2610")
t.eq(pandoc.utils.stringify(todo[1].content[2]):sub(1, 3), "\u{2612}", "checked is U+2612")

-- Code.
local code = reader.convert({ { type = "code",
  code = { rich_text = { run("print(1)") }, language = "python", caption = {} } } })
t.eq(code[1].t, "CodeBlock", "code becomes a CodeBlock")
t.eq(code[1].text, "print(1)", "content is literal")
t.eq(code[1].classes, pandoc.List({ "python" }), "language becomes the class")

-- Code content is literal: newlines and indentation must survive intact.
-- stringify() collapses LineBreak to a space, so a multi-line fixture is the
-- only thing that catches a regression here.
local multiline = reader.convert({ { type = "code", code = {
  rich_text = { run("def f():\n    return 1\n") },
  language = "python", caption = {} } } })
t.eq(multiline[1].text, "def f():\n    return 1\n",
     "multi-line code keeps its newlines and indentation")

-- Columns.
local cols = reader.convert({ { type = "column_list", has_children = true,
  column_list = { children = {
    { type = "column", column = { children = {
        { type = "paragraph", paragraph = { rich_text = { run("L") } } } } } },
    { type = "column", column = { width_ratio = 0.5, children = {
        { type = "paragraph", paragraph = { rich_text = { run("R") } } } } } } } } } })
t.eq(cols[1].classes, pandoc.List({ "columns" }), "column_list is the columns Div")
t.eq(cols[1].content[1].classes, pandoc.List({ "column" }), "each child is a column")
t.eq(cols[1].content[2].attributes["width-ratio"], "0.5", "width_ratio is carried")

-- Media: the URL goes on the inner Link, matching the NFM golden exactly.
local vid = reader.convert({ { type = "video",
  video = { type = "external", external = { url = "https://e.com/v.mp4" },
            caption = { run("Video caption") } } } })
t.eq(vid[1].t, "Figure", "video is a Figure")
t.eq(vid[1].classes, pandoc.List({ "video" }), "with its type class")
t.eq(pandoc.utils.stringify(vid[1].caption), "Video caption", "caption is populated")
local link = vid[1].content[1].content[1]
t.eq(link.t, "Link", "the body is a Link")
t.eq(link.target, "https://e.com/v.mp4", "carrying the URL")
t.eq(vid[1].attributes.src, nil, "src is NOT duplicated onto the Figure")

-- A Notion-hosted file uses .file.url; expiry_time is dropped.
local hosted = reader.convert({ { type = "image",
  image = { type = "file", file = { url = "https://s3/i.png",
                                    expiry_time = "2026-08-29T00:00:00Z" },
            caption = {} } } })
t.eq(hosted[1].content[1].content[1].target, "https://s3/i.png", "file.url is used")
t.eq(hosted[1].attributes.expiry_time, nil, "expiry_time is dropped")

-- A file_upload has no URL at all.
local upload = reader.convert({ { type = "pdf",
  pdf = { type = "file_upload", file_upload = { id = "up-1" }, caption = {} } } })
t.eq(upload[1].attributes["data-file-upload-id"], "up-1", "the upload id is kept")

-- Tables.
local tbl = reader.convert({ { type = "table", has_children = true,
  table = { table_width = 2, has_column_header = true, has_row_header = false,
    children = {
      { type = "table_row", table_row = { cells = { { run("Status") }, { run("Owner") } } } },
      { type = "table_row", table_row = { cells = { { run("In progress") }, { run("Ada") } } } } } } } })
t.eq(tbl[1].t, "Table", "table becomes a Table")
t.eq(#tbl[1].colspecs, 2, "table_width becomes the colspec count")
t.eq(#tbl[1].head.rows, 1, "has_column_header moves the first row into the head")
t.eq(#tbl[1].bodies[1].body, 1, "leaving one row in the body")

local tbl_norow = reader.convert({ { type = "table", has_children = true,
  table = { table_width = 1, has_column_header = false, has_row_header = true,
    children = { { type = "table_row", table_row = { cells = { { run("x") } } } } } } } })
t.eq(#tbl_norow[1].head.rows, 0, "without has_column_header the head is empty")
t.eq(tbl_norow[1].bodies[1].row_head_columns, 1, "has_row_header sets row_head_columns")

-- Synced blocks: one Notion type, two AST classes, decided by synced_from.
local original = reader.convert({ { type = "synced_block",
  synced_block = { synced_from = pandoc.json.null, children = {} } } })
t.eq(original[1].classes, pandoc.List({ "synced-block" }), "null synced_from is the original")
local reference = reader.convert({ { type = "synced_block",
  synced_block = { synced_from = { type = "block_id", block_id = "b-1" }, children = {} } } })
t.eq(reference[1].classes, pandoc.List({ "synced-block-reference" }), "a set synced_from is a reference")
t.eq(reference[1].attributes.url, "b-1", "carrying the source block id")

-- A block-level mention.
local bm = reader.convert({ { type = "mention",
  mention = { type = "page", page = { id = "p-9" } } } })
t.eq(bm[1].t, "Para", "a mention block is a Para")
t.eq(bm[1].content[1].classes, pandoc.List({ "mention", "mention-page" }), "holding a mention Span")
