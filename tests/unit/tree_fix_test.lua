local t = require "support.assert"
local tree = require "notion.reader.tree"

local function kinds(text)
  local out = {}
  for _, n in ipairs(tree.classify(text)) do out[#out + 1] = n.kind end
  return out
end

-- SPEC: schema.CONTAINERS is now consumed -- only container tags may open a
-- multi-line container. A known non-container tag (e.g. `page`) that is
-- neither self-closing nor inline-closed is recovered as literal text and
-- does not swallow the rest of the document.
local pg = tree.parse('<page url="u">\nafter')
t.eq(#pg, 2, "non-container known tag does not open a container")
t.eq(pg[1].kind, "text", "recovered as literal text")
t.eq(pg[1].text, '<page url="u">', "text preserved verbatim")
t.eq(pg[2].text, "after", "following block is not swallowed")

-- CRITICAL 1: hyphenated tags must not be treated as Lua patterns. Before
-- the fix, "-" is a lazy quantifier, so the inline-close match for
-- "meeting-notes" always failed and the tag swallowed the rest of the doc.
t.eq(kinds("<meeting-notes>x</meeting-notes>\nafter"), { "tag_inline", "text" },
     "hyphenated tag inline-close is detected, not swallowed")
t.eq(kinds('<mention-page url="u">x</mention-page>\nafter'), { "tag_inline", "text" },
     "hyphenated mention tag inline-close is detected, not swallowed")

-- CRITICAL 2: fence de-indent must not blindly drop N characters when a
-- body line has fewer tabs than the fence itself.
local ind2 = tree.classify("- p\n\t```\ncode\n\t```")
t.eq(ind2[3].text, "code", "fence body shorter than the fence's own indent is left untouched, not truncated")

-- IMPORTANT 3: whitespace handling lives in classify, so space-indented
-- tags and fences ARE detected, and nesting for them works.

-- space-indented tag inside a container
local nest = tree.parse('<callout icon="X">\n    <details>\n        inner\n    </details>\n</callout>')
t.eq(#nest, 1, "callout is one root")
t.eq(nest[1].tag, "callout", "outer tag recorded")
t.eq(#nest[1].children, 1, "details nests inside callout despite space indentation")
t.eq(nest[1].children[1].tag, "details", "inner tag recorded")
t.eq(#nest[1].children[1].children, 1, "one grandchild")
t.eq(nest[1].children[1].children[1].text, "inner", "grandchild content")

-- space-indented fence inside a container: the fence is detected, and any
-- indentation beyond the fence's own indent survives as literal text.
local f2 = tree.parse('<callout icon="X">\n    ```python\n        def f():\n            return 1\n    ```\n</callout>')
t.eq(#f2[1].children, 1, "space-indented fence nests as a single child")
t.eq(f2[1].children[1].kind, "code", "kind is code")
t.eq(f2[1].children[1].info, "python", "language captured")
t.eq(f2[1].children[1].text, "    def f():\n        return 1",
     "indentation beyond the fence's own indent survives literally")

-- Notion's own documented table example, space-indented, nests correctly.
local tbl = tree.parse('<table>\n    <tr>\n        <td>Cell</td>\n    </tr>\n</table>')
t.eq(#tbl, 1, "one table root")
t.eq(tbl[1].tag, "table", "table tag recorded")
t.eq(#tbl[1].children, 1, "one row")
t.eq(tbl[1].children[1].tag, "tr", "row tag recorded")
t.eq(#tbl[1].children[1].children, 1, "one cell")
t.eq(tbl[1].children[1].children[1].tag, "td", "cell tag recorded")

-- IMPORTANT 4: a still-open container line whose trailing content happens
-- to end in "/>" (from unrelated embedded content) must not be misread as
-- self-closing -- self-closing is anchored on the opening tag itself.
t.eq(kinds('<callout icon="X">text <table_of_contents/>\nnext'), { "tag_open", "text" },
     "trailing /> from unrelated content does not make the container self-closing")

local mixed = tree.parse('<callout icon="X">text <table_of_contents/>\nnext\n</callout>')
t.eq(#mixed, 1, "callout opens and balances despite the trailing />")
t.eq(mixed[1].tag, "callout", "tag recorded")
t.eq(#mixed[1].children, 1, "one child")
t.eq(mixed[1].children[1].text, "next", "child content")
