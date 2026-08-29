local t   = require "support.assert"
local env = require "notion.block.envelope"

local BLOCK = { object = "block", type = "divider", divider = {} }

-- Shape 1: a bare array.
local blocks, page = env.unwrap({ BLOCK })
t.eq(#blocks, 1, "bare array yields its blocks")
t.eq(page, nil, "bare array carries no page")

-- Shape 2: a paginated list response, exactly as GET returns it.
blocks, page = env.unwrap({
  object = "list", results = { BLOCK, BLOCK }, has_more = false,
  next_cursor = pandoc.json.null,
})
t.eq(#blocks, 2, "list response yields its results")
t.eq(page, nil, "list response carries no page")

-- Shape 3: a page object.
blocks, page = env.unwrap({
  object = "page",
  properties = { title = { type = "title", title = {} } },
  children = { BLOCK },
})
t.eq(#blocks, 1, "page object yields its children")
t.truthy(page ~= nil, "page object is returned for property extraction")
t.truthy(page.properties ~= nil, "the properties map survives")

-- A page with no children is legal and yields no blocks.
blocks, page = env.unwrap({ object = "page", properties = {} })
t.eq(#blocks, 0, "a childless page yields no blocks")
t.truthy(page ~= nil, "but still returns the page")

-- A page whose children arrived under `results` (some hydrators do this).
blocks = env.unwrap({ object = "page", properties = {}, results = { BLOCK } })
t.eq(#blocks, 1, "results is accepted on a page object too")

-- The empty array is legal: an empty document, not an error.
t.eq(#env.unwrap({}), 0, "an empty array is an empty document")

-- Fatal path 2 of 2 (design doc 6.5): an unrecognized envelope.
for _, bad in ipairs({ 42, "a string", true,
                       { object = "user", id = "x" },
                       { object = "database", id = "x" } }) do
  local ok, err = pcall(env.unwrap, bad)
  t.truthy(not ok, "unrecognized envelope raises: " .. t.fmt(bad))
  t.truthy(tostring(err):find("array", 1, true),
           "the diagnostic names the accepted shapes")
end

-- The result is always a pandoc.List, so downstream code can rely on :map etc.
t.truthy(pandoc.utils.type(env.unwrap({ BLOCK })) == "List",
         "blocks come back as a pandoc.List")
