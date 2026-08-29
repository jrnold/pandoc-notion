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

-- Sub/superscript over NON-digit content is the spec table's "Unicode
-- equivalents where they exist, ELSE LITERAL TEXT" -- an APPROXIMATION, not a
-- drop: every character survives, so nothing may be logged. (This used to
-- log INFO, contradicting the spec's own tier.)
do
  local out, err = nfm.from_markdown_verbose("x~abc~ and y^def^\n")
  contains(out, "xabc", "non-digit subscript keeps its text literally")
  contains(out, "ydef", "non-digit superscript keeps its text literally")
  t.eq(err, "", "non-digit sub/superscript is an approximation and logs nothing")
end

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

-- Every remaining TRUE DROP on the write side. Each keeps the content it can
-- and discards something NFM has no slot for at all, so each must log INFO
-- under --verbose and stay silent at default verbosity. These were all
-- verified as producing zero bytes of stderr before this suite grew.
local WRITE_DROPS = {
  { name  = "table caption",
    input = "| a | b |\n|---|---|\n| 1 | 2 |\n\n: My caption\n",
    needle = "table caption" },
  { name  = "heading identifier",
    input = "# Foo {#myid}\n",
    needle = 'identifier "myid"' },
  { name  = "heading class",
    input = "# Foo {.mycls}\n",
    needle = 'heading class "mycls"' },
  { name  = "span class",
    input = "[inner]{.myclass}\n",
    needle = 'Span class "myclass"' },
  { name  = "code block class past the first",
    input = "``` {.lua .numberLines}\nx = 1\n```\n",
    needle = 'code block class "numberLines"' },
}

for _, case in ipairs(WRITE_DROPS) do
  local out, err = nfm.from_markdown_verbose(case.input)
  contains(err, "INFO", case.name .. " drop is logged at INFO")
  contains(err, case.needle, case.name .. " drop names what was dropped")
  -- and the content that CAN survive still does
  t.truthy(#out > 0, case.name .. " still produces output")
end

-- Silence at default verbosity, for every write-side drop above: INFO is an
-- INFO, not a warning, so nothing may reach stderr without --verbose.
for _, case in ipairs(WRITE_DROPS) do
  local tmp = os.tmpname()
  local fh = assert(io.open(tmp, "wb")); fh:write(case.input); fh:close()
  local p = assert(io.popen(string.format("pandoc -f markdown -t %q %q 2>&1 >/dev/null",
                                          nfm.ROOT .. "/notion-markdown-writer.lua", tmp), "r"))
  local quiet_err = p:read("a")
  p:close()
  os.remove(tmp)
  t.eq(quiet_err, "", case.name .. " drop is silent at default verbosity")
end

-- The READ side drops a block wrapper inside a <td> the same way the write
-- side does (blocks_to_inlines keeps the text, loses the structure), so it
-- must log the same way -- the inconsistency this pins was one construct
-- being loud in one direction and silent in the other.
do
  local td_blocks = "<table>\n<tr>\n<td>\n- a\n- b\n</td>\n</tr>\n</table>\n"
  local out, err = nfm.to_nfm_with_log(td_blocks)
  contains(err, "INFO", "reader logs a block wrapper dropped inside <td>")
  contains(err, "table cell", "and names the location, as the writer does")
  contains(out, "ab", "the cell's text still survives the drop")

  local tmp = os.tmpname()
  local fh = assert(io.open(tmp, "wb")); fh:write(td_blocks); fh:close()
  local p = assert(io.popen(string.format("pandoc -f %q -t %q %q 2>&1 >/dev/null",
                                          nfm.ROOT .. "/notion-markdown-reader.lua",
                                          nfm.ROOT .. "/notion-markdown-writer.lua", tmp), "r"))
  local quiet_err = p:read("a")
  p:close()
  os.remove(tmp)
  t.eq(quiet_err, "", "reader's <td> block drop is silent at default verbosity")
end
