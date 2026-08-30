-- pandoc Blocks -> Notion block JSON. Output is a deliberately FORGIVING
-- superset of the API shape: no limit enforcement, no chunking, no
-- nesting-depth check (design doc 8.2). An uploading script owns all of that.
local json     = require "notion.block.json"
local schema   = require "notion.schema"
local richtext = require "notion.block.richtext"

local M = {}

local options = { preserve_ids = false }

function M.set_options(o)
  options.preserve_ids = (o or {}).preserve_ids == true
end

-- Task 11 extends this.
M.HANDLERS = {}

function M.color_of(element)
  local attributes = element and element.attributes or nil
  return json.color_to_notion(attributes and attributes.color or nil)
end

function M.block(type_name, payload, element)
  local out = json.obj({
    object = "block",
    type   = type_name,
    [type_name] = payload,
  })
  if options.preserve_ids and element and element.identifier
     and element.identifier ~= "" then
    out.id = element.identifier
  end
  return out
end

local function rich(inlines)
  return richtext.from_inlines(inlines or {})
end

-- Split a Div's content into leading inline content (which becomes rich_text)
-- and the remaining blocks (which become children).
local function split_content(blocks)
  local head, rest = nil, pandoc.Blocks({})
  for i, b in ipairs(blocks or {}) do
    if i == 1 and (b.t == "Plain" or b.t == "Para") then
      head = b.content
    else
      rest:insert(b)
    end
  end
  return head, rest
end

-- The checkbox convention pandoc's task_lists extension defines.
local CHECKED, UNCHECKED = "\u{2612}", "\u{2610}"

local function todo_state(inlines)
  local first = inlines and inlines[1] or nil
  if not first or first.t ~= "Str" then return nil, inlines end
  if first.text ~= CHECKED and first.text ~= UNCHECKED then return nil, inlines end
  local rest = pandoc.Inlines({})
  for i = 2, #inlines do
    if not (i == 2 and inlines[i].t == "Space") then rest:insert(inlines[i]) end
  end
  return first.text == CHECKED, rest
end

local function item_blocks(item, ordered, start_index)
  local head, rest = split_content(item)
  local checked, inlines = todo_state(head)
  local type_name = ordered and "numbered_list_item"
                    or (checked ~= nil and "to_do" or "bulleted_list_item")

  local payload = json.obj({ rich_text = rich(inlines or head), color = "default" })
  if checked ~= nil then payload.checked = checked end
  if ordered and start_index then payload.list_start_index = start_index end
  local children = M.convert(rest)
  if #children > 0 then payload.children = children end
  return M.block(type_name, payload, nil)
end

-- ---- Div class dispatch ---------------------------------------------------

local VOID_CLASSES = {
  breadcrumb = "breadcrumb", ["table-of-contents"] = "table_of_contents",
  tab = "tab", template = "template",
}

