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
