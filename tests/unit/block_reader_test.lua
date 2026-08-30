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
