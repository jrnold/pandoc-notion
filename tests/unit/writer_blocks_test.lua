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

-- CRITICAL: page/database are BLOCK_TAGS but NOT schema.CONTAINERS --
-- tree.lua's tag_kind only opens a multi-line container for CONTAINERS tags,
-- so the reader only ever builds these as tag_inline. Writing them in
-- container form (<page>\n\t…\n</page>) produces a tag_open the reader can
-- never close, corrupting on the very next read; they must round-trip as one
-- line instead.
t.eq(out({ pandoc.Div({ pandoc.Plain({ pandoc.Str("Title") }) },
                      pandoc.Attr("", { "page" },
                                  { { "url", "u://p" }, { "color", "blue" } })) }),
     '<page url="u://p" color="blue">Title</page>',
     "page tag stays on one line, not container form")
t.eq(out({ pandoc.Div({ pandoc.Plain({ pandoc.Str("DB") }) },
                      pandoc.Attr("", { "database" }, { { "url", "u://d" } })) }),
     '<database url="u://d">DB</database>',
     "database tag stays on one line, not container form")

-- H5/H6 clamp to H4 (per spec); this is a genuine, logged drop of level info.
t.eq(out({ pandoc.Header(5, { pandoc.Str("H") }) }), "#### H", "h5 clamps to h4")
t.eq(out({ pandoc.Header(6, { pandoc.Str("H") }) }), "#### H", "h6 clamps to h4")

-- a class not in NFM's vocabulary: content survives, wrapper is dropped
-- (and logged), not left as an unrecognized Div.
t.eq(out({ pandoc.Div({ pandoc.Para({ pandoc.Str("x") }) },
                      pandoc.Attr("", { "foreign-class" }, {})) }),
     "x", "unknown Div class drops the wrapper, keeps the content")

-- raw HTML: pass through only when the tag is in NFM's closed vocabulary;
-- otherwise it is dropped (logged at INFO), never left as literal text.
t.eq(out({ pandoc.RawBlock("html", "<empty-block/>") }), "<empty-block/>",
     "known-vocabulary RawBlock passes through")
t.eq(out({ pandoc.RawBlock("html", "<div>x</div>") }), "",
     "unknown RawBlock is dropped, not left as literal text")

-- footnotes degrade to an endnote, not raw HTML. The in-text marker and the
-- endnote label must render identically -- exact match, not a substring
-- check, so an escaping mismatch between them (`\[1\]` vs `[1]`) can't hide.
local note = out({ pandoc.Para({ pandoc.Str("x"),
  pandoc.Note({ pandoc.Para({ pandoc.Str("body") }) }) }) })
t.eq(note, "x[1]\n[1] body", "footnote marker is unescaped and matches the endnote label")
