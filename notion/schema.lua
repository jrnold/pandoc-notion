local M = {}

-- Multi-line containers: these nest by tag balance rather than by indentation.
M.CONTAINERS = {}
for _, tag in ipairs({ "callout", "details", "summary", "columns", "column",
                       "table", "colgroup", "col", "tr", "td", "synced_block",
                       "synced_block_reference", "meeting-notes" }) do
  M.CONTAINERS[tag] = true
end

-- tag -> Div class plus the attribute order used when rendering back to NFM.
M.BLOCK_TAGS = {
  callout                = { class = "callout",                attrs = { "icon", "color" } },
  details                = { class = "toggle",                 attrs = { "color" } },
  summary                = { class = "summary",                attrs = {} },
  columns                = { class = "columns",                attrs = {} },
  column                 = { class = "column",                 attrs = {} },
  synced_block           = { class = "synced-block",           attrs = { "url" } },
  synced_block_reference = { class = "synced-block-reference", attrs = { "url" } },
  ["meeting-notes"]      = { class = "meeting-notes",          attrs = {} },
  page                   = { class = "page",                   attrs = { "url", "color" } },
  database               = { class = "database",               attrs = { "url", "inline", "icon", "color" } },
  table_of_contents      = { class = "table-of-contents",      attrs = { "color" }, void = true },
  ["empty-block"]        = { class = "empty-block",            attrs = {},          void = true },
  unknown                = { class = "unknown",                attrs = { "url", "alt" }, void = true },
}

-- Media blocks render as Figure with a type class.
M.MEDIA_TAGS = {
  audio = { class = "audio", attrs = { "src", "color" } },
  video = { class = "video", attrs = { "src", "color" } },
  file  = { class = "file",  attrs = { "src", "color" } },
  pdf   = { class = "pdf",   attrs = { "src", "color" } },
}

-- Mentions render as Span with classes {"mention", "mention-<kind>"}.
M.MENTION_TAGS = {
  ["mention-user"]        = { class = "mention-user",        attrs = { "url" } },
  ["mention-page"]        = { class = "mention-page",        attrs = { "url" } },
  ["mention-database"]    = { class = "mention-database",    attrs = { "url" } },
  ["mention-data-source"] = { class = "mention-data-source", attrs = { "url" } },
  ["mention-agent"]       = { class = "mention-agent",       attrs = { "url" } },
  ["mention-date"]        = { class = "mention-date",
                              attrs = { "start", "end", "startTime", "timeZone" } },
}

-- Table structure tags. These become native pandoc Table/Row/Cell rather than
-- Div, so they are their own category rather than BLOCK_TAGS entries -- but
-- the line scanner must still recognise them as tags.
M.TABLE_TAGS = {}
for _, tag in ipairs({ "table", "colgroup", "col", "tr", "td" }) do
  M.TABLE_TAGS[tag] = true
end

-- Reverse lookups, built once at load.
local reverse = {}
for tag, def in pairs(M.BLOCK_TAGS)   do reverse[def.class] = { tag, "block"   } end
for tag, def in pairs(M.MEDIA_TAGS)   do reverse[def.class] = { tag, "media"   } end
for tag, def in pairs(M.MENTION_TAGS) do reverse[def.class] = { tag, "mention" } end

function M.class_to_tag(class)
  local hit = reverse[class]
  if not hit then return nil, nil end
  return hit[1], hit[2]
end

function M.is_known_tag(tag)
  if M.TABLE_TAGS[tag] then return true end
  return (M.BLOCK_TAGS[tag] or M.MEDIA_TAGS[tag] or M.MENTION_TAGS[tag]) ~= nil
end

-- ---------------------------------------------------------------------------
-- Notion block-type axis (block-JSON design doc 4.3).
--
-- This is the third coordinate: NFM tag <-> pandoc class <-> Notion type.
-- Types with no NFM tag live in their own table rather than BLOCK_TAGS, so
-- that is_known_tag() does not start accepting <bookmark> as valid NFM.
-- ---------------------------------------------------------------------------

