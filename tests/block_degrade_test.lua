local t  = require "support.assert"
local bj = require "support.blockjson"

-- Design doc 8: degradation is deterministic and SILENT at default verbosity.
-- INFO is emitted only when content is genuinely dropped. Silence is asserted
-- as strictly as output, since the policy makes silence a requirement.
local function convert(markdown)
  return bj.from_markdown_verbose(markdown)
end

local function text_of(out, index)
  local decoded = pandoc.json.decode(out)
  local block = decoded[index or 1]
  local payload = block[block.type]
  local parts = {}
  for _, run in ipairs(payload.rich_text or {}) do
    parts[#parts + 1] = run.text and run.text.content or run.plain_text
  end
  return table.concat(parts)
end

-- LineBlock is native, not lossy.
local out, log = convert("| one\n| two\n")
t.eq(text_of(out), "one\ntwo", "LineBlock becomes one paragraph with newlines")
t.truthy(not log:find("%[INFO%]"), "and logs nothing, since nothing was dropped")

-- SmallCaps uppercases, silently.
out, log = convert("[quiet]{.smallcaps}\n")
t.eq(text_of(out), "QUIET", "SmallCaps uppercases")
t.truthy(not log:find("%[INFO%]"), "silently")

-- Super/subscript, silently.
out, log = convert("x^2^ and H~2~O\n")
t.truthy(text_of(out):find("²", 1, true), "superscript uses its Unicode form")
t.truthy(text_of(out):find("₂", 1, true), "so does subscript")
t.truthy(not log:find("%[INFO%]"), "silently")

-- Definition lists, silently.
out, log = convert("Term\n\n:   Meaning\n")
local dl = pandoc.json.decode(out)[1]
t.eq(dl.paragraph.rich_text[1].annotations.bold, true, "the term is bolded")
t.truthy(dl.paragraph.children ~= nil, "the definition becomes a child block")
t.truthy(not log:find("%[INFO%]"), "silently")

-- Footnotes, silently.
out, log = convert("Text[^1]\n\n[^1]: The note.\n")
t.truthy(text_of(out):find("[1]", 1, true), "a marker is left inline")
t.truthy(#pandoc.json.decode(out) > 1, "and the body is appended as an endnote")
t.truthy(not log:find("%[INFO%]"), "silently")

-- Headings beyond 4 clamp, silently.
out, log = convert("##### Deep\n")
t.eq(pandoc.json.decode(out)[1].type, "heading_4", "H5 clamps to heading_4")
t.truthy(not log:find("%[INFO%]"), "silently")

-- A genuine drop: raw content in a foreign format. This one MUST log.
out, log = convert("```{=latex}\n\\vspace{1cm}\n```\n")
t.eq(#pandoc.json.decode(out), 0, "a foreign RawBlock is dropped")
t.truthy(log:find("Not rendering RawBlock", 1, true), "and logs at INFO")

-- A genuine drop: block content inside a table cell. Two grid-table rows
-- separated by a blank row inside the same cell parse as two Para blocks in
-- one Cell -- the brief's original "| - a\n  - b   |" fixture is malformed
-- grid-table syntax (each continuation line of a multi-line cell needs its
-- own trailing "|"), so pandoc parses it as a single Para, not a Table, and
-- never reaches the cell path at all. Verified against pandoc 3.11: this
-- fixture actually produces `Cell ... [Para ["a"], Para ["b"]]`.
out, log = convert("+---------+\n| a       |\n|         |\n| b       |\n+---------+\n")
t.truthy(log:find("Not rendering block content inside table cell", 1, true),
         "a multi-block cell logs at INFO")
t.eq(pandoc.json.decode(out)[1].type, "table",
     "and the table itself still converts -- the cell is flattened, not dropped")
