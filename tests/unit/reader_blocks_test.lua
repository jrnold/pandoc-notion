local t = require "support.assert"
local tree   = require "notion.reader.tree"
local blocks = require "notion.reader.blocks"

-- A wide columns setting keeps the native writer's pretty-printer from
-- wrapping constructors like `Header 1 ( ... )` onto their own line, which
-- would otherwise split the very substrings these assertions search for.
local WIDE = pandoc.WriterOptions({ columns = 1000 })

local function native(nfm)
  return pandoc.write(pandoc.Pandoc(blocks.convert(tree.parse(nfm))), "native", WIDE)
end
local function has(nfm, needle, msg)
  t.truthy(native(nfm):find(needle, 1, true) ~= nil, msg)
end

-- paragraphs and the attribute-gap rule
has("Hello", "Para", "plain text becomes Para")
t.truthy(native("Hello"):find("Div") == nil, "unattributed Para is NOT wrapped")
has('Hello {color="blue"}', "Div", "attributed Para IS wrapped")
has('Hello {color="blue"}', '"color" , "blue"', "wrapper carries the color")

-- headings use native Attr, no wrapper
has('# H {color="blue"}', "Header 1", "heading level")
t.truthy(native('# H {color="blue"}'):find("Div") == nil, "heading needs no wrapper")
has('# H {toggle="true"}', '"toggle" , "true"', "toggle attr rides on the Header")

-- h5/h6 collapse to h4
has("##### Five", "Header 4", "h5 collapses to h4")
has("###### Six", "Header 4", "h6 collapses to h4")

-- lists
has("- a\n- b", "BulletList", "bullets group into one list")
t.eq(select(2, native("- a\n- b"):gsub("BulletList", "")), 1, "exactly one BulletList")
has("1. a\n2. b", "OrderedList", "ordered list")
has("- [ ] todo", "\\9744", "unchecked box uses U+2610")
has("- [x] done", "\\9746", "checked box uses U+2612")

-- quote, divider, code, equation
has("> quoted", "BlockQuote", "quote")
has("---", "HorizontalRule", "divider")
has("```lua\nx = 1\n```", "CodeBlock", "code block")
has("```lua\nx = 1\n```", '"lua"', "code language becomes a class")
has("$$a=b$$", "Math DisplayMath", "display equation")

-- containers
has('<callout icon="X" color="blue_bg">\n\tHi\n</callout>', '"callout"', "callout class")
has('<callout icon="X" color="blue_bg">\n\tHi\n</callout>', '"icon" , "X"', "callout icon")
has("<columns>\n<column>\nL\n</column>\n</columns>", '"columns"', "columns class")
has("<columns>\n<column>\nL\n</column>\n</columns>", '"column"', "column class")

-- the two tags real pages contain but the enhanced-markdown spec omits
has('<unknown url="u" alt="bookmark"/>', '"unknown"', "unknown block")
has('<unknown url="u" alt="bookmark"/>', '"alt" , "bookmark"', "unknown alt attribute")

-- toggle vs toggle-heading stay distinct
has("<details>\n<summary>T</summary>\nBody\n</details>", '"toggle"', "details is toggle")
has('# H {toggle="true"}\n\tChild', '"toggle-heading"', "toggle heading with children")

-- single-newline block separation
t.eq(select(2, native("one\ntwo"):gsub("Para", "")), 2,
     "two adjacent lines are two Paras, not one")

-- tables (ruling F1: the brief's block_for has no <table> branch; a table
-- node must become a native Table/Row/Cell, never a mangled paragraph/Div)
local TABLE_2X2 = '<table>\n' ..
  '\t<tr>\n\t\t<td>A1</td>\n\t\t<td>A2</td>\n\t</tr>\n' ..
  '\t<tr>\n\t\t<td>B1</td>\n\t\t<td>B2</td>\n\t</tr>\n' ..
  '</table>'
has(TABLE_2X2, "[ Table ", "table becomes a native Table")
t.truthy(native(TABLE_2X2):find("Div") == nil, "table is not a Div")
t.eq(select(2, native(TABLE_2X2):gsub("AlignDefault , ColWidthDefault", "")), 2,
     "2x2 table has 2 columns")

local TABLE_HEADER = '<table header-row="true">\n' ..
  '\t<tr>\n\t\t<td>H1</td>\n\t\t<td>H2</td>\n\t</tr>\n' ..
  '\t<tr>\n\t\t<td>A1</td>\n\t\t<td>A2</td>\n\t</tr>\n' ..
  '</table>'
do
  local n = native(TABLE_HEADER)
  local head_pos = n:find("TableHead")
  local h1_pos = n:find('"H1"', 1, true)
  local body_pos = n:find("TableBody")
  t.truthy(head_pos and h1_pos and body_pos and
           head_pos < h1_pos and h1_pos < body_pos,
           "header-row=true puts the first row in the head")
