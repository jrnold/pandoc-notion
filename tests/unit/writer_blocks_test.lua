local t = require "support.assert"
local w = require "notion.writer.blocks"

local function out(blocks) return w.render(pandoc.Blocks(blocks), 0) end

t.eq(out({ pandoc.Para({ pandoc.Str("Hi") }) }), "Hi", "paragraph")

-- blocks are separated by a SINGLE newline, not a blank line
t.eq(out({ pandoc.Para({ pandoc.Str("a") }), pandoc.Para({ pandoc.Str("b") }) }),
     "a\nb", "single newline between blocks")

-- attribute-only Div unwraps back onto its child's attribute suffix
t.eq(out({ pandoc.Div({ pandoc.Para({ pandoc.Str("Hi") }) },
                      pandoc.Attr("", {}, { color = "blue" })) }),
     'Hi {color="blue"}', "attribute Div becomes a suffix")

-- headings
t.eq(out({ pandoc.Header(1, { pandoc.Str("H") }) }), "# H", "h1")
t.eq(out({ pandoc.Header(4, { pandoc.Str("H") }) }), "#### H", "h4")
t.eq(out({ pandoc.Header(2, { pandoc.Str("H") }, pandoc.Attr("", {}, { color = "blue" })) }),
     '## H {color="blue"}', "heading with color")

-- lists and to-dos
t.eq(out({ pandoc.BulletList({ { pandoc.Plain({ pandoc.Str("a") }) },
                               { pandoc.Plain({ pandoc.Str("b") }) } }) }),
     "- a\n- b", "bullet list")
-- F2: "\9744"/"\9746" are Lua compile errors (\ddd caps at \255); use
-- \u{...} escapes for the to-do box characters instead.
t.eq(out({ pandoc.BulletList({ { pandoc.Plain({ pandoc.Str("\u{2610} t") }) } }) }),
     "- [ ] t", "unchecked to-do")
t.eq(out({ pandoc.BulletList({ { pandoc.Plain({ pandoc.Str("\u{2612} t") }) } }) }),
     "- [x] t", "checked to-do")
t.eq(out({ pandoc.OrderedList({ { pandoc.Plain({ pandoc.Str("a") }) } }) }),
     "1. a", "ordered list")

-- children indent with a TAB, never spaces
local nested = out({ pandoc.BulletList({
  { pandoc.Plain({ pandoc.Str("parent") }), pandoc.Para({ pandoc.Str("child") }) } }) })
t.eq(nested, "- parent\n\tchild", "child is tab-indented")
t.truthy(nested:find("    ") == nil, "no space indentation anywhere")

-- code is literal and fenced
t.eq(out({ pandoc.CodeBlock("x = {1}", pandoc.Attr("", { "lua" }, {})) }),
     "```lua\nx = {1}\n```", "code block content is not escaped")

-- structures
t.eq(out({ pandoc.HorizontalRule() }), "---", "divider")
t.eq(out({ pandoc.Para({ pandoc.Math("DisplayMath", "a=b") }) }), "$$a=b$$", "equation")
-- Attributes are given as an ordered array of pairs, not a Lua map: per
-- attr.lua, pandoc.Attr given a plain map emits a different attribute order
-- on every run (Lua table iteration order is unspecified), which made this
-- assertion flaky rather than deterministic.
t.eq(out({ pandoc.Div({ pandoc.Para({ pandoc.Str("Hi") }) },
                      pandoc.Attr("", { "callout" }, { { "icon", "X" }, { "color", "b" } })) }),
     '<callout icon="X" color="b">\n\tHi\n</callout>', "callout with tab-indented child")
t.eq(out({ pandoc.Div({}, pandoc.Attr("", { "empty-block" }, {})) }),
     "<empty-block/>", "empty block")
t.eq(out({ pandoc.Div({}, pandoc.Attr("", { "unknown" }, { { "url", "u" }, { "alt", "bookmark" } })) }),
     '<unknown url="u" alt="bookmark"/>', "unknown block")

-- footnotes degrade to an endnote, not raw HTML
local note = out({ pandoc.Para({ pandoc.Str("x"),
  pandoc.Note({ pandoc.Para({ pandoc.Str("body") }) }) }) })
t.truthy(note:find("[1]", 1, true) ~= nil, "footnote leaves a marker")
t.truthy(note:find("body", 1, true) ~= nil, "and the body appears as an endnote")
