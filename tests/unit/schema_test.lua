local t = require "support.assert"
local schema = require "notion.schema"

-- block tags carry class and ordered attribute names
t.eq(schema.BLOCK_TAGS.callout.class, "callout", "callout class")
t.eq(schema.BLOCK_TAGS.callout.attrs, { "icon", "color" }, "callout attr order")
t.eq(schema.BLOCK_TAGS.details.class, "toggle", "<details> maps to the toggle class")

-- the two tags absent from the enhanced-markdown page but required by real pages
t.eq(schema.BLOCK_TAGS.unknown.class, "unknown", "<unknown> is in the vocabulary")
t.eq(schema.BLOCK_TAGS.unknown.attrs, { "url", "alt" }, "unknown attr order")
t.truthy(schema.BLOCK_TAGS.unknown.void, "<unknown> is self-closing")
t.eq(schema.BLOCK_TAGS["meeting-notes"].class, "meeting-notes", "<meeting-notes> exists")

-- toggle and toggle-heading are distinct classes, never shared
t.truthy(schema.class_to_tag("toggle") == "details", "toggle class belongs to <details>")
t.truthy(schema.class_to_tag("toggle-heading") == nil,
         "toggle-heading has no tag; it is built from a Header")

-- media
t.eq(schema.MEDIA_TAGS.video.class, "video", "video class")
t.eq(schema.MEDIA_TAGS.video.attrs, { "src", "color" }, "video attr order")
for _, tag in ipairs({ "audio", "video", "file", "pdf" }) do
  t.truthy(schema.MEDIA_TAGS[tag], tag .. " is a media tag")
end

-- mentions: all six, each with both classes available via class_to_tag
for _, tag in ipairs({ "mention-user", "mention-page", "mention-database",
                       "mention-data-source", "mention-agent", "mention-date" }) do
  t.truthy(schema.MENTION_TAGS[tag], tag .. " is a mention tag")
end

-- containers nest by tag balance
for _, tag in ipairs({ "callout", "details", "columns", "column", "table",
                       "synced_block", "synced_block_reference", "meeting-notes" }) do
  t.truthy(schema.CONTAINERS[tag], tag .. " is a container")
end
t.truthy(not schema.CONTAINERS.unknown, "self-closing tags are not containers")
t.truthy(not schema.CONTAINERS.page, "single-line tags are not containers")

-- reverse lookup is total over every declared class
local _, kind = schema.class_to_tag("video")
t.eq(kind, "media", "video reverses to a media tag")
local _, kind2 = schema.class_to_tag("mention-user")
t.eq(kind2, "mention", "mention-user reverses to a mention tag")

t.truthy(schema.is_known_tag("callout"), "callout is known")
t.truthy(not schema.is_known_tag("marquee"), "marquee is not")

-- Ruling F1: table structure tags are their own category (not BLOCK_TAGS),
-- but the scanner must still recognise them as known tags.
for _, tag in ipairs({ "table", "colgroup", "col", "tr", "td" }) do
  t.truthy(schema.TABLE_TAGS[tag], tag .. " is a table tag")
  t.truthy(schema.is_known_tag(tag), tag .. " is recognised by the scanner")
end
t.truthy(schema.class_to_tag("table") == nil, "table has no Div class mapping")

-- ---- Notion block-type axis (block-JSON design doc 4.3) ----

-- Reuse: these three fold onto classes the NFM pair already defines, which is
-- what keeps the new vocabulary at six classes instead of nine.
t.eq(schema.NOTION_INDEX.child_page.class, "page", "child_page reuses page")
t.eq(schema.NOTION_INDEX.child_database.class, "database",
     "child_database reuses database")
t.eq(schema.NOTION_INDEX.transcription.class, "meeting-notes",
     "transcription is a legacy alias of meeting_notes")
t.eq(schema.NOTION_INDEX.meeting_notes.class, "meeting-notes",
     "meeting_notes maps to the same class")

-- The six genuinely new classes.
for ntype, class in pairs({ bookmark = "bookmark", embed = "embed",
                            link_preview = "link-preview",
                            breadcrumb = "breadcrumb", template = "template",
                            tab = "tab" }) do
  t.eq(schema.NOTION_INDEX[ntype].class, class, ntype .. " has its own class")
end

-- JSON-only types must NOT leak into the NFM tag vocabulary, or the NFM
-- reader would start accepting <bookmark> as valid input.
for _, ntype in ipairs({ "bookmark", "embed", "link_preview", "breadcrumb",
                         "template", "tab" }) do
  t.truthy(not schema.is_known_tag(ntype), ntype .. " is not an NFM tag")
  t.truthy(not schema.BLOCK_TAGS[ntype], ntype .. " is not in BLOCK_TAGS")
end

-- Existing rows gained a notion coordinate.
t.eq(schema.NOTION_INDEX.callout.class, "callout", "callout indexed by type")
t.eq(schema.NOTION_INDEX.callout.fields.icon, "icon", "callout maps icon")
t.truthy(schema.NOTION_INDEX.callout.rich_text, "callout carries rich text")
t.truthy(schema.NOTION_INDEX.callout.children, "callout carries children")
t.truthy(not schema.NOTION_INDEX.divider.rich_text, "divider carries no rich text")

-- Irregular types are flagged for hand-written conversion.
for _, ntype in ipairs({ "table", "table_row", "column_list", "column",
                         "heading_1", "heading_2", "heading_3", "heading_4",
                         "bulleted_list_item", "numbered_list_item", "to_do",
                         "image", "video", "audio", "pdf", "file",
                         "synced_block", "code" }) do
  t.truthy(schema.NOTION_INDEX[ntype], ntype .. " is indexed")
  t.truthy(schema.NOTION_INDEX[ntype].custom, ntype .. " is hand-written")
end

-- Every one of the 37 documented types resolves (design doc 3.1).
local ALL_TYPES = {
  "audio", "bookmark", "breadcrumb", "bulleted_list_item", "callout",
  "child_database", "child_page", "code", "column", "column_list", "divider",
  "embed", "equation", "file", "heading_1", "heading_2", "heading_3",
  "heading_4", "image", "link_preview", "meeting_notes", "mention",
  "numbered_list_item", "paragraph", "pdf", "quote", "synced_block", "tab",
  "table", "table_of_contents", "table_row", "template", "to_do", "toggle",
  "transcription", "unsupported", "video",
}
t.eq(#ALL_TYPES, 37, "the documented type list is 37 long")
for _, ntype in ipairs(ALL_TYPES) do
  t.truthy(schema.NOTION_INDEX[ntype], ntype .. " is present in NOTION_INDEX")
end

-- Reverse lookup.
t.eq(schema.class_to_notion("callout"), "callout", "callout reverses")
t.eq(schema.class_to_notion("link-preview"), "link_preview", "link-preview reverses")
t.eq(schema.class_to_notion("nonsense"), nil, "unknown class reverses to nil")

-- meeting_notes and transcription both claim the "meeting-notes" class, so the
-- reverse lookup is order-dependent without the explicit pin. This is the only
-- real collision in NOTION_INDEX; assert it resolves to the canonical type.
t.eq(schema.class_to_notion("meeting-notes"), "meeting_notes",
     "meeting-notes reverses to the canonical type, not transcription")
