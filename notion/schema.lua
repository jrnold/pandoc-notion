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

return M
