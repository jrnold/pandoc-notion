local t = require "support.assert"
local attr = require "notion.attr"

-- colors
t.truthy(attr.is_color("blue"), "blue is a color")
t.truthy(attr.is_color("blue_bg"), "blue_bg is a color")
t.truthy(not attr.is_color("chartreuse"), "chartreuse is not")
local n = 0
for _ in pairs(attr.COLORS) do n = n + 1 end
t.eq(n, 18, "exactly 18 legal colors")

-- parse keeps source order
local p, order = attr.parse('icon="X" color="blue_bg"')
t.eq(p, { icon = "X", color = "blue_bg" }, "parses both pairs")
t.eq(order, { "icon", "color" }, "records source order")

-- peel
local text, pairs_, ord = attr.peel('Rich text {color="blue"}')
t.eq(text, "Rich text", "peels the attribute list off")
t.eq(pairs_, { color = "blue" }, "returns the attributes")
t.eq(ord, { "color" }, "returns the order")

-- prose that merely looks like an attribute list must survive untouched
local t2, p2 = attr.peel("see the {color} field")
t.eq(t2, "see the {color} field", "no key=\"value\" means no attribute list")
t.eq(p2, {}, "and no attributes")

local t3, p3 = attr.peel('a literal brace \\{color="blue"}')
t.eq(t3, 'a literal brace \\{color="blue"}', "escaped brace is not an attribute list")
t.eq(p3, {}, "and yields no attributes")

local t4 = attr.peel("plain line")
t.eq(t4, "plain line", "line without braces is unchanged")

-- render
t.eq(attr.render({ color = "blue" }, { "color" }), ' {color="blue"}', "renders one pair")
t.eq(attr.render({ icon = "X", color = "b" }, { "icon", "color" }),
     ' {icon="X" color="b"}', "renders in the given order")
t.eq(attr.render({}, {}), "", "empty renders as empty string")

-- render round-trips peel, which is what byte-exact idempotence depends on
local line = 'Heading {icon="X" color="blue_bg"}'
local body, bp, bo = attr.peel(line)
t.eq(body .. attr.render(bp, bo), line, "peel then render is identity")

-- ordered() exists because pandoc.Attr given a plain Lua map produces a
-- DIFFERENT attribute order on every run, which would make round-trip tests
-- flaky rather than merely wrong.
t.eq(attr.ordered({ icon = "X", color = "b" }, { "icon", "color" }),
     { { "icon", "X" }, { "color", "b" } }, "ordered builds a {k,v} array")

local stable = {}
for i = 1, 5 do
  local a = pandoc.Attr("", {}, attr.ordered({ icon = "X", color = "b", url = "u" },
                                             { "icon", "color", "url" }))
  local keys = {}
  for _, kv in ipairs(a.attributes) do keys[#keys + 1] = kv[1] end
  stable[i] = table.concat(keys, ",")
end
t.eq(stable, { "icon,color,url", "icon,color,url", "icon,color,url",
               "icon,color,url", "icon,color,url" },
     "pandoc.Attr order is stable when given an ordered array")

-- from_attr reads a pandoc AttributeList back in its preserved order
local pa = pandoc.Attr("", {}, { { "icon", "X" }, { "color", "b" } })
local fp, fo = attr.from_attr(pa.attributes)
t.eq(fp, { icon = "X", color = "b" }, "from_attr recovers the pairs")
t.eq(fo, { "icon", "color" }, "from_attr recovers the order")