-- Notion types that have no NFM tag at all.
M.NOTION_BLOCKS = {
  bookmark     = { class = "bookmark",     fields = { url = "url" } },
  embed        = { class = "embed",        fields = { url = "url" } },
  link_preview = { class = "link-preview", fields = { url = "url" } },
  breadcrumb   = { class = "breadcrumb",   fields = {} },
  template     = { class = "template",     fields = {}, rich_text = true,
                   children = true },
  tab          = { class = "tab",          fields = {}, children = true },
}

-- Notion type -> { class, fields, rich_text, children, custom }.
-- `fields` maps a JSON payload key to an AST attribute name.
-- `custom` marks a type whose structure needs a hand-written converter.
M.NOTION_INDEX = {
  -- regular, table-driven
  paragraph         = { class = nil,                  fields = {}, rich_text = true, children = true },
  quote             = { class = nil,                  fields = {}, rich_text = true, children = true },
  divider           = { class = nil,                  fields = {} },
  equation          = { class = nil,                  fields = {} },
  callout           = { class = "callout",            fields = { icon = "icon" }, rich_text = true, children = true },
  toggle            = { class = "toggle",             fields = {}, rich_text = true, children = true },
  table_of_contents = { class = "table-of-contents",  fields = {} },
  meeting_notes     = { class = "meeting-notes",      fields = {}, children = true },
  transcription     = { class = "meeting-notes",      fields = {}, children = true },
  child_page        = { class = "page",               fields = { title = "title" } },
  child_database    = { class = "database",           fields = { title = "title" } },
  unsupported       = { class = "unknown",            fields = { block_type = "alt" } },
  mention           = { class = nil,                  fields = {}, custom = true },

  -- irregular, hand-written (Tasks 8 and 11)
  heading_1          = { class = nil,          fields = {}, custom = true },
  heading_2          = { class = nil,          fields = {}, custom = true },
  heading_3          = { class = nil,          fields = {}, custom = true },
  heading_4          = { class = nil,          fields = {}, custom = true },
  bulleted_list_item = { class = nil,          fields = {}, custom = true },
  numbered_list_item = { class = nil,          fields = {}, custom = true },
  to_do              = { class = nil,          fields = {}, custom = true },
  code               = { class = nil,          fields = {}, custom = true },
  table              = { class = nil,          fields = {}, custom = true },
  table_row          = { class = nil,          fields = {}, custom = true },
  column_list        = { class = "columns",    fields = {}, custom = true },
  column             = { class = "column",     fields = {}, custom = true },
  synced_block       = { class = "synced-block", fields = {}, custom = true },
  image              = { class = "image",      fields = {}, custom = true },
  video              = { class = "video",      fields = {}, custom = true },
  audio              = { class = "audio",      fields = {}, custom = true },
  pdf                = { class = "pdf",        fields = {}, custom = true },
  file               = { class = "file",       fields = {}, custom = true },
}

-- Fold the NFM-less types in.
for ntype, def in pairs(M.NOTION_BLOCKS) do
  M.NOTION_INDEX[ntype] = {
    class     = def.class,
    fields    = def.fields,
    rich_text = def.rich_text,
    children  = def.children,
  }
end

local notion_reverse = {}
for ntype, def in pairs(M.NOTION_INDEX) do
  -- child_page/child_database/transcription deliberately share a class with
  -- another type; the first-listed canonical spelling wins the reverse.
  if def.class and not notion_reverse[def.class] then
    notion_reverse[def.class] = ntype
  end
end
-- Pin the reverse for the three shared-class pairs, so a writer emitting a
-- `page` Div produces child_page rather than whichever pairs() reached first.
notion_reverse["page"]          = "child_page"
notion_reverse["database"]      = "child_database"
notion_reverse["meeting-notes"] = "meeting_notes"
notion_reverse["synced-block"]  = "synced_block"

function M.class_to_notion(class)
  return notion_reverse[class]
end

return M
