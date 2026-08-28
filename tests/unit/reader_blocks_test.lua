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
has(TABLE_2X2, "Table", "table becomes a native Table")
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
has(TABLE_CELL_COLOR, '"color" , "red"', "cell color lands in the cell's Attr")

-- Notion's own documented space-indented style
local TABLE_SPACE_INDENTED =
  '<table>\n    <tr>\n        <td>Cell</td>\n    </tr>\n</table>'
has(TABLE_SPACE_INDENTED, "Table", "space-indented table parses to a real Table")
has(TABLE_SPACE_INDENTED, '"Cell"', "space-indented table keeps cell content")
