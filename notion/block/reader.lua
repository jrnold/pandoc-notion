-- Notion block JSON -> pandoc Blocks. Regular types are driven from
-- schema.NOTION_INDEX; irregular ones are registered into CUSTOM by
-- reader_custom.lua (Task 8).
local json     = require "notion.block.json"
local schema   = require "notion.schema"
local richtext = require "notion.block.richtext"

local M = {}

-- Task 8 populates this. Keyed by Notion type -> function(block, payload) -> Blocks
M.CUSTOM = {}

-- Notion spells an icon three ways; the AST wants one string.
local function icon_value(icon)
  if type(icon) ~= "table" then return nil end
  local kind = json.get(icon, "type")
  if kind == "emoji" then
    local e = json.get(icon, "emoji")
    return e and tostring(e) or nil
  end
  local url = json.get(json.get(icon, kind or ""), "url")
  return url and tostring(url) or nil
end

-- Build the Attr for a block: id in the identifier slot (design doc 4.1),
-- declared fields as attributes, colour translated and omitted when default.
function M.attr_for(block, def, payload)
  local attributes = {}
  for jkey, akey in pairs((def and def.fields) or {}) do
    -- icon arrives as an object ({type="emoji",emoji="X"} or a file object);
    -- everything else declared in `fields` is already a scalar.
    local v = (jkey == "icon") and icon_value(json.get(payload, "icon"))
              or json.get(payload, jkey)
    if v ~= nil and type(v) ~= "table" then
      attributes[#attributes + 1] = { akey, tostring(v) }
    end
  end
  local color = json.color_to_ast(json.get(payload, "color"))
  if color then attributes[#attributes + 1] = { "color", color } end

  local id = json.get(block, "id")
  local classes = {}
  if def and def.class then classes[1] = def.class end
  return pandoc.Attr(id and tostring(id) or "", classes, attributes)
end

-- Children live in the type payload per the prose, and at the top level in
-- Notion's own example. Design doc 3.4 records the ambiguity; we accept both.
function M.children_of(block, payload)
  return json.get(payload, "children") or json.get(block, "children") or {}
end

-- Design doc 4.2: use a node's native Attr where pandoc has one; wrap in a
-- class-less, attribute-only Div only where it does not. A block with no
-- attributes is never wrapped, so ordinary content stays ordinary.
function M.wrap_color(element, color, id)
  if not color and (id == nil or id == "") then return element end
  local attributes = {}
  if color then attributes[#attributes + 1] = { "color", color } end
  return pandoc.Div({ element }, pandoc.Attr(id or "", {}, attributes))
end

local function unknown_block(block, type_name)
  local id = json.get(block, "id")
  return pandoc.Div({}, pandoc.Attr(id and tostring(id) or "", { "unknown" },
                                    { { "alt", tostring(type_name) } }))
end

-- Exposed on M (not a local) because reader_custom.lua's registrations and the
-- list-grouping pass in M.convert both dispatch through it.
function M.convert_block(block)
  local type_name = json.get(block, "type")
  if not type_name then
    pandoc.log.warn("Skipping block with no type: " ..
                    tostring(json.get(block, "id") or "<no id>"))
    return nil
  end
  type_name = tostring(type_name)
  local payload = json.get(block, type_name) or {}

  local custom = M.CUSTOM[type_name]
  if custom then return custom(block, payload) end

  local def = schema.NOTION_INDEX[type_name]
  if not def then return unknown_block(block, type_name) end

  -- A type flagged `custom` has no generic representation: its content lives
  -- in a shape the table-driven path cannot read. If its handler is missing,
  -- degrade to a visible `unknown` rather than a near-empty Div that silently
  -- discards code text, table structure, or a media source.
  if def.custom then return unknown_block(block, type_name) end

  -- Notion's own "unsupported" carries the real type in block_type.
  if type_name == "unsupported" then
    local real = json.get(payload, "block_type")
    return unknown_block(block, real or "unsupported")
  end

  local id      = json.get(block, "id")
  local color   = json.color_to_ast(json.get(payload, "color"))
  local inlines = def.rich_text and richtext.to_inlines(json.get(payload, "rich_text"))
                  or nil
  local kids    = def.children and M.convert(M.children_of(block, payload)) or nil

  if type_name == "paragraph" then
    local para = pandoc.Para(inlines or {})
    if kids and #kids > 0 then
      return pandoc.Div(pandoc.Blocks({ para }) .. kids,
                        pandoc.Attr(id and tostring(id) or "", {},
                                    color and { { "color", color } } or {}))
    end
    return M.wrap_color(para, color, id and tostring(id) or nil)
  end

  if type_name == "quote" then
    local body = pandoc.Blocks({ pandoc.Para(inlines or {}) })
    if kids then body = body .. kids end
    return M.wrap_color(pandoc.BlockQuote(body), color, id and tostring(id) or nil)
  end

  if type_name == "divider" then
    return M.wrap_color(pandoc.HorizontalRule(), color, id and tostring(id) or nil)
  end

  if type_name == "equation" then
    local expr = json.get(payload, "expression")
    return M.wrap_color(pandoc.Para({ pandoc.Math("DisplayMath", tostring(expr or "")) }),
                        color, id and tostring(id) or nil)
  end

  -- Everything else is a Div carrying its class and attributes.
  local content = pandoc.Blocks({})
  if inlines and #inlines > 0 then content:insert(pandoc.Plain(inlines)) end
  if kids then content = content .. kids end
  return pandoc.Div(content, M.attr_for(block, def, payload))
end

function M.convert(blocks)
  local out = pandoc.Blocks({})
  for _, block in ipairs(blocks or {}) do
    if type(block) == "table" then
      local converted = M.convert_block(block)
      if converted then
        if pandoc.utils.type(converted) == "Blocks" then
          out = out .. converted
        else
          out:insert(converted)
        end
      end
    end
  end
  return out
end

return M
