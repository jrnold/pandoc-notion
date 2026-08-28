local t = require "support.assert"
local escape = require "notion.escape"

t.eq(escape.escape("a*b"), "a\\*b", "escapes asterisk")
t.eq(escape.escape("^caret^"), "\\^caret\\^", "escapes caret")
t.eq(escape.escape("plain text"), "plain text", "leaves ordinary text alone")
t.eq(escape.escape("a\\b"), "a\\\\b", "escapes the backslash itself")

t.eq(escape.unescape("a\\*b"), "a*b", "unescapes asterisk")
t.eq(escape.unescape("a\\qb"), "a\\qb", "leaves non-special escapes intact")

-- Every character in the spec's set round-trips.
for _, c in ipairs(escape.SPECIAL) do
  t.eq(escape.unescape(escape.escape(c)), c, "round-trips " .. c)
  t.eq(escape.escape(c), "\\" .. c, "escapes " .. c)
end

t.eq(#escape.SPECIAL, 13, "the spec lists exactly 13 special characters")
