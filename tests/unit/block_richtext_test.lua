local t  = require "support.assert"
local rt = require "notion.block.richtext"

-- Build a rich text object with the annotations that matter, defaults elsewhere.
local function seg(content, ann, href)
  ann = ann or {}
  return {
    type = "text",
    text = { content = content, link = href and { url = href } or nil },
    annotations = {
      bold          = ann.bold          or false,
      italic        = ann.italic        or false,
      strikethrough = ann.strikethrough or false,
      underline     = ann.underline     or false,
      code          = ann.code          or false,
      color         = ann.color         or "default",
    },
    plain_text = content,
    href = href,
  }
end

local function native(inlines)
  return pandoc.write(pandoc.Pandoc({ pandoc.Plain(inlines) }), "native")
end

-- Plain text.
t.eq(native(rt.to_inlines({ seg("hello world") })),
     native({ pandoc.Str("hello"), pandoc.Space(), pandoc.Str("world") }),
     "plain text becomes Str/Space")

-- Single annotations.
t.eq(native(rt.to_inlines({ seg("x", { bold = true }) })),
     native({ pandoc.Strong({ pandoc.Str("x") }) }), "bold becomes Strong")
t.eq(native(rt.to_inlines({ seg("x", { italic = true }) })),
     native({ pandoc.Emph({ pandoc.Str("x") }) }), "italic becomes Emph")
t.eq(native(rt.to_inlines({ seg("x", { underline = true }) })),
     native({ pandoc.Underline({ pandoc.Str("x") }) }), "underline is native")
t.eq(native(rt.to_inlines({ seg("x", { strikethrough = true }) })),
     native({ pandoc.Strikeout({ pandoc.Str("x") }) }), "strikethrough becomes Strikeout")

-- Code is innermost by type constraint: it holds a string, not inlines.
t.eq(native(rt.to_inlines({ seg("x", { code = true, bold = true }) })),
     native({ pandoc.Strong({ pandoc.Code("x") }) }),
     "code sits inside Strong, never the reverse")

-- Canonical order: Link, Span(color), Strong, Emph, Underline, Strikeout.
local all = rt.to_inlines({ seg("x", {
  bold = true, italic = true, underline = true,
  strikethrough = true, color = "blue",
}, "https://example.com") })
t.eq(native(all), native({
  pandoc.Link({
    pandoc.Span({
      pandoc.Strong({
        pandoc.Emph({
          pandoc.Underline({ pandoc.Strikeout({ pandoc.Str("x") }) })
        })
      })
    }, pandoc.Attr("", {}, { { "color", "blue" } }))
  }, "https://example.com")
}), "the full stack nests in canonical order")

-- Colour translation happens here, not in the caller.
t.eq(native(rt.to_inlines({ seg("x", { color = "blue_background" }) })),
     native({ pandoc.Span({ pandoc.Str("x") },
                          pandoc.Attr("", {}, { { "color", "blue_bg" } })) }),
     "_background becomes _bg")
t.eq(native(rt.to_inlines({ seg("x", { color = "default" }) })),
     native({ pandoc.Str("x") }), "default colour adds no Span")

-- Coalescing: Notion splits runs arbitrarily; identical neighbours must merge.
t.eq(native(rt.to_inlines({ seg("He", { bold = true }), seg("llo", { bold = true }) })),
     native({ pandoc.Strong({ pandoc.Str("Hello") }) }),
     "adjacent identical annotations coalesce into one wrapper")
t.eq(native(rt.to_inlines({ seg("a", { bold = true }), seg("b", { italic = true }) })),
     native({ pandoc.Strong({ pandoc.Str("a") }), pandoc.Emph({ pandoc.Str("b") }) }),
     "differing annotations do not coalesce")

-- A newline inside content is a line break within the block.
t.eq(native(rt.to_inlines({ seg("a\nb") })),
     native({ pandoc.Str("a"), pandoc.LineBreak(), pandoc.Str("b") }),
     "\\n becomes LineBreak")

-- Equations.
t.eq(native(rt.to_inlines({ { type = "equation", equation = { expression = "e=mc^2" },
                              annotations = {}, plain_text = "e=mc^2" } })),
     native({ pandoc.Math("InlineMath", "e=mc^2") }), "equation becomes InlineMath")

-- Mentions carry both a generic and a specific class.
local m = rt.to_inlines({ {
  type = "mention",
  mention = { type = "user", user = { object = "user", id = "abc-123" } },
  annotations = {}, plain_text = "Ada",
} })
t.eq(m[1].t, "Span", "a mention is a Span")
t.eq(m[1].classes, pandoc.List({ "mention", "mention-user" }), "both classes present")

-- An unlisted mention kind degrades generically rather than being dropped.
local u = rt.to_inlines({ {
  type = "mention",
  mention = { type = "data_source", data_source = { id = "d-1" } },
  annotations = {}, plain_text = "Sources",
} })
t.eq(u[1].classes, pandoc.List({ "mention", "mention-data-source" }),
     "unknown mention kinds get a class from their name")
t.eq(pandoc.utils.stringify(u[1]), "Sources", "and keep their plain_text")

-- null in an optional field must not be treated as present.
t.eq(native(rt.to_inlines({ {
       type = "text",
       text = { content = "x", link = pandoc.json.null },
       annotations = {}, plain_text = "x", href = pandoc.json.null,
     } })),
     native({ pandoc.Str("x") }), "null link does not produce a Link")

-- A mention carrying a top-level href must NOT be wrapped in a Link: its URL
-- already lives in the Span's url attribute, and Link[mention] is not
-- expressible in NFM, which would break the cross-pair round trip.
local href_mention = rt.to_inlines({ {
  type = "mention",
  mention = { type = "page", page = { id = "p-1" } },
  annotations = {}, plain_text = "Ada", href = "https://notion.so/p",
} })
t.eq(href_mention[1].t, "Span", "a mention with an href stays a bare Span")
t.eq(href_mention[1].classes, pandoc.List({ "mention", "mention-page" }),
     "and keeps both mention classes")

-- Same annotations but different link targets must not coalesce. identity()
-- already folds href into the key; this pins the behaviour.
local two_links = rt.to_inlines({
  seg("a", { bold = true }, "https://one.example"),
  seg("b", { bold = true }, "https://two.example"),
})
t.eq(#two_links, 2, "runs with different hrefs do not coalesce")

-- Empty input.
t.eq(#rt.to_inlines({}), 0, "empty rich_text yields no inlines")
t.eq(#rt.to_inlines(nil), 0, "absent rich_text yields no inlines")
