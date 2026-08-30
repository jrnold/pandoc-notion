-- The structurally irregular block types. These shapes must match what the NFM
-- reader produces byte for byte, or the cross-pair test (Task 14) fails.
local json     = require "notion.block.json"
local richtext = require "notion.block.richtext"
local reader   = require "notion.block.reader"

local function inlines_of(payload)
  return richtext.to_inlines(json.get(payload, "rich_text"))
end

local function id_of(block)
  local id = json.get(block, "id")
  return id and tostring(id) or ""
end

-- ---- headings -------------------------------------------------------------

for level = 1, 4 do
  reader.CUSTOM["heading_" .. level] = function(block, payload)
    local attributes = {}
    if json.get(payload, "is_toggleable") == true then
      attributes[#attributes + 1] = { "toggle", "true" }
    end
    local color = json.color_to_ast(json.get(payload, "color"))
    if color then attributes[#attributes + 1] = { "color", color } end

    local header = pandoc.Header(level, inlines_of(payload),
                                 pandoc.Attr(id_of(block), {}, attributes))
    local kids = reader.convert(reader.children_of(block, payload))
    if #kids == 0 then return header end
    -- A Header cannot contain blocks, so a toggle heading WITH children needs
    -- the wrapper. Without children it does not.
    return pandoc.Div(pandoc.Blocks({ header }) .. kids,
                      pandoc.Attr("", { "toggle-heading" }, {}))
  end
end

-- ---- list items -----------------------------------------------------------

-- Called by reader.convert once per item in a grouped run.
function reader.list_item(block, type_name, payload)
  local inlines = inlines_of(payload)
  if type_name == "to_do" then
    local mark = json.get(payload, "checked") == true and "\u{2612}" or "\u{2610}"
    inlines = pandoc.Inlines({ pandoc.Str(mark), pandoc.Space() }) .. inlines
  end
  local body = pandoc.Blocks({ pandoc.Plain(inlines) })
  local kids = reader.convert(reader.children_of(block, payload))
  body = body .. kids

  local color = json.color_to_ast(json.get(payload, "color"))
  local id    = id_of(block)
  if color or id ~= "" then
    local attributes = color and { { "color", color } } or {}
    return pandoc.Blocks({ pandoc.Div(body, pandoc.Attr(id, {}, attributes)) })
  end
  return body
end

-- ---- code -----------------------------------------------------------------

reader.CUSTOM.code = function(block, payload)
  local text = pandoc.utils.stringify(inlines_of(payload))
  local language = json.get(payload, "language")
  local classes = {}
  if language and language ~= "plain text" then classes[1] = tostring(language) end

  local attributes = {}
  local caption = richtext.to_inlines(json.get(payload, "caption"))
  if #caption > 0 then
    attributes[#attributes + 1] = { "caption", pandoc.utils.stringify(caption) }
  end
  return pandoc.CodeBlock(text, pandoc.Attr(id_of(block), classes, attributes))
end

-- ---- columns --------------------------------------------------------------

reader.CUSTOM.column_list = function(block, payload)
  return pandoc.Div(reader.convert(reader.children_of(block, payload)),
                    pandoc.Attr(id_of(block), { "columns" }, {}))
end

reader.CUSTOM.column = function(block, payload)
  local attributes = {}
  local ratio = json.get(payload, "width_ratio")
  if ratio then
    local i = math.tointeger(ratio)
    attributes[#attributes + 1] = { "width-ratio", i and tostring(i) or tostring(ratio) }
  end
  return pandoc.Div(reader.convert(reader.children_of(block, payload)),
                    pandoc.Attr(id_of(block), { "column" }, attributes))
end

-- ---- media ----------------------------------------------------------------

-- The URL lives on the inner Link, never duplicated onto the Figure's attrs.
-- This matches tests/golden/blocks/media-av.native exactly.
local function media_reader(class)
  return function(block, payload)
    local kind = json.get(payload, "type")
    local url, upload_id
    if kind == "file_upload" then
      upload_id = json.get(json.get(payload, "file_upload"), "id")
    elseif kind then
      url = json.get(json.get(payload, kind), "url")
    end

    local caption = richtext.to_inlines(json.get(payload, "caption"))
    if #caption == 0 then
      local name = json.get(payload, "name")
      if name then caption = pandoc.Inlines({ pandoc.Str(tostring(name)) }) end
    end

    local attributes = {}
    if upload_id then
      attributes[#attributes + 1] = { "data-file-upload-id", tostring(upload_id) }
    end
    local color = json.color_to_ast(json.get(payload, "color"))
    if color then attributes[#attributes + 1] = { "color", color } end

    local body
    if url then
      body = pandoc.Blocks({ pandoc.Plain({
        pandoc.Link(caption, tostring(url)) }) })
    else
      body = pandoc.Blocks({ pandoc.Plain(caption) })
    end

    return pandoc.Figure(body,
      pandoc.Caption(pandoc.Blocks({ pandoc.Plain(caption) })),
      pandoc.Attr(id_of(block), { class }, attributes))
  end
end

for _, class in ipairs({ "image", "video", "audio", "pdf", "file" }) do
  reader.CUSTOM[class] = media_reader(class)
end

-- ---- tables ---------------------------------------------------------------

local function row_cells(row_block)
  local payload = json.get(row_block, "table_row") or {}
  local cells = pandoc.List({})
  for _, cell in ipairs(json.get(payload, "cells") or {}) do
    cells:insert(pandoc.Cell(
      pandoc.Blocks({ pandoc.Plain(richtext.to_inlines(cell)) })))
  end
  return pandoc.Row(cells)
end

reader.CUSTOM.table = function(block, payload)
  local width = math.tointeger(json.get(payload, "table_width") or 0) or 0
  local rows = pandoc.List({})
  for _, child in ipairs(reader.children_of(block, payload)) do
    if json.get(child, "type") == "table_row" then rows:insert(row_cells(child)) end
  end
  if width == 0 and #rows > 0 then width = #rows[1].cells end

  local colspecs = {}
  for _ = 1, width do
    colspecs[#colspecs + 1] = { pandoc.AlignDefault, nil }
  end

  local head_rows = pandoc.List({})
  if json.get(payload, "has_column_header") == true and #rows > 0 then
    head_rows:insert(rows:remove(1))
  end
  local row_head_columns = json.get(payload, "has_row_header") == true and 1 or 0

  return pandoc.Table(
    pandoc.Caption(pandoc.Blocks({})),
    colspecs,
    pandoc.TableHead(head_rows),
    { pandoc.TableBody(rows, {}, row_head_columns) },
    pandoc.TableFoot(),
    pandoc.Attr(id_of(block), {}, {}))
end

-- A stray table_row outside a table: recovered, not fatal.
reader.CUSTOM.table_row = function(block, payload)
  return pandoc.Plain(richtext.to_inlines((json.get(payload, "cells") or {})[1]))
end

-- ---- synced blocks --------------------------------------------------------

-- One Notion type, two AST classes. synced_from is what distinguishes them.
reader.CUSTOM.synced_block = function(block, payload)
  local from = json.get(payload, "synced_from")
  local body = reader.convert(reader.children_of(block, payload))
  if from then
    local source = json.get(from, "block_id")
    local attributes = source and { { "url", tostring(source) } } or {}
    return pandoc.Div(body, pandoc.Attr(id_of(block),
                                        { "synced-block-reference" }, attributes))
  end
  return pandoc.Div(body, pandoc.Attr(id_of(block), { "synced-block" }, {}))
end

-- ---- block-level mention --------------------------------------------------

reader.CUSTOM.mention = function(block, payload)
  return pandoc.Para(richtext.to_inlines({
    { type = "mention", mention = payload, annotations = {},
      plain_text = json.get(block, "plain_text") } }))
end

return true
