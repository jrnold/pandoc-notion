local t = require "support.assert"
local inlines = require "notion.reader.inlines"

local function render(ils)
  return pandoc.write(pandoc.Pandoc({ pandoc.Plain(ils) }), "native")
end
local function has(ils, needle, msg)
  t.truthy(render(ils):find(needle, 1, true) ~= nil, msg)
end
local function has_not(ils, needle, msg)
  t.truthy(render(ils):find(needle, 1, true) == nil, msg)
end

local function types(ils)
  local out = {}
  for _, il in ipairs(ils) do out[#out + 1] = il.t end
  return out
end
local function has_type(ils, ty, msg)
  local found = false
  for _, il in ipairs(ils) do if il.t == ty then found = true end end
  t.truthy(found, msg)
end
local function lacks_type(ils, ty, msg)
  local found = false
  for _, il in ipairs(ils) do if il.t == ty then found = true end end
  t.truthy(not found, msg)
end

-- the pinned extension set must not fabricate constructs NFM lacks
local lit = inlines.read("~sub~ and H~2~O and @citekey")
t.truthy(render(lit):find("Subscript") == nil, "no Subscript fabricated")
t.truthy(render(lit):find("Cite") == nil, "no Cite fabricated")

-- native markdown still works
has(inlines.read("**b** and *i* and `c`"), "Strong", "bold parses")
has(inlines.read("**b** and *i* and `c`"), "Emph", "italic parses")
has(inlines.read("[t](http://x)"), "Link", "links parse")
has(inlines.read("$e=mc^2$"), "Math InlineMath", "inline math parses")
has(inlines.read("~~gone~~"), "Strikeout", "strikeout parses")

-- NFM tags fold into the convention
has(inlines.read('<span underline="true">u</span>'), "Underline",
    "underline becomes the native Underline node")
has(inlines.read('<span color="red">c</span>'), '"color" , "red"',
    "inline color becomes a Span attribute")
has(inlines.read('<mention-user url="u://1">Ada</mention-user>'), '"mention"',
    "mention carries the generic class")
has(inlines.read('<mention-user url="u://1">Ada</mention-user>'), '"mention-user"',
    "mention carries the specific class")
has(inlines.read('<mention-user url="u://1">Ada</mention-user>'), "Ada",
    "mention keeps its label")
has(inlines.read('<mention-date start="2026-01-01"/>'), '"mention-date"',
    "self-closing mention folds")
has(inlines.read("a<br>b"), "LineBreak", "<br> becomes LineBreak")

-- citation is a Span with a url attribute, never a Cite
local cit = inlines.read("[^https://x.com/a]")
has(cit, '"citation"', "citation class applied")
has(cit, "https://x.com/a", "citation url captured")
t.truthy(render(cit):find("Cite") == nil, "citation is not a Cite node")

-- unknown tags survive as literal text rather than disappearing
has(inlines.read("<marquee>hi</marquee>"), "marquee", "unknown tag kept as text")

-- unmatched/unknown tags fold to literal text uniformly -- both ends become
-- Str, never a bare RawInline, so a later NFM-escaping pass treats them the
-- same way (see the writer, which escapes Str but not RawInline verbatim).
has_not(inlines.read("<marquee>hi</marquee>"), "RawInline",
    "unknown tag pair leaves no RawInline node")
has_not(inlines.read("</mention-user>"), "RawInline",
    "stray closing tag becomes literal text, not RawInline")
has_not(inlines.read('<mention-user url="u">Ada'), "RawInline",
    "unbalanced open tag becomes literal text, not RawInline")

-- leading whitespace must not fall into markdown_strict's own indented-code-
-- block rule (4+ leading spaces -> CodeBlock -> flattened to an inline Code
-- span by blocks_to_inlines), which would silently destroy any markup inside.
-- Shape-based, not substring: a prior substring assertion in this suite
-- passed while hiding a wrong shape, so these check node types directly.
local four_sp = inlines.read("    spaced")
t.eq(types(four_sp), { "Str" }, "4-space-indented text is a single Str node")
t.truthy(four_sp[1] and four_sp[1].text == "spaced",
    "4-space-indented text keeps its content, leading spaces trimmed")

local four_sp_bold = inlines.read("    **bold**")
has_type(four_sp_bold, "Strong", "4-space-indented bold still parses as Strong")
lacks_type(four_sp_bold, "Code",
    "4-space-indented bold is NOT swallowed into a Code span")

local two_sp = inlines.read("  spaced")
t.eq(types(two_sp), { "Str" },
    "2-space-indented text is still a single Str node (unchanged behavior)")
t.truthy(two_sp[1] and two_sp[1].text == "spaced",
    "2-space-indented text keeps its content")

t.eq(types(inlines.read("a `code` b")), { "Str", "Space", "Code", "Space", "Str" },
    "a genuine inline code span still parses as Code")
