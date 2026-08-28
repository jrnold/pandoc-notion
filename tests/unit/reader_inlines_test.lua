local t = require "support.assert"
local inlines = require "notion.reader.inlines"

local function render(ils)
  return pandoc.write(pandoc.Pandoc({ pandoc.Plain(ils) }), "native")
end
local function has(ils, needle, msg)
  t.truthy(render(ils):find(needle, 1, true) ~= nil, msg)
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
