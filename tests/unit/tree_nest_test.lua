local t = require "support.assert"
local tree = require "notion.reader.tree"

-- indentation nesting
local n = tree.parse("- parent\n\tchild\n\t\tgrandchild")
t.eq(#n, 1, "one root")
t.eq(n[1].text, "- parent", "root text")
t.eq(#n[1].children, 1, "one child")
t.eq(n[1].children[1].text, "child", "child text")
t.eq(n[1].children[1].children[1].text, "grandchild", "grandchild nests")

-- siblings at depth 0 are separate blocks (single-newline rule)
local sib = tree.parse("one\ntwo\nthree")
t.eq(#sib, 3, "three sibling blocks")

-- blank lines are stripped entirely
t.eq(#tree.parse("a\n\n\nb"), 2, "blank lines vanish")

-- attributes are peeled during nesting
local a = tree.parse('Rich text {color="blue"}')
t.eq(a[1].text, "Rich text", "attribute list removed from text")
t.eq(a[1].attrs, { color = "blue" }, "attributes captured")
t.eq(a[1].attr_order, { "color" }, "order captured")

-- tag balance nesting, independent of indentation
local c = tree.parse('<callout icon="X" color="blue_bg">\n\tRich **text**\n</callout>')
t.eq(#c, 1, "callout is one root node")
t.eq(c[1].tag, "callout", "tag recorded")
t.eq(c[1].attrs, { icon = "X", color = "blue_bg" }, "tag attributes parsed")
t.eq(#c[1].children, 1, "one child")
t.eq(c[1].children[1].text, "Rich **text**", "child content")

-- Notion's own docs indent container children with SPACES; tag balance means
-- that still works, because indentation is not what nests them.
local sp = tree.parse('<callout icon="X">\n    Spaced child\n</callout>')
t.eq(#sp[1].children, 1, "space-indented container child still nests")
t.eq(sp[1].children[1].text, "Spaced child", "and keeps its text")

-- fences collapse into one code node with literal content
local f = tree.parse("```python\ndef f():\n\treturn 1\n```")
t.eq(#f, 1, "fence is one node")
t.eq(f[1].kind, "code", "kind is code")
t.eq(f[1].info, "python", "language captured")
t.eq(f[1].text, "def f():\n\treturn 1", "body is literal, tabs preserved")

-- unbalanced closing tag is recovered as literal text, never fatal
local u = tree.parse("</callout>")
t.eq(#u, 1, "recovered as one node")
t.eq(u[1].kind, "text", "treated as literal text")
t.eq(u[1].text, "</callout>", "text preserved verbatim")

-- self-closing tags are complete nodes and open no nesting level
local v = tree.parse("<table_of_contents/>\nafter")
t.eq(#v, 2, "self-closing tag does not swallow the next line")
t.eq(v[1].tag, "table_of_contents", "tag recorded")
t.eq(#v[1].children, 0, "and has no children")
