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
t.eq(w.render({ pandoc.Span({ pandoc.Str("\128516") },
        pandoc.Attr("", { "emoji" }, { ["data-emoji"] = "smile" })) }),
     ":smile:", "custom emoji")

-- degradation: NFM-native fallbacks, never raw HTML
t.eq(w.render({ pandoc.SmallCaps({ pandoc.Str("abc") }) }), "ABC", "smallcaps uppercases")
t.eq(w.render({ pandoc.Subscript({ pandoc.Str("2") }) }), "\226\130\130",
     "subscript uses Unicode")
t.eq(w.render({ pandoc.Superscript({ pandoc.Str("2") }) }), "\194\178",
     "superscript uses Unicode")