local function div_handler(el)
  local classes = el.classes or {}

  -- A class-less Div means one of two things, distinguished by child count:
  --   exactly one child  -> the colour wrapper of design doc 4.2
  --   more than one      -> a parent block with children, which is how BOTH
  --                         this reader and the NFM reader represent a
  --                         paragraph that has nested content. Verified:
  --                         "Parent\n\tChild" through the NFM reader yields
  --                         Div ("",[],[]) [Para, Para].
  -- Flattening the multi-child case would silently drop the nesting.
  if #classes == 0 then
    local color = M.color_of(el)
    local inner = M.convert(el.content)
    if #inner <= 1 then
      if color ~= "default" then
        for _, b in ipairs(inner) do
          if type(b[b.type]) == "table" then b[b.type].color = color end
        end
      end
      return inner
    end
    local parent = inner:remove(1)
    if color ~= "default" and type(parent[parent.type]) == "table" then
      parent[parent.type].color = color
    end
    if type(parent[parent.type]) == "table" then
      parent[parent.type].children = inner
    end
    return parent
  end

  local class = classes[1]
  local head, rest = split_content(el.content)

  -- toggle-heading wraps a Header plus the children a Header cannot hold.
  -- The children belong INSIDE the heading's payload, not beside it.
  if class == "toggle-heading" then
    local converted = M.convert(el.content)
    if #converted == 0 then return converted end
    local heading = converted:remove(1)
    if #converted > 0 and type(heading[heading.type]) == "table" then
      heading[heading.type].children = converted
    end
    return heading
  end

  if class == "synced-block" or class == "synced-block-reference" then
    local from = pandoc.json.null
    if class == "synced-block-reference" then
      from = json.obj({ type = "block_id", block_id = el.attributes.url or "" })
    end
    return M.block("synced_block", json.obj({
      synced_from = from, children = M.convert(el.content) }), el)
  end

  if class == "unknown" then
    return M.block("unsupported", json.obj({
      block_type = el.attributes.alt or "unsupported" }), el)
  end

  if VOID_CLASSES[class] then
    local payload = json.obj({})
    if class == "table-of-contents" then payload.color = M.color_of(el) end
    if class == "template" or class == "tab" then
      local kids = M.convert(el.content)
      if #kids > 0 then payload.children = kids end
      if class == "template" then payload.rich_text = rich(head) end
    end
    return M.block(VOID_CLASSES[class], payload, el)
  end

  local ntype = schema.class_to_notion(class)
  if not ntype then
    -- Design doc 8: an unrecognized class is unwrapped, its children kept.
    return M.convert(el.content)
  end

  local def = schema.NOTION_INDEX[ntype] or {}
  local payload = json.obj({})

  for jkey, akey in pairs(def.fields or {}) do
    local v = el.attributes[akey]
    if v ~= nil then
      if jkey == "icon" then
        payload.icon = json.obj({ type = "emoji", emoji = v })
      else
        payload[jkey] = v
      end
    end
  end

  if class == "bookmark" or class == "embed" or class == "link-preview" then
    payload.url = el.attributes.url or ""
    if class == "bookmark" then payload.caption = rich(head) end
    return M.block(ntype, payload, el)
  end

  -- column carries width_ratio, which has no `fields` entry because it needs
  -- numeric conversion rather than a straight string copy.
  if class == "column" then
    local ratio = el.attributes["width-ratio"]
    if ratio then payload.width_ratio = tonumber(ratio) or ratio end
    payload.children = M.convert(el.content)
    return M.block(ntype, payload, el)
  end

  if def.rich_text then payload.rich_text = rich(head) end
  payload.color = M.color_of(el)

  local kids = M.convert(def.rich_text and rest or el.content)
  if #kids > 0 then payload.children = kids end
  return M.block(ntype, payload, el)
end

-- ---- handlers -------------------------------------------------------------

M.HANDLERS.Para = function(el)
  return M.block("paragraph",
                 json.obj({ rich_text = rich(el.content), color = "default" }), el)
end
M.HANDLERS.Plain = M.HANDLERS.Para

M.HANDLERS.Header = function(el)
  local level = math.min(el.level or 1, 4)   -- H5/H6 clamp, matching NFM
  local payload = json.obj({
    rich_text = rich(el.content),
    color     = M.color_of(el),
    is_toggleable = el.attributes.toggle == "true",
  })
  return M.block("heading_" .. level, payload, el)
end

M.HANDLERS.BlockQuote = function(el)
  local head, rest = split_content(el.content)
  local payload = json.obj({ rich_text = rich(head), color = "default" })
  local kids = M.convert(rest)
  if #kids > 0 then payload.children = kids end
  return M.block("quote", payload, el)
end

M.HANDLERS.HorizontalRule = function(el)
  return M.block("divider", json.obj({}), el)
end

M.HANDLERS.CodeBlock = function(el)
  local language = (el.classes or {})[1] or "plain text"
  -- The reader stores a code block's caption as an attribute, since pandoc's
  -- CodeBlock has no caption slot. Emit it back, or it is silently dropped.
  local caption_text = el.attributes and el.attributes.caption or nil
  local caption = caption_text
                  and richtext.from_inlines({ pandoc.Str(caption_text) })
                  or json.arr()
  return M.block("code", json.obj({
    rich_text = richtext.from_inlines({ pandoc.Str(el.text) }),
    language  = language,
    caption   = caption,
  }), el)
end

M.HANDLERS.BulletList = function(el)
  local out = json.arr()
  for _, item in ipairs(el.content) do out:insert(item_blocks(item, false, nil)) end
  return out
end

M.HANDLERS.OrderedList = function(el)
  local out = json.arr()
  local start_index = el.listAttributes and el.listAttributes.start or 1
  for i, item in ipairs(el.content) do
    out:insert(item_blocks(item, true, i == 1 and start_index or nil))
  end
  return out
end

M.HANDLERS.Div = div_handler

function M.convert(blocks)
  local out = json.arr()
  for _, el in ipairs(blocks or {}) do
    local handler = M.HANDLERS[el.t]
    if handler then
      local produced = handler(el)
      if produced == nil then
        -- deliberately dropped
      elseif produced.object == "block" then
        out:insert(produced)
      else
        for _, b in ipairs(produced) do out:insert(b) end
      end
    end
  end
  return out
end

return M
