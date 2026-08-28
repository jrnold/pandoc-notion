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