end

local TABLE_CELL_COLOR = '<table>\n' ..
  '\t<tr>\n\t\t<td color="red">A1</td>\n\t</tr>\n' ..
  '</table>'
has(TABLE_CELL_COLOR, 'Cell ( "" , [] , [ ( "color" , "red" ) ] )',
    "cell color lands specifically in the cell's own Attr, not the row's or table's")

-- Notion's own documented space-indented style
local TABLE_SPACE_INDENTED =
  '<table>\n    <tr>\n        <td>Cell</td>\n    </tr>\n</table>'
has(TABLE_SPACE_INDENTED, "[ Table ", "space-indented table parses to a real Table")
has(TABLE_SPACE_INDENTED, '"Cell"', "space-indented table keeps cell content")

-- colgroup/col: pandoc's ColSpec has no Attr slot for a per-column color, so
-- it is genuinely dropped (logged at INFO -- see log_colgroup_colors) rather
-- than represented; either way the table's own structure must stay intact.
local TABLE_COLGROUP_COLOR = '<table>\n' ..
  '\t<colgroup>\n\t\t<col color="red"/>\n\t</colgroup>\n' ..
  '\t<tr>\n\t\t<td>A1</td>\n\t</tr>\n' ..
  '</table>'
has(TABLE_COLGROUP_COLOR, "[ Table ", "colgroup with a col color still parses to a Table")
has(TABLE_COLGROUP_COLOR, '"A1"', "colgroup with a col color keeps the row content")
t.truthy(native(TABLE_COLGROUP_COLOR):find('"color"', 1, true) == nil,
         "the dropped column color does not leak into any native Attr")

local TABLE_COLGROUP_NO_COLOR = '<table>\n' ..
  '\t<colgroup>\n\t\t<col/>\n\t</colgroup>\n' ..
  '\t<tr>\n\t\t<td>A1</td>\n\t</tr>\n' ..
  '</table>'
has(TABLE_COLGROUP_NO_COLOR, "[ Table ", "colgroup with no color is silently ignored")
has(TABLE_COLGROUP_NO_COLOR, '"A1"', "colgroup with no color keeps the row content")

-- CRITICAL fix: pandoc.Caption(nil, {...}) crashes on this pandoc version
-- (`object has no __toinline metamethod`) for EVERY MEDIA_TAGS entry, since
-- none of the 237 prior assertions exercised a media tag at all. Each must
-- parse without crashing AND land as a Figure with the right class and the
-- caption text actually present -- not just "didn't throw".
for _, tag in ipairs({ "audio", "video", "file", "pdf" }) do
  local nfm = string.format('<%s src="u">cap%s</%s>', tag, tag, tag)
  has(nfm, "[ Figure ", "<" .. tag .. "> parses to a Figure without crashing")
  has(nfm, '"' .. tag .. '"', "<" .. tag .. "> carries its class")
  has(nfm, '"cap' .. tag .. '"', "<" .. tag .. "> keeps its caption text")
end

-- MINOR fix: Caption(nil, {...}) also produced `Caption (Just [])` instead
-- of pandoc's own `Caption Nothing […]`; single-argument Caption(long) fixes
-- both the crash and this round-trip mismatch at once.
has('<audio src="u">cap</audio>', "Caption Nothing", "media Figure caption is Nothing, not Just []")
has(TABLE_2X2, "Caption Nothing", "table Caption is Nothing, not Just []")

-- IMPORTANT fix: a standalone image becomes a Figure (spec §4.3), matching
-- the shape media tags produce; an image alongside other text stays a Para.
has("![capB](http://x/i.png)", "[ Figure ", "standalone image becomes a Figure")
has("![capB](http://x/i.png)", '"capB"', "the image's alt text becomes the Figure's caption")
has("text ![img](http://x/i.png) more", "Para", "an image mixed with other text stays a Para")
t.truthy(native("text ![img](http://x/i.png) more"):find("Figure") == nil,
         "...and is NOT promoted to a Figure")

-- IMPORTANT fix: header-column="true" has a real native slot, TableBody's
-- row_head_columns -- it must not be silently discarded like colgroup color.
local TABLE_HEADER_COLUMN = '<table header-column="true">\n' ..
  '\t<tr>\n\t\t<td>A1</td>\n\t\t<td>A2</td>\n\t</tr>\n' ..
  '</table>'
has(TABLE_HEADER_COLUMN, "RowHeadColumns 1", "header-column=true sets RowHeadColumns to 1")
has(TABLE_2X2, "RowHeadColumns 0", "without header-column, RowHeadColumns stays 0")

