local t     = require "support.assert"
local props = require "notion.block.props"

local function text_run(s)
  return { type = "text", text = { content = s }, annotations = {}, plain_text = s }
end

local meta = props.to_meta({
  title        = { type = "title",        title = { text_run("Q3 Roadmap") } },
  Notes        = { type = "rich_text",    rich_text = { text_run("hello") } },
  Score        = { type = "number",       number = 87 },
  Ratio        = { type = "number",       number = 1.5 },
  Status       = { type = "select",       select = { name = "In progress" } },
  Stage        = { type = "status",       status = { name = "Doing" } },
  Tags         = { type = "multi_select", multi_select = { { name = "a" }, { name = "b" } } },
  Owner        = { type = "people",       people = { { name = "Ada L." } } },
  Linked       = { type = "relation",     relation = { { id = "p-1" }, { id = "p-2" } } },
  Due          = { type = "date",         date = { start = "2026-09-30" } },
  Window       = { type = "date",         date = { start = "2026-09-01", ["end"] = "2026-09-30" } },
  Done         = { type = "checkbox",     checkbox = false },
  Site         = { type = "url",          url = "https://example.com" },
  Mail         = { type = "email",        email = "a@example.com" },
  Phone        = { type = "phone_number", phone_number = "+15551234" },
  Attachments  = { type = "files",        files = {
                     { name = "a.pdf", type = "external", external = { url = "https://e.com/a.pdf" } },
                     { name = "b.png", type = "file",     file = { url = "https://s3/b.png" } } } },
  Computed     = { type = "formula",      formula = { type = "string", string = "yes" } },
  Total        = { type = "rollup",       rollup = { type = "number", number = 12 } },
  Created      = { type = "created_time", created_time = "2026-08-01T00:00:00.000Z" },
  Author       = { type = "created_by",   created_by = { name = "Ada L." } },
  Mystery      = { type = "future_type",  future_type = { whatever = 1 } },
})

t.eq(pandoc.utils.stringify(meta.title), "Q3 Roadmap", "title becomes MetaInlines")
t.eq(pandoc.utils.stringify(meta.Notes), "hello", "rich_text becomes MetaInlines")
t.eq(meta.Score, "87", "an integral number has no decimal part")
t.eq(meta.Ratio, "1.5", "a fractional number keeps it")
t.eq(meta.Status, "In progress", "select uses .name")
t.eq(meta.Stage, "Doing", "status uses .name")
t.eq(meta.Tags, { "a", "b" }, "multi_select becomes a list of names")
t.eq(meta.Owner, { "Ada L." }, "people becomes a list of names")
t.eq(meta.Linked, { "p-1", "p-2" }, "relation becomes a list of ids")
t.eq(meta.Due, "2026-09-30", "a single date is its start")
t.eq(meta.Window, "2026-09-01/2026-09-30", "a ranged date is start/end")
t.eq(meta.Done, false, "checkbox becomes a boolean")
t.eq(meta.Site, "https://example.com", "url passes through")
t.eq(meta.Mail, "a@example.com", "email passes through")
t.eq(meta.Phone, "+15551234", "phone_number passes through")
t.eq(meta.Attachments, { "https://e.com/a.pdf", "https://s3/b.png" },
     "files becomes a list of URLs regardless of hosting")
t.eq(meta.Computed, "yes", "formula resolves to its value")
t.eq(meta.Total, "12", "rollup resolves to its value")
t.eq(meta.Created, "2026-08-01T00:00:00.000Z", "timestamps pass through")
t.eq(meta.Author, "Ada L.", "created_by uses .name")
t.eq(meta.Mystery, nil, "an unrecognized property type is skipped, not fatal")

-- Empty and null inputs must not crash.
t.eq(props.to_meta({}), {}, "no properties yields no meta")
t.eq(props.to_meta(nil), {}, "absent properties yields no meta")
t.eq(props.to_meta({ Empty = { type = "select", select = pandoc.json.null } }).Empty, nil,
     "a null property value is skipped")

-- A title property under a non-"title" key still populates Meta.title, since
-- Notion names the title column whatever the database calls it.
local named = props.to_meta({ Name = { type = "title", title = { text_run("Doc") } } })
t.eq(pandoc.utils.stringify(named.title), "Doc", "the title property also lands on Meta.title")
t.eq(pandoc.utils.stringify(named.Name), "Doc", "and keeps its own name")
