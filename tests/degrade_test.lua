-- Pins the lossy-input policy: deterministic NFM-native fallbacks, silent by
-- default, pandoc.log.info only on a true drop. Silence is asserted as
-- strictly as output, per the spec.
local t   = require "support.assert"
local nfm = require "support.nfm"

local function contains(hay, needle, msg) t.truthy(hay:find(needle, 1, true) ~= nil, msg) end
local function lacks(hay, needle, msg)    t.truthy(hay:find(needle, 1, true) == nil, msg) end

-- Footnote: [n] marker plus an endnote, no raw HTML.
local fn = nfm.from_markdown("Text with a note.[^1]\n\n[^1]: The note body.\n")
contains(fn, "[1]", "footnote leaves a numeric marker")
contains(fn, "The note body.", "note body appears as an endnote")
lacks(fn, "\\[1\\]", "marker and endnote label are unescaped, not \\[1\\]")
lacks(fn, "<sup", "no raw HTML fallback")

-- Definition list: bold term plus indented child.
local dl = nfm.from_markdown("Term\n:   Definition of term.\n")
contains(dl, "**Term**", "term becomes bold")
contains(dl, "\tDefinition of term.", "definition becomes a tab-indented child")

-- Line block: <br>, which is genuinely NFM-native.
local lb = nfm.from_markdown("| A line\n| Second line\n")
contains(lb, "A line<br>Second line", "line block uses <br>")

-- Small caps uppercase; no smallcaps span.
local sc = nfm.from_markdown("[abc]{.smallcaps}\n")
contains(sc, "ABC", "small caps uppercased")
lacks(sc, "smallcaps", "no class=\"smallcaps\" span")

-- Sub/superscript use Unicode, never <sub>/<sup>.
local ss = nfm.from_markdown("H~2~O and x^2^\n")
lacks(ss, "<sub", "no <sub> tag")
lacks(ss, "<sup", "no <sup> tag")
contains(ss, "\226\130\130", "subscript two is U+2082")
contains(ss, "\194\178", "superscript two is U+00B2")

-- Degradation is SILENT at default verbosity -- no log output at all, for
-- an approximated (not dropped) construct such as a footnote or a
-- definition list.
do
  local _, err = nfm.from_markdown_verbose("Text with a note.[^1]\n\n[^1]: Body.\n")
  t.eq(err, "", "footnote approximation logs nothing, even under --verbose")
end
do
  local _, err = nfm.from_markdown_verbose("Term\n:   Def.\n")
  t.eq(err, "", "definition list approximation logs nothing, even under --verbose")
end

-- Same check at genuinely default verbosity (no --verbose flag at all), to
-- make sure nothing leaks onto stderr outside the INFO channel either.
do
  local quiet = io.popen(
    string.format("printf 'Term\\n:   Def.\\n' | pandoc -f markdown -t %q 2>&1 >/dev/null",
                  nfm.ROOT .. "/notion-markdown-writer.lua"), "r")
  local quiet_err = quiet:read("a")
  quiet:close()
  t.eq(quiet_err, "", "approximation logs nothing at default verbosity")
end

-- A TRUE DROP logs INFO: block content inside a table cell.
local nested_cell = table.concat({
  "+---------+", "| - a     |", "|   - b   |", "+---------+", "" }, "\n")
local _, err_drop = nfm.from_markdown_verbose(nested_cell)
contains(err_drop, "INFO", "true drop is logged at INFO")
contains(err_drop, "table cell", "and names the location")
