local t   = require "support.assert"
local nfm = require "support.nfm"

-- CRLF line endings and trailing whitespace at end of line can never be
-- canonical NFM -- the writer always normalizes CRLF to LF and strips
-- trailing whitespace, so a fixture containing either could never be
-- byte-identical on a first pass and doesn't belong in the corpus sweep.
-- Exercised directly here via to_nfm instead, feeding both through and
-- asserting they normalize to clean output, and that the result is stable.

local src = "A line with trailing whitespace.   \r\nAnother line.\r\n"
local expected = "A line with trailing whitespace.\nAnother line."

local once = nfm.to_nfm(src):gsub("\n$", "")
t.eq(once, expected, "CRLF and trailing whitespace normalize to clean LF output")

local twice = nfm.to_nfm(once):gsub("\n$", "")
t.eq(twice, once, "normalized output is stable under a second pass")

-- A leading '#' run the reader does NOT treat as a heading (NFM has levels
-- 1-4; the reader accepts up to 6, then it is prose) must keep its text.
-- markdown_strict's own ATX rule is looser than ours in two directions --
-- seven-plus hashes, and no space after the hashes -- and used to eat the
-- whole run silently, leaving just "seven".
for _, line in ipairs({ "####### seven", "######## eight", "####nospace",
                        "#one" }) do
  local out = nfm.to_nfm(line .. "\n"):gsub("\n$", "")
  t.eq(out, line, "a non-heading '#' run is preserved: " .. line)
  t.eq(nfm.to_nfm(out .. "\n"):gsub("\n$", ""), out, "and is stable: " .. line)
end

-- Six hashes ARE a heading to this reader, clamped to NFM's level 4 -- the
-- boundary the loop above sits just past.
t.eq(nfm.to_nfm("###### six\n"):gsub("\n$", ""), "#### six",
     "six hashes stay a heading, clamped to level 4")

-- An inline Code span containing a backtick must be fenced with a longer
-- backtick run, or it re-reads as different content. Reachable only from
-- foreign-format input, so this goes through the writer alone and then back
-- in through the reader.
do
  local src = "a `` `x ` y` `` b\n"
  local as_nfm  = nfm.from_markdown(src)
  local via     = pandoc.pipe("pandoc", { "-f", nfm.ROOT .. "/notion-markdown-reader.lua",
                                          "-t", "native" }, as_nfm)
  local direct  = pandoc.pipe("pandoc", { "-f", "markdown", "-t", "native" }, src)
  t.eq(via, direct, "a Code span containing backticks survives the writer intact")
end
