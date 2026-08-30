local t  = require "support.assert"
local bj = require "support.blockjson"

-- A list response, exactly as GET /v1/blocks/:id/children returns it.
local LIST = [[
{"object":"list","results":[
  {"object":"block","id":"b-1","type":"heading_1",
   "heading_1":{"rich_text":[{"type":"text","text":{"content":"Title"},
     "annotations":{"bold":false,"italic":false,"strikethrough":false,
     "underline":false,"code":false,"color":"default"},"plain_text":"Title"}],
     "color":"default","is_toggleable":false}},
  {"object":"block","id":"b-2","type":"paragraph",
   "paragraph":{"rich_text":[{"type":"text","text":{"content":"Body"},
     "annotations":{"bold":false,"italic":false,"strikethrough":false,
     "underline":false,"code":false,"color":"default"},"plain_text":"Body"}],
     "color":"default"}}
],"has_more":false,"next_cursor":null}
]]

local native = bj.to_native(LIST)
t.truthy(native:find("Header 1", 1, true), "the heading survives end to end")
t.truthy(native:find('Str "Body"', 1, true), "so does the paragraph")
t.truthy(native:find("b-1", 1, true), "and the block id reaches the AST")

-- A bare array works too.
t.truthy(bj.to_native('[{"type":"divider","divider":{}}]'):find("HorizontalRule", 1, true),
         "a bare array is accepted")

-- A page object contributes Meta.
local PAGE = [[
{"object":"page","id":"p-1",
 "properties":{"title":{"type":"title","title":[{"type":"text",
   "text":{"content":"Q3 Roadmap"},"annotations":{},"plain_text":"Q3 Roadmap"}]},
   "Status":{"type":"select","select":{"name":"In progress"}}},
 "children":[{"type":"paragraph","paragraph":{"rich_text":[]}}]}
]]
local meta_native = bj.to_native(PAGE)
t.truthy(meta_native:find("Q3", 1, true), "the page title reaches Meta")
t.truthy(meta_native:find("In progress", 1, true), "so do other properties")

-- Standalone output is titled, which is the whole point of lifting the title.
local html = pandoc.pipe("pandoc",
  { "-f", bj.READER, "-t", "html", "--standalone" }, PAGE)
t.truthy(html:find("<title>Q3 Roadmap</title>", 1, true),
         "--standalone output carries the title")

-- Fatal path 1: unparseable input. pandoc must exit non-zero.
local ok = pcall(pandoc.pipe, "pandoc", { "-f", bj.READER, "-t", "native" }, "{bad")
t.truthy(not ok, "malformed JSON fails the conversion")

-- Fatal path 2: an unrecognized envelope.
local ok2 = pcall(pandoc.pipe, "pandoc", { "-f", bj.READER, "-t", "native" },
                  '{"object":"user","id":"u-1"}')
t.truthy(not ok2, "an unrecognized envelope fails the conversion")

-- An empty document is legal.
t.truthy(bj.to_native("[]"):find("%[%s*%]"), "an empty array yields an empty document")
