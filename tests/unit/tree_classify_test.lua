local t = require "support.assert"
local tree = require "notion.reader.tree"

local function kinds(text)
  local out = {}
  for _, n in ipairs(tree.classify(text)) do out[#out + 1] = n.kind end
  return out
end

-- line splitting normalizes line endings
t.eq(tree.lines("a\r\nb\rc\n"), { "a", "b", "c" }, "normalizes CRLF and CR, drops trailing newline")
t.eq(tree.lines("a\n\nb"), { "a", "", "b" }, "keeps interior blank lines")

-- single newline separates blocks: two text lines are two nodes
t.eq(kinds("one\ntwo"), { "text", "text" }, "adjacent lines are separate blocks")

-- indentation is counted in tabs, and stripped from the node text
local n = tree.classify("- parent\n\tchild")
t.eq(n[1].indent, 0, "parent at depth 0")
t.eq(n[2].indent, 1, "child at depth 1")
t.eq(n[2].text, "child", "indent is stripped from text")

-- leading spaces are NOT indentation UNLESS they run to a full tab_stop:
-- pandoc expands tabs to tab_stop spaces before any custom Reader sees the
-- input (unless --preserve-tabs is passed), so a run of exactly tab_stop
-- spaces counts as one indent level, same as a literal tab. Short of that,
-- spaces are still just text.
local sp = tree.classify("  spaced")
t.eq(sp[1].indent, 0, "2 spaces (< default tab_stop 4) do not create depth")
t.eq(sp[1].text, "  spaced", "and are left in the text")

local sp4 = tree.classify("    spaced")
t.eq(sp4[1].indent, 1, "a full tab_stop's worth of spaces (4, the default) is one level")
t.eq(sp4[1].text, "spaced", "and is stripped from the text")

-- mixed leading whitespace resolves left to right, one level at a time
local mixed = tree.classify("\t    Child")
t.eq(mixed[1].indent, 2, "a tab plus a full tab_stop of spaces is two levels")
t.eq(mixed[1].text, "Child", "both levels are stripped from the text")

-- --tab-stop is honored: a different tab_stop changes how many spaces make
-- one level.
local ts8 = tree.classify("        Child", 8)
t.eq(ts8[1].indent, 1, "8 spaces is one level at tab_stop 8")
t.eq(ts8[1].text, "Child", "and is stripped from the text")

local ts8_short = tree.classify("    Child", 8)
t.eq(ts8_short[1].indent, 0, "4 spaces is NOT one level at tab_stop 8")
t.eq(ts8_short[1].text, "    Child", "and stays in the text")

-- fences: content is literal, and NFM syntax inside must not be classified
local fenced = tree.classify("```lua\n<callout icon=\"X\">\n- a\n```")
t.eq(kinds("```lua\n<callout icon=\"X\">\n- a\n```"),
     { "fence_open", "fence_body", "fence_body", "fence_close" },
     "fence body is never interpreted")
t.eq(fenced[1].text, "lua", "fence_open carries the info string")
t.eq(fenced[2].text, '<callout icon="X">', "tag inside a fence stays literal")

-- a tab-indented fence keeps its body verbatim relative to the fence indent
local ind = tree.classify("\t```\n\tcode\n\t```")
t.eq(ind[2].text, "code", "fence body is de-indented by the fence's own depth")

-- tags
t.eq(kinds('<callout icon="X">'), { "tag_open" }, "opening container tag")
t.eq(kinds("</callout>"), { "tag_close" }, "closing tag")
t.eq(kinds("<table_of_contents/>"), { "self_closing" }, "self-closing tag")
t.eq(kinds('<unknown url="u" alt="bookmark"/>'), { "self_closing" }, "unknown block tag")
t.eq(kinds('<page url="u">Title</page>'), { "tag_inline" }, "tag opening and closing on one line")

-- unknown tags are literal text, never tags
t.eq(kinds("<marquee>hi</marquee>"), { "text" }, "tags outside the vocabulary are text")

-- blanks
t.eq(kinds("a\n\nb"), { "text", "blank", "text" }, "blank lines are classified, stripped later")

local nodes = tree.classify('<callout icon="X">')
t.eq(nodes[1].tag, "callout", "tag name is recorded")
