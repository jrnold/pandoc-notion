-- Structural block types plus the design doc 8 lossy fallbacks.
local json     = require "notion.block.json"
local richtext = require "notion.block.richtext"
local writer   = require "notion.block.writer"

-- ---- tables ---------------------------------------------------------------

-- Notion table cells hold rich text only. A cell containing blocks is a real
-- drop, so it logs at INFO -- unlike the silent degradations around it.
local function cell_rich_text(cell)
  local blocks = cell.content or {}
  if #blocks > 1 then
    pandoc.log.info("Not rendering block content inside table cell")
  end
  local inlines = pandoc.Inlines({})
  for i, b in ipairs(blocks) do
    if i > 1 then inlines:insert(pandoc.Space()) end
    for _, il in ipairs(pandoc.utils.blocks_to_inlines({ b })) do
      inlines:insert(il)
    end
  end
  return richtext.from_inlines(inlines)
end

local function row_block(row)
  local cells = json.arr()
  for _, cell in ipairs(row.cells or {}) do cells:insert(cell_rich_text(cell)) end
  return writer.block("table_row", json.obj({ cells = cells }), nil)
end

writer.HANDLERS.Table = function(el)
  local children = json.arr()
  local head_rows = (el.head and el.head.rows) or {}
  for _, row in ipairs(head_rows) do children:insert(row_block(row)) end

  local row_head_columns = 0
  for _, body in ipairs(el.bodies or {}) do
    row_head_columns = math.max(row_head_columns, body.row_head_columns or 0)
    for _, row in ipairs(body.body or {}) do children:insert(row_block(row)) end
  end
  for _, row in ipairs((el.foot and el.foot.rows) or {}) do
    children:insert(row_block(row))
  end

  return writer.block("table", json.obj({
    table_width       = #(el.colspecs or {}),
    has_column_header = #head_rows > 0,
    has_row_header    = row_head_columns > 0,
    children          = children,
  }), el)
end

-- ---- figures / media ------------------------------------------------------

local MEDIA_CLASSES = { image = true, video = true, audio = true,
                        pdf = true, file = true }

writer.HANDLERS.Figure = function(el)
  local class
  for _, c in ipairs(el.classes or {}) do
    if MEDIA_CLASSES[c] then class = c end
  end

  -- The URL lives on the inner Link (or Image), matching how the reader built it.
  local url
  local function find_url(inlines)
    for _, il in ipairs(inlines or {}) do
      if il.t == "Link" and not url then url = il.target end
      if il.t == "Image" and not url then url = il.src end
      if il.content then find_url(il.content) end
    end
  end
  for _, b in ipairs(el.content or {}) do
    if b.content then find_url(b.content) end
  end

  local caption = richtext.from_inlines(
    pandoc.utils.blocks_to_inlines((el.caption and el.caption.long) or {}))

  local payload = json.obj({ caption = caption })
  local upload_id = el.attributes and el.attributes["data-file-upload-id"] or nil
  if upload_id then
    payload.type = "file_upload"
    payload.file_upload = json.obj({ id = upload_id })
  else
    payload.type = "external"
    payload.external = json.obj({ url = url or "" })
  end
  return writer.block(class or "image", payload, el)
end

-- ---- line blocks ----------------------------------------------------------

-- Genuinely native, not a degradation: Notion renders a literal newline inside
-- text.content as a line break within one block.
writer.HANDLERS.LineBlock = function(el)
  local inlines = pandoc.Inlines({})
  for i, line in ipairs(el.content or {}) do
    if i > 1 then inlines:insert(pandoc.LineBreak()) end
    for _, il in ipairs(line) do inlines:insert(il) end
  end
  return writer.block("paragraph", json.obj({
    rich_text = richtext.from_inlines(inlines), color = "default" }), el)
end

-- ---- definition lists -----------------------------------------------------

writer.HANDLERS.DefinitionList = function(el)
  local out = json.arr()
  for _, entry in ipairs(el.content or {}) do
    local term, definitions = entry[1], entry[2]
    local children = json.arr()
    for _, definition in ipairs(definitions or {}) do
      for _, b in ipairs(writer.convert(definition)) do children:insert(b) end
    end
    local payload = json.obj({
      rich_text = richtext.from_inlines({ pandoc.Strong(term) }),
      color     = "default",
    })
    if #children > 0 then payload.children = children end
    out:insert(writer.block("paragraph", payload, nil))
  end
  return out
end

-- ---- raw blocks -----------------------------------------------------------

writer.HANDLERS.RawBlock = function(el)
  pandoc.log.info('Not rendering RawBlock (Format "' .. tostring(el.format) .. '")')
  return nil
end

return true
