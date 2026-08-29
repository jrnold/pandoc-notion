local t   = require "support.assert"
local nfm = require "support.nfm"

-- Notion's own "Complete example" (enhanced-markdown page, spec Sec 3) uses a
-- markdown PIPE table for its Status/Owner example, not the <table>/<tr>/<td>
-- HTML form documented elsewhere on the same page. Neither doc page states or
-- implies pipe tables are rejected on input, so the reader is liberal on
-- read: notion/reader/blocks.lua's pipe_table_run detects a run of
-- consecutive lines starting with "|", hands them to pandoc.read with the
-- pinned +pipe_tables extension, and uses the resulting Table directly when
-- it parses to exactly one. The writer stays canonical -- it only ever emits
-- <table>/<tr>/<td> -- so a pipe table normalizes on the very first pass.
-- That is fine because byte-identity is already waived; this fixture is
-- pinned in KNOWN_NOT_BYTE_IDENTICAL specifically for that normalization.

local pipe_path = nfm.ROOT .. "/tests/corpus/blocks/table-pipe.nfm"
local pipe_src  = nfm.read_file(pipe_path):gsub("\n$", "")

local pipe_once = nfm.to_nfm(pipe_src):gsub("\n$", "")
t.eq(pipe_once,
  "<table header-row=\"true\">\n\t<tr>\n\t\t<td>Status</td>\n\t\t<td>Owner</td>\n\t</tr>\n"
  .. "\t<tr>\n\t\t<td>In progress</td>\n\t\t<td>Ada</td>\n\t</tr>\n</table>",
  "a markdown pipe table normalizes to the canonical <table> form")

-- The reader must be liberal but not credulous: a line starting with "|"
-- that is NOT a well-formed table -- a stray literal "|" in prose, here with
-- no delimiter row at all -- must fall through to ordinary paragraph
-- handling. It must never crash and never be silently swallowed (both real
-- hazards for a hand-rolled "does this look like a table" check).

local hazard_path = nfm.ROOT .. "/tests/corpus/adversarial/pipe-not-table.nfm"
local hazard_src  = nfm.read_file(hazard_path):gsub("\n$", "")

local hazard_once = nfm.to_nfm(hazard_src):gsub("\n$", "")
t.eq(hazard_once, "\\| Not a table, just prose with a pipe.",
  "a non-table line starting with \"|\" stays a paragraph, with the pipe escaped on write")

-- Notion's own official cell content (<mention-user> inside a pipe-table
-- cell, tests/corpus/official/complete-example.nfm) must fold to the same
-- Span-based mention representation a <table> cell gets, not survive as a
-- dropped RawInline pair -- otherwise the mention silently disappears.
local mention_row = table.concat({
  "| Status | Owner |", "|---|---|",
  '| In progress | <mention-user url="u">Ada</mention-user> |', "" }, "\n")
local mention_out = nfm.to_nfm(mention_row):gsub("\n$", "")
t.truthy(mention_out:find('<mention-user url="u">Ada</mention-user>', 1, true) ~= nil,
  "a mention inside a pipe-table cell folds instead of being dropped")

-- pandoc's own pipe-tables grammar does not REJECT a delimiter row that
-- under-specifies columns relative to the header/data rows -- it silently
-- narrows the whole table to match the delimiter, dropping the extra
-- columns with no error and no [INFO]. pipe_table_run guards against this
-- by comparing the parsed table's column count against the widest column
-- count any source line implies, and falling back to ordinary paragraphs
-- when the table came out narrower. The assertion that matters is that
-- BOTH the dropped column's header ("B") and the dropped cell ("2")
-- survive in the fallback output -- a test that only checked "it didn't
-- crash" would have passed even with the data silently gone.
local truncated_path = nfm.ROOT .. "/tests/corpus/adversarial/pipe-table-truncated-delimiter.nfm"
local truncated_src  = nfm.read_file(truncated_path):gsub("\n$", "")

local truncated_once = nfm.to_nfm(truncated_src):gsub("\n$", "")
t.eq(truncated_once, "\\| A \\| B \\|\n\\|--\n\\| 1 \\| 2 \\|",
  "a delimiter row narrower than the header falls back to paragraphs, not a truncated table")
t.truthy(truncated_once:find("B", 1, true) ~= nil, "the dropped column header (\"B\") survives")
t.truthy(truncated_once:find("2", 1, true) ~= nil, "the dropped cell (\"2\") survives")

-- Control: an ordinary well-formed `|---|---|` delimiter still parses as a
-- real Table -- the fix above must not make the reader newly distrustful
-- of valid tables.
local control_once = nfm.to_nfm(pipe_src):gsub("\n$", "")
t.truthy(control_once:find("<table", 1, true) ~= nil,
  "a well-formed delimiter row still parses as <table> (no regression)")

-- A delimiter row that OVER-specifies columns relative to the header does
-- NOT lose data -- pandoc pads the header's missing trailing cell instead
-- of dropping anything -- so it must still parse as a Table with every
-- value intact, not fall back.
local wide_delim = table.concat({
  "| A | B |", "|---|---|---|", "| 1 | 2 | 3 |", "" }, "\n")
local wide_once = nfm.to_nfm(wide_delim):gsub("\n$", "")
t.truthy(wide_once:find("<table", 1, true) ~= nil,
  "a delimiter row wider than the header still parses as <table>")
for _, want in ipairs({ "A", "B", "1", "2", "3" }) do
  t.truthy(wide_once:find(">" .. want .. "<", 1, true) ~= nil,
    "a wide delimiter row keeps every value, including \"" .. want .. "\"")
end