-- IMPORTANT fix: a <td> spanning multiple lines carries its content as
-- CHILDREN (kind="tag_open", text="<td>"), not inline text -- the reviewer's
-- exact repro. Before the fix this silently produced an empty cell while
-- the Table/Row/Cell structure still looked correct.
local TABLE_MULTILINE_TD = "<table>\n\t<tr>\n\t\t<td>\n\t\t\tCell\n\t\t</td>\n\t</tr>\n</table>"
has(TABLE_MULTILINE_TD, "[ Table ", "multi-line <td> still parses to a Table")
has(TABLE_MULTILINE_TD, '"Cell"', "multi-line <td> keeps its content instead of going empty")

-- MINOR fix: a divider's color has no native Attr slot on HorizontalRule,
-- so it is genuinely dropped (logged at INFO, same tier as colgroup color);
-- the structure must still come out as a plain HorizontalRule.
has('--- {color="blue"}', "HorizontalRule", "a colored divider still parses to a HorizontalRule")
t.truthy(native('--- {color="blue"}'):find('"color"', 1, true) == nil,
         "the dropped divider color does not leak into the native output")

-- Ruling: the code-fence info string carries its own attribute list, same
-- as any other line -- ```` ```lua {color="blue"} ```` must peel into a
-- language class AND real attributes, not a mangled class like
-- `lua {color="blue"}`. A bare fence keeps its language with no attributes.
has('```lua {color="blue"}\nx = 1\n```', "CodeBlock", "attributed fence still becomes a CodeBlock")
has('```lua {color="blue"}\nx = 1\n```', '[ "lua" ]', "attributed fence's class is just the language")
has('```lua {color="blue"}\nx = 1\n```', '"color" , "blue"', "attributed fence's attribute survives")
has("```lua\nx = 1\n```", '[ "lua" ]', "a bare fence still gets a clean language class")
t.truthy(native("```lua\nx = 1\n```"):find("color", 1, true) == nil,
         "...and no stray attributes")

-- Bug fix: a standalone <mention-*> line double-emitted its attributes.
-- tree.parse classifies it as tag_inline/self_closing with its attrs
-- parsed into node.attrs; inlines.read(node.text) ALSO builds the mention
-- Span with those same attrs in its own Attr. Before the fix, block_for's
-- generic paragraph fallthrough then wrap()ped that Para in a redundant
-- attribute Div carrying node.attrs again -- the writer rendered that as a
-- stray trailing `{...}` after the tag on round-trip. A standalone mention
-- must come out as a bare `Para [ Span ... ]`, no enclosing Div, and the
-- URL/attrs must appear exactly once (inside the Span).
local MENTION_LINES = {
  { name = "mention-user",        line = '<mention-user url="https://notion.so/u">Ada</mention-user>' },
  { name = "mention-page",        line = '<mention-page url="https://notion.so/p">Page</mention-page>' },
  { name = "mention-database",    line = '<mention-database url="https://notion.so/d">Database</mention-database>' },
  { name = "mention-data-source", line = '<mention-data-source url="https://notion.so/ds">Source</mention-data-source>' },
  { name = "mention-agent",       line = '<mention-agent url="https://notion.so/a">Agent</mention-agent>' },
  { name = "mention-date",        line = '<mention-date start="2026-01-01"/>' },
}

for _, m in ipairs(MENTION_LINES) do
  local n = native(m.line)
  t.truthy(n:find("[ Para ", 1, true) ~= nil,
           m.name .. ": standalone mention is a bare Para")
  t.truthy(n:find("Div", 1, true) == nil,
           m.name .. ": standalone mention has NO enclosing Div")
  t.truthy(n:find('"' .. m.name .. '"', 1, true) ~= nil,
           m.name .. ": mention class survives inside the Span")

  local ok, out = pcall(pandoc.pipe, "pandoc",
    { "-f", "./notion-markdown-reader.lua", "-t", "./notion-markdown-writer.lua" }, m.line)
  t.truthy(ok, m.name .. ": round-trip does not error: " .. tostring(out))
  if ok then
    -- the writer always terminates its output with a trailing newline, same
    -- as any text file; that is not the bug under test here.
    t.eq(out, m.line .. "\n",
         m.name .. ": standalone mention round-trips byte-identically, no trailing {...}")
  end
end

-- control case: an inline mention embedded in running text must not regress
has('Hi <mention-user url="https://notion.so/u">Ada</mention-user> there',
    '"mention-user"', "inline mention in running text still works")
t.truthy(native('Hi <mention-user url="https://notion.so/u">Ada</mention-user> there'):find("Div") == nil,
         "inline mention in running text is still not wrapped")

-- control case: a genuinely attributed paragraph must still get its wrapper
has('Hello {color="blue"}', "Div", "an attributed (non-mention) paragraph still gets wrapped")
has('Hello {color="blue"}', '"color" , "blue"', "...and still carries its color")
