local t = require "support.assert"
local w = require "notion.writer.inlines"

local function ils(md)
  local d = pandoc.read(md, "markdown")
  return pandoc.utils.blocks_to_inlines(d.blocks)
end
local function out(md) return w.render(ils(md)) end

t.eq(out("**b**"), "**b**", "bold")
t.eq(out("*i*"), "*i*", "italic")
t.eq(out("~~s~~"), "~~s~~", "strikeout")
t.eq(out("`c`"), "`c`", "inline code")
t.eq(out("[t](http://x)"), "[t](http://x)", "link")
t.eq(out("$e=mc$"), "$e=mc$", "inline math")

-- special characters are escaped outside code
t.eq(w.render({ pandoc.Str("a{b}c") }), "a\\{b\\}c", "braces escaped")
t.eq(w.render({ pandoc.Str("100% ^ 2") }), "100% \\^ 2", "caret escaped")

-- but NOT inside code
t.eq(w.render({ pandoc.Code("a{b}c") }), "`a{b}c`", "code content is literal")

-- convention round-trips
t.eq(w.render({ pandoc.Underline({ pandoc.Str("u") }) }),
     '<span underline="true">u</span>', "underline")
t.eq(w.render({ pandoc.Span({ pandoc.Str("c") }, pandoc.Attr("", {}, { color = "red" })) }),
     '<span color="red">c</span>', "inline color")
t.eq(w.render({ pandoc.LineBreak() }), "<br>", "line break")
t.eq(w.render({ pandoc.Span({ pandoc.Str("Ada") },
        pandoc.Attr("", { "mention", "mention-user" }, { url = "u://1" })) }),
     '<mention-user url="u://1">Ada</mention-user>', "mention")
t.eq(w.render({ pandoc.Span({}, pandoc.Attr("", { "citation" }, { url = "http://x" })) }),
     "[^http://x]", "citation")
-- "\128516" is byte \128 followed by the literal characters "516", not the
-- emoji U+1F604 (same \ddd trap as F2: \ddd caps at \255). Use \u{...}.
t.eq(w.render({ pandoc.Span({ pandoc.Str("\u{1F604}") },
        pandoc.Attr("", { "emoji" }, { ["data-emoji"] = "smile" })) }),
     ":smile:", "custom emoji")

-- degradation: NFM-native fallbacks, never raw HTML
t.eq(w.render({ pandoc.SmallCaps({ pandoc.Str("abc") }) }), "ABC", "smallcaps uppercases")
t.eq(w.render({ pandoc.Subscript({ pandoc.Str("2") }) }), "\226\130\130",
     "subscript uses Unicode")
t.eq(w.render({ pandoc.Superscript({ pandoc.Str("2") }) }), "\194\178",
     "superscript uses Unicode")
-- Non-digit content has no NFM subscript/superscript equivalent, so it falls
-- back to literal text -- the spec's "Unicode equivalents where they exist,
-- else literal text". Every character survives, so this is an APPROXIMATION,
-- not a drop, and is therefore NOT logged (see tests/degrade_test.lua).
t.eq(w.render({ pandoc.Subscript({ pandoc.Str("abc") }) }), "abc",
     "non-digit subscript degrades to plain text")
t.eq(w.render({ pandoc.Superscript({ pandoc.Str("abc") }) }), "abc",
     "non-digit superscript degrades to plain text")
t.eq(w.render({ pandoc.Subscript({ pandoc.Str("a2b") }) }), "a\226\130\130b",
     "a mixed subscript maps the digits and keeps the rest literally")

-- raw HTML: pass through only when the tag is in NFM's closed vocabulary;
-- otherwise it is dropped (logged at INFO), never left as literal HTML.
t.eq(w.render({ pandoc.RawInline("html", '<mention-user url="u://1">') }),
     '<mention-user url="u://1">', "known-vocabulary raw HTML passes through")
t.eq(w.render({ pandoc.RawInline("html", "<sub>") }), "",
     "unknown raw HTML is dropped, not left as literal text")

-- Code content is literal, never backslash-escaped -- but a backtick inside
-- it would close the span early, so the fence grows to one longer than the
-- longest run the content holds, with padding spaces when the content itself
-- starts or ends with a backtick. Backtick-free content is untouched.
t.eq(w.render({ pandoc.Code("plain") }), "`plain`", "backtick-free code is unchanged")
t.eq(w.render({ pandoc.Code("a`b") }), "``a`b``", "one backtick inside grows the fence")
t.eq(w.render({ pandoc.Code("a``b") }), "```a``b```", "the fence beats the longest run")
t.eq(w.render({ pandoc.Code("`lead") }), "`` `lead ``", "a leading backtick is padded")
t.eq(w.render({ pandoc.Code("trail`") }), "`` trail` ``", "a trailing backtick is padded")
t.eq(w.render({ pandoc.Code("a\\b*c") }), "`a\\b*c`", "code is still never escaped")

-- A mention Span with no attributes at all self-closes tightly, matching how
-- every other void NFM tag is written (`<empty-block/>`).
t.eq(w.render({ pandoc.Span({}, pandoc.Attr("", { "mention", "mention-page" }, {})) }),
     "<mention-page/>", "an attribute-less mention self-closes with no stray space")

-- A Span carrying a class NFM cannot express keeps its content and its
-- attributes; only the class is dropped (logged at INFO).
t.eq(w.render({ pandoc.Span({ pandoc.Str("x") },
      pandoc.Attr("", { "foreign" }, { color = "blue" })) }),
     '<span color="blue">x</span>', "an unknown Span class drops, content and attrs stay")
