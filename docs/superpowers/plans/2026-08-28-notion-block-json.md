# Notion Block JSON Reader/Writer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a pandoc custom Lua reader and writer that convert Notion's block object JSON to and from the pandoc AST, targeting the same shared AST convention the NFM pair already uses.

**Architecture:** Both directions dispatch through the existing `notion/schema.lua`, extended with a third coordinate (the Notion block type) so a construct's spelling cannot drift between the three vocabularies. Regular container types are table-driven from that schema; structurally irregular types (tables, columns, headings, lists, media) get hand-written converters. Notion's rich text is a *flat* list of annotated runs while pandoc's is a *nested* tree, so a single module owns both halves of that inverse conversion.

**Tech Stack:** Lua 5.4 (pandoc's bundled interpreter), pandoc 3.10.2 custom reader/writer API, `pandoc.json`, no external dependencies. Tests run via `pandoc lua tests/run.lua`.

**Spec:** `docs/superpowers/specs/2026-08-28-notion-block-json-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **pandoc 3.10.2 or later**, Lua 5.4, `PANDOC_API_VERSION` 1.23.1.2. Re-verify spec §2 if the version moves.
- **Zero external dependencies.** No luarocks, no busted. The only interpreter is `pandoc lua`.
- **Every JSON array is a `pandoc.List`, never a bare table.** `pandoc.json.encode({})` emits `{}` (an object); only `pandoc.json.encode(pandoc.List{})` emits `[]`. Construct every array through `json.arr()`. This is spec §2.1 and it is the one mistake no type system catches.
- **Every optional field is compared against `pandoc.json.null`, never tested for truthiness.** `null` decodes to a truthy userdata singleton, so `if b.caption then` is true when `caption` is `null`. Read every field through `json.get()`. Spec §2.4.
- **`pandoc.json.decode` returns `nil` on malformed input and never raises.** `pcall` around it is useless. Spec §2.3.
- **Colors:** the AST uses NFM's `_bg` spelling; Notion uses `_background`; `"default"` means the attribute is omitted entirely. Translate at the JSON boundary only, via `json.color_to_ast` / `json.color_to_notion`. Spec §4.2.
- **Canonical rich-text wrapper order**, outermost to innermost: `Link`, `Span(color)`, `Strong`, `Emph`, `Underline`, `Strikeout`, `Code`. `Code` is innermost by type constraint — it holds a string, not inlines. Spec §4.4.
- **Round-trip direction:** assert `JSON → AST → JSON` only. `AST → JSON` is many-to-one and the reverse assertion would chase a bug that does not exist. Spec §2.7.
- **No API-limit enforcement.** No splitting long runs, no warnings on oversized arrays, no nesting-depth checks. Output is a deliberately forgiving superset. Spec §8.2.
- **`Meta` is read-only.** The writer ignores it and emits a bare block array. Spec §4.6.
- **Block `id` goes in the `Attr` identifier slot**; all other server-owned metadata is dropped. Writer omits `id` by default. Spec §4.1.
- **Exactly two fatal paths**, both at the outer boundary: unparseable JSON, and an unrecognized envelope. Everything inside a recognized envelope is recovered, never fatal. Spec §6.5.
- **Degradation is silent** at default verbosity. `pandoc.log.info` only when content is genuinely dropped.
- **Do not modify NFM behavior.** The existing 866 tests must still pass after every task. New JSON-only block types go in a separate schema table so `is_known_tag` does not start accepting `<bookmark>` as NFM.
- **Commit after every task.** Conventional commit format (`feat:`, `test:`, `fix:`, `docs:`).

## File Structure

```
notion-block-reader.lua        entry: Reader(input, opts) — prelude + wiring only
notion-block-writer.lua        entry: Writer(doc, opts)   — prelude + wiring only
notion/
  schema.lua        MODIFIED: gains NOTION_BLOCKS + NOTION_INDEX (the third axis)
  attr.lua          unchanged
  escape.lua        unchanged — NFM-only; this pair never escapes
  block/
    json.lua        array/object discipline, null guards, decode, color normalizer
    envelope.lua    bare array | list response | page object → blocks + page
    richtext.lua    rich_text[] ↔ Inlines, both directions
    props.lua       page properties → Meta
    reader.lua      JSON blocks → pandoc Blocks
    writer.lua      pandoc Blocks → JSON blocks
tests/
  support/blockjson.lua   helpers that shell out to pandoc for the block pair
  unit/block_*_test.lua   per-module unit suites
  corpus/json/**          JSON fixtures (round-trip + AST goldens)
  golden/json/**          expected .native output
  crosspair_test.lua      NFM → JSON → NFM, the shared-AST assertion
```

**Task dependency order:** 1 → 2 are foundations that everything imports. 3 → 4 are the rich-text inverse pair. 5 → 6 are small independent leaf modules. 7 → 9 build the reader. 10 → 12 build the writer. 13 → 14 are cross-cutting verification requiring both directions.

**Running one suite** (used throughout; the full runner is `pandoc lua tests/run.lua`):

```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_json_test"; os.exit(require("support.assert").report())'
```

---

### Task 1: `notion/block/json.lua` — array/object discipline and null guards

This module exists because two `pandoc.json` behaviors produce silent, non-local failures: a bare `{}` encodes as a JSON *object* where Notion requires an array, and `null` decodes to a *truthy* userdata. Centralizing both means each trap has one owner and one test.

**Files:**
- Create: `notion/block/json.lua`
- Create: `tests/unit/block_json_test.lua`
- Modify: `tests/run.lua` (register the new suite)

**Interfaces:**
- Consumes: nothing (this is the base layer).
- Produces:
  - `json.arr(t?) -> pandoc.List` — a JSON array; `t` optional initial items
  - `json.obj(t?) -> table` — a JSON object
  - `json.get(t, key) -> value|nil` — `nil` for missing *and* for `pandoc.json.null`
  - `json.decode_or_diagnose(text) -> value` — raises on unparseable input
  - `json.encode(v) -> string`
  - `json.color_to_ast(c) -> string|nil` — `"default"`/`nil` → `nil`, `"blue_background"` → `"blue_bg"`
  - `json.color_to_notion(c) -> string` — `nil` → `"default"`, `"blue_bg"` → `"blue_background"`

- [ ] **Step 1: Write the failing test**

Create `tests/unit/block_json_test.lua`:

```lua
local t = require "support.assert"
local json = require "notion.block.json"

-- Spec 2.1: the array/object distinction is invisible in Lua and fatal in Notion.
t.eq(json.encode(json.arr()), "[]", "empty array encodes as []")
t.eq(json.encode(json.obj()), "{}", "empty object encodes as {}")
t.eq(json.encode(json.arr({ 1, 2 })), "[1,2]", "array with items")
t.eq(json.encode(json.obj({ a = 1 })), '{"a":1}', "object with keys")

-- An array nested inside an object must still be an array.
t.eq(json.encode(json.obj({ rich_text = json.arr() })), '{"rich_text":[]}',
     "nested empty array stays an array")

-- Spec 2.4: null is truthy userdata, so get() must return nil for it.
local decoded = json.decode_or_diagnose('{"a":null,"b":1}')
t.truthy(decoded.a ~= nil, "raw null is present and truthy")
t.eq(json.get(decoded, "a"), nil, "get() returns nil for null")
t.eq(json.get(decoded, "b"), 1, "get() returns real values")
t.eq(json.get(decoded, "missing"), nil, "get() returns nil for absent keys")
t.eq(json.get(nil, "a"), nil, "get() tolerates a nil container")

-- Spec 2.3: decode returns nil rather than raising; we must raise ourselves.
local ok, err = pcall(json.decode_or_diagnose, "{bad")
t.truthy(not ok, "malformed JSON raises")
t.truthy(tostring(err):find("{bad", 1, true), "the diagnostic quotes the input")
local ok2 = pcall(json.decode_or_diagnose, "")
t.truthy(not ok2, "empty input raises")

-- Spec 4.2: colour spelling differs between NFM and the API.
t.eq(json.color_to_ast("default"), nil, "default means no attribute")
t.eq(json.color_to_ast(nil), nil, "absent means no attribute")
t.eq(json.color_to_ast("blue"), "blue", "plain hues pass through")
t.eq(json.color_to_ast("blue_background"), "blue_bg", "_background becomes _bg")
t.eq(json.color_to_notion(nil), "default", "no attribute means default")
t.eq(json.color_to_notion("blue"), "blue", "plain hues pass through")
t.eq(json.color_to_notion("blue_bg"), "blue_background", "_bg becomes _background")

-- Round trip over every legal colour.
for _, hue in ipairs({ "gray", "brown", "orange", "yellow", "green",
                       "blue", "purple", "pink", "red" }) do
  t.eq(json.color_to_ast(json.color_to_notion(hue)), hue, hue .. " round-trips")
  t.eq(json.color_to_ast(json.color_to_notion(hue .. "_bg")), hue .. "_bg",
       hue .. "_bg round-trips")
end
```

- [ ] **Step 2: Register the suite and run it to verify it fails**

In `tests/run.lua`, add `"unit.block_json_test",` to the `suites` list, immediately after `"unit.schema_test",`.

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_json_test"; os.exit(require("support.assert").report())'
```
Expected: FAIL with `module 'notion.block.json' not found`.

- [ ] **Step 3: Write the implementation**

Create `notion/block/json.lua`:

```lua
-- Central owner of the two pandoc.json behaviours that fail silently and
-- non-locally (design doc 2.1 and 2.4):
--   * a bare {} encodes as a JSON object, where Notion requires an array
--   * null decodes to a TRUTHY userdata singleton
-- Every array in this project is built with arr(); every optional field is
-- read through get().
local M = {}

local pjson = pandoc.json

-- A JSON array. Must be a pandoc.List: a plain table encodes as {}.
function M.arr(t)
  return pandoc.List(t or {})
end

-- A JSON object. A plain table is correct here.
function M.obj(t)
  return t or {}
end

-- Field access that treats JSON null exactly like an absent key.
function M.get(t, key)
  if type(t) ~= "table" then return nil end
  local v = t[key]
  if v == nil or v == pjson.null then return nil end
  return v
end

function M.encode(v)
  return pjson.encode(v)
end

-- pandoc.json.decode returns nil on malformed input and never raises, so a
-- pcall around it is useless -- the nil must be checked for here, or the
-- failure resurfaces much later as something unrelated.
function M.decode_or_diagnose(text)
  local value = pjson.decode(text)
  if value == nil then
    local head = tostring(text):sub(1, 80)
    error("notion-block-reader: input is not valid JSON, starting: " .. head, 0)
  end
  return value
end

-- Colour spelling differs between the two formats. The shared AST keeps NFM's
-- form; this pair translates at its own boundary. "default" is spelled as the
-- absence of the attribute.
function M.color_to_ast(c)
  if c == nil or c == pjson.null or c == "default" then return nil end
  local hue = tostring(c):match("^(.*)_background$")
  if hue then return hue .. "_bg" end
  return tostring(c)
end

function M.color_to_notion(c)
  if c == nil or c == "" then return "default" end
  local hue = tostring(c):match("^(.*)_bg$")
  if hue then return hue .. "_background" end
  return tostring(c)
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_json_test"; os.exit(require("support.assert").report())'
```
Expected: PASS, `28 passed, 0 failed`.

Then confirm nothing regressed:
```bash
pandoc lua tests/run.lua
```
Expected: `894 passed, 0 failed` (866 existing + 28 new).

- [ ] **Step 5: Commit**

```bash
git add notion/block/json.lua tests/unit/block_json_test.lua tests/run.lua
git commit -m "feat(block): add json.lua owning array/object and null discipline"
```

---

### Task 2: Extend `notion/schema.lua` with the Notion block-type axis

The schema becomes the single index over all three vocabularies. JSON-only types go in their **own table**, not in `BLOCK_TAGS`, so the NFM reader does not start accepting `<bookmark>` as valid NFM.

**Files:**
- Modify: `notion/schema.lua` (append; do not alter existing tables' contents)
- Modify: `tests/unit/schema_test.lua` (append new assertions)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `schema.NOTION_BLOCKS` — table keyed by Notion type, for types with no NFM tag
  - `schema.NOTION_INDEX` — table keyed by Notion type → `{ class, fields, rich_text, children, custom }`
  - `schema.class_to_notion(class) -> string|nil`

`fields` maps a JSON payload key to an AST attribute name. `custom = true` marks a type whose structure is irregular enough to need a hand-written converter (Tasks 8 and 11).

- [ ] **Step 1: Write the failing test**

Append to `tests/unit/schema_test.lua`:

```lua
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
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.schema_test"; os.exit(require("support.assert").report())'
```
Expected: FAIL with `attempt to index a nil value (field 'NOTION_INDEX')`.

- [ ] **Step 3: Write the implementation**

Append to `notion/schema.lua`, immediately **before** the final `return M`:

```lua
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.schema_test"; os.exit(require("support.assert").report())'
```
Expected: PASS.

Then the full suite, confirming the NFM side is untouched:
```bash
pandoc lua tests/run.lua
```
Expected: all pass, count increased by the new schema assertions.

- [ ] **Step 5: Commit**

```bash
git add notion/schema.lua tests/unit/schema_test.lua
git commit -m "feat(schema): add the Notion block-type axis"
```

---

### Task 3: `notion/block/richtext.lua` — flat → nested (read direction)

Notion stores style as a property of each character run; pandoc stores it as containment. This half coalesces adjacent runs with identical annotations, then wraps each in the canonical order. Coalescing is not cosmetic: Notion splits runs at arbitrary points, so without it the output depends on a page's edit history.

**Files:**
- Create: `notion/block/richtext.lua`
- Create: `tests/unit/block_richtext_test.lua`
- Modify: `tests/run.lua`

**Interfaces:**
- Consumes: `json.arr`, `json.get`, `json.color_to_ast` (Task 1).
- Produces: `richtext.to_inlines(rich_text_array) -> pandoc.Inlines`

- [ ] **Step 1: Write the failing test**

Create `tests/unit/block_richtext_test.lua`:

```lua
local t  = require "support.assert"
local rt = require "notion.block.richtext"

-- Build a rich text object with the annotations that matter, defaults elsewhere.
local function seg(content, ann, href)
  ann = ann or {}
  return {
    type = "text",
    text = { content = content, link = href and { url = href } or nil },
    annotations = {
      bold          = ann.bold          or false,
      italic        = ann.italic        or false,
      strikethrough = ann.strikethrough or false,
      underline     = ann.underline     or false,
      code          = ann.code          or false,
      color         = ann.color         or "default",
    },
    plain_text = content,
    href = href,
  }
end

local function native(inlines)
  return pandoc.write(pandoc.Pandoc({ pandoc.Plain(inlines) }), "native")
end

-- Plain text.
t.eq(native(rt.to_inlines({ seg("hello world") })),
     native({ pandoc.Str("hello"), pandoc.Space(), pandoc.Str("world") }),
     "plain text becomes Str/Space")

-- Single annotations.
t.eq(native(rt.to_inlines({ seg("x", { bold = true }) })),
     native({ pandoc.Strong({ pandoc.Str("x") }) }), "bold becomes Strong")
t.eq(native(rt.to_inlines({ seg("x", { italic = true }) })),
     native({ pandoc.Emph({ pandoc.Str("x") }) }), "italic becomes Emph")
t.eq(native(rt.to_inlines({ seg("x", { underline = true }) })),
     native({ pandoc.Underline({ pandoc.Str("x") }) }), "underline is native")
t.eq(native(rt.to_inlines({ seg("x", { strikethrough = true }) })),
     native({ pandoc.Strikeout({ pandoc.Str("x") }) }), "strikethrough becomes Strikeout")

-- Code is innermost by type constraint: it holds a string, not inlines.
t.eq(native(rt.to_inlines({ seg("x", { code = true, bold = true }) })),
     native({ pandoc.Strong({ pandoc.Code("x") }) }),
     "code sits inside Strong, never the reverse")

-- Canonical order: Link, Span(color), Strong, Emph, Underline, Strikeout.
local all = rt.to_inlines({ seg("x", {
  bold = true, italic = true, underline = true,
  strikethrough = true, color = "blue",
}, "https://example.com") })
t.eq(native(all), native({
  pandoc.Link({
    pandoc.Span({
      pandoc.Strong({
        pandoc.Emph({
          pandoc.Underline({ pandoc.Strikeout({ pandoc.Str("x") }) })
        })
      })
    }, pandoc.Attr("", {}, { { "color", "blue" } }))
  }, "https://example.com")
}), "the full stack nests in canonical order")

-- Colour translation happens here, not in the caller.
t.eq(native(rt.to_inlines({ seg("x", { color = "blue_background" }) })),
     native({ pandoc.Span({ pandoc.Str("x") },
                          pandoc.Attr("", {}, { { "color", "blue_bg" } })) }),
     "_background becomes _bg")
t.eq(native(rt.to_inlines({ seg("x", { color = "default" }) })),
     native({ pandoc.Str("x") }), "default colour adds no Span")

-- Coalescing: Notion splits runs arbitrarily; identical neighbours must merge.
t.eq(native(rt.to_inlines({ seg("He", { bold = true }), seg("llo", { bold = true }) })),
     native({ pandoc.Strong({ pandoc.Str("Hello") }) }),
     "adjacent identical annotations coalesce into one wrapper")
t.eq(native(rt.to_inlines({ seg("a", { bold = true }), seg("b", { italic = true }) })),
     native({ pandoc.Strong({ pandoc.Str("a") }), pandoc.Emph({ pandoc.Str("b") }) }),
     "differing annotations do not coalesce")

-- A newline inside content is a line break within the block.
t.eq(native(rt.to_inlines({ seg("a\nb") })),
     native({ pandoc.Str("a"), pandoc.LineBreak(), pandoc.Str("b") }),
     "\\n becomes LineBreak")

-- Equations.
t.eq(native(rt.to_inlines({ { type = "equation", equation = { expression = "e=mc^2" },
                              annotations = {}, plain_text = "e=mc^2" } })),
     native({ pandoc.Math("InlineMath", "e=mc^2") }), "equation becomes InlineMath")

-- Mentions carry both a generic and a specific class.
local m = rt.to_inlines({ {
  type = "mention",
  mention = { type = "user", user = { object = "user", id = "abc-123" } },
  annotations = {}, plain_text = "Ada",
} })
t.eq(m[1].t, "Span", "a mention is a Span")
t.eq(m[1].classes, pandoc.List({ "mention", "mention-user" }), "both classes present")

-- An unlisted mention kind degrades generically rather than being dropped.
local u = rt.to_inlines({ {
  type = "mention",
  mention = { type = "data_source", data_source = { id = "d-1" } },
  annotations = {}, plain_text = "Sources",
} })
t.eq(u[1].classes, pandoc.List({ "mention", "mention-data-source" }),
     "unknown mention kinds get a class from their name")
t.eq(pandoc.utils.stringify(u[1]), "Sources", "and keep their plain_text")

-- null in an optional field must not be treated as present.
t.eq(native(rt.to_inlines({ {
       type = "text",
       text = { content = "x", link = pandoc.json.null },
       annotations = {}, plain_text = "x", href = pandoc.json.null,
     } })),
     native({ pandoc.Str("x") }), "null link does not produce a Link")

-- Empty input.
t.eq(#rt.to_inlines({}), 0, "empty rich_text yields no inlines")
t.eq(#rt.to_inlines(nil), 0, "absent rich_text yields no inlines")
```

- [ ] **Step 2: Register the suite and run it to verify it fails**

Add `"unit.block_richtext_test",` to `tests/run.lua` after `"unit.block_json_test",`.

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_richtext_test"; os.exit(require("support.assert").report())'
```
Expected: FAIL with `module 'notion.block.richtext' not found`.

- [ ] **Step 3: Write the implementation**

Create `notion/block/richtext.lua`:

```lua
-- Notion rich text is a FLAT list of runs, each carrying a complete annotation
-- set. Pandoc's is a NESTED tree. Both halves of that inverse conversion live
-- here so the inverse property stays visible and testable in one place.
local json = require "notion.block.json"

local M = {}

-- Canonical wrapper order, outermost to innermost:
--   Link, Span(color), Strong, Emph, Underline, Strikeout, Code
-- Code is innermost by TYPE CONSTRAINT -- it holds a string, not inlines, so
-- Code[Strong[...]] cannot be constructed. The rest is pinned purely for
-- determinism: {bold,italic} maps equally well onto Strong[Emph[x]] and
-- Emph[Strong[x]], and an unpinned choice makes round trips flap.

local function annotations_of(rt)
  local a = json.get(rt, "annotations") or {}
  return {
    bold          = json.get(a, "bold") == true,
    italic        = json.get(a, "italic") == true,
    underline     = json.get(a, "underline") == true,
    strikethrough = json.get(a, "strikethrough") == true,
    code          = json.get(a, "code") == true,
    color         = json.color_to_ast(json.get(a, "color")),
  }
end

local function href_of(rt)
  local direct = json.get(rt, "href")
  if direct then return tostring(direct) end
  local text = json.get(rt, "text")
  local link = json.get(text, "link")
  local url  = json.get(link, "url")
  return url and tostring(url) or nil
end

-- Stable identity for coalescing: two runs merge only if every annotation and
-- the link target match exactly.
local function identity(a, href)
  return table.concat({
    tostring(a.bold), tostring(a.italic), tostring(a.underline),
    tostring(a.strikethrough), tostring(a.code),
    tostring(a.color or ""), tostring(href or ""),
  }, "\1")
end

-- Text content with embedded newlines becomes LineBreak, which is how Notion
-- renders a line break inside a single block.
local function text_inlines(s)
  local out, first = {}, true
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    if not first then out[#out + 1] = pandoc.LineBreak() end
    first = false
    for _, el in ipairs(pandoc.Inlines(line)) do out[#out + 1] = el end
  end
  return out
end

local function mention_span(rt)
  local mention = json.get(rt, "mention") or {}
  local kind    = tostring(json.get(mention, "type") or "unknown")
  local class   = "mention-" .. kind:gsub("_", "-")
  local payload = json.get(mention, kind) or {}

  local attrs = {}
  local url = json.get(payload, "url")
  local id  = json.get(payload, "id")
  if url then attrs[#attrs + 1] = { "url", tostring(url) }
  elseif id then attrs[#attrs + 1] = { "url", tostring(id) } end
  if kind == "date" then
    attrs = {}
    local start_ = json.get(payload, "start")
    local end_   = json.get(payload, "end")
    if start_ then attrs[#attrs + 1] = { "start", tostring(start_) } end
    if end_   then attrs[#attrs + 1] = { "end",   tostring(end_)   } end
  end

  local label = json.get(rt, "plain_text")
  local content = label and text_inlines(tostring(label)) or {}
  return pandoc.Span(content,
                     pandoc.Attr("", { "mention", class }, attrs))
end

-- The innermost node for one run. Code is built here, not wrapped, because it
-- takes a string.
local function leaf(rt, a, content)
  local kind = json.get(rt, "type")
  if kind == "equation" then
    local expr = json.get(json.get(rt, "equation") or {}, "expression")
    return { pandoc.Math("InlineMath", tostring(expr or "")) }
  end
  if kind == "mention" then
    return { mention_span(rt) }
  end
  if a.code then return { pandoc.Code(content) } end
  return text_inlines(content)
end

local function wrap(inlines, a, href)
  if a.strikethrough then inlines = { pandoc.Strikeout(inlines) } end
  if a.underline     then inlines = { pandoc.Underline(inlines) } end
  if a.italic        then inlines = { pandoc.Emph(inlines) } end
  if a.bold          then inlines = { pandoc.Strong(inlines) } end
  if a.color then
    inlines = { pandoc.Span(inlines,
                            pandoc.Attr("", {}, { { "color", a.color } })) }
  end
  if href then inlines = { pandoc.Link(inlines, href) } end
  return inlines
end

function M.to_inlines(rich_text)
  local out = pandoc.List({})
  if type(rich_text) ~= "table" then return pandoc.Inlines(out) end

  -- Pass 1: coalesce adjacent text runs sharing an identity. Mentions and
  -- equations are atomic and never merge.
  local runs = {}
  for _, rt in ipairs(rich_text) do
    local a       = annotations_of(rt)
    local href    = href_of(rt)
    local kind    = json.get(rt, "type")
    local id      = identity(a, href)
    local content = ""
    if kind == "text" or kind == nil then
      content = tostring(json.get(json.get(rt, "text") or {}, "content") or "")
    end
    local prev = runs[#runs]
    if kind == "text" and prev and prev.mergeable and prev.identity == id then
      prev.content = prev.content .. content
    else
      runs[#runs + 1] = {
        rt = rt, annotations = a, href = href, identity = id,
        content = content, mergeable = (kind == "text"),
      }
    end
  end

  -- Pass 2: wrap each coalesced run in canonical order.
  for _, run in ipairs(runs) do
    for _, el in ipairs(wrap(leaf(run.rt, run.annotations, run.content),
                            run.annotations, run.href)) do
      out:insert(el)
    end
  end
  return pandoc.Inlines(out)
end

return M
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_richtext_test"; os.exit(require("support.assert").report())'
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add notion/block/richtext.lua tests/unit/block_richtext_test.lua tests/run.lua
git commit -m "feat(block): convert Notion rich text to nested pandoc inlines"
```

**Documented behavior, not a defect:** `pandoc.Inlines("a  b")` collapses a run
of spaces to a single `Space`. Notion content containing consecutive spaces
therefore round-trips as single-spaced. This is *consistent* with the NFM pair,
which delegates to `pandoc.read` and collapses identically, and it preserves
idempotence (`f(f(x)) == f(x)`) — only first-pass byte-identity is affected.
Author canonical fixtures without double spaces (spec §9.3).

---

### Task 4: `notion/block/richtext.lua` — nested → flat (write direction)

The inverse half. The tree is walked with the annotation set inherited
downward, emitting one segment per leaf. This direction is **many-to-one**:
`Strong[Link[x]]` and `Link[Strong[x]]` are distinct pandoc ASTs but have a
single Notion encoding, so the inverse property is asserted in one direction
only.

**Files:**
- Modify: `notion/block/richtext.lua` (append)
- Modify: `tests/unit/block_richtext_test.lua` (append)

**Interfaces:**
- Consumes: `json.arr`, `json.obj`, `json.color_to_notion` (Task 1); `M.to_inlines` (Task 3).
- Produces: `richtext.from_inlines(inlines) -> pandoc.List` of rich text objects.

Lossy inline constructs (`SmallCaps`, `Superscript`, `Subscript`, `Note`,
`Quoted`, `Cite`, `RawInline`, `Image`) are **not** handled here — they are
Task 11, gated by the completeness test in Task 13. The dispatch below has a
defined default: any unlisted inline with a `.content` field is walked through
transparently, so nothing crashes in the meantime.

- [ ] **Step 1: Write the failing test**

Append to `tests/unit/block_richtext_test.lua`:

```lua
-- ---- write direction (nested -> flat) ----

-- Strip to the fields that carry meaning, so comparisons stay readable.
local function summarize(arr)
  local out = {}
  for i, s in ipairs(arr) do
    local a = s.annotations
    out[i] = {
      type = s.type,
      text = s.text and s.text.content or nil,
      link = s.text and s.text.link and s.text.link.url or nil,
      expr = s.equation and s.equation.expression or nil,
      b = a.bold, i = a.italic, u = a.underline,
      s_ = a.strikethrough, c = a.code, color = a.color,
    }
  end
  return out
end

t.eq(summarize(rt.from_inlines({ pandoc.Str("hi") })),
     { { type = "text", text = "hi", b = false, i = false, u = false,
         s_ = false, c = false, color = "default" } },
     "a bare Str becomes one default-annotated run")

t.eq(summarize(rt.from_inlines({ pandoc.Strong({ pandoc.Str("hi") }) }))[1].b, true,
     "Strong sets bold")
t.eq(summarize(rt.from_inlines({ pandoc.Emph({ pandoc.Str("hi") }) }))[1].i, true,
     "Emph sets italic")
t.eq(summarize(rt.from_inlines({ pandoc.Underline({ pandoc.Str("x") }) }))[1].u, true,
     "Underline sets underline")
t.eq(summarize(rt.from_inlines({ pandoc.Strikeout({ pandoc.Str("x") }) }))[1].s_, true,
     "Strikeout sets strikethrough")
t.eq(summarize(rt.from_inlines({ pandoc.Code("x") }))[1].c, true, "Code sets code")

-- Annotations inherit downward through nesting.
local nested = summarize(rt.from_inlines({
  pandoc.Strong({ pandoc.Str("a"), pandoc.Emph({ pandoc.Str("b") }) })
}))
t.eq(#nested, 2, "the nested tree splits into two runs")
t.eq(nested[1], { type = "text", text = "a", b = true, i = false, u = false,
                  s_ = false, c = false, color = "default" }, "outer run is bold only")
t.eq(nested[2].b, true, "inner run inherits bold")
t.eq(nested[2].i, true, "inner run adds italic")

-- Colour translates back at this boundary.
t.eq(summarize(rt.from_inlines({
       pandoc.Span({ pandoc.Str("x") },
                   pandoc.Attr("", {}, { { "color", "blue_bg" } }))
     }))[1].color, "blue_background", "_bg becomes _background")

-- Links.
local linked = summarize(rt.from_inlines({
  pandoc.Link({ pandoc.Str("t") }, "https://example.com")
}))
t.eq(linked[1].link, "https://example.com", "Link becomes text.link.url")

-- Many-to-one: both nestings collapse to the same encoding.
local a = summarize(rt.from_inlines({
  pandoc.Strong({ pandoc.Link({ pandoc.Str("t") }, "https://e.com") }) }))
local b = summarize(rt.from_inlines({
  pandoc.Link({ pandoc.Strong({ pandoc.Str("t") }) }, "https://e.com") }))
t.eq(a, b, "Strong[Link] and Link[Strong] encode identically")

-- Breaks.
t.eq(summarize(rt.from_inlines({ pandoc.Str("a"), pandoc.LineBreak(),
                                 pandoc.Str("b") }))[1].text, "a\nb",
     "LineBreak becomes a newline inside one run")
t.eq(summarize(rt.from_inlines({ pandoc.Str("a"), pandoc.Space(),
                                 pandoc.Str("b") }))[1].text, "a b",
     "adjacent same-annotation output merges into one run")

-- Math.
t.eq(summarize(rt.from_inlines({ pandoc.Math("InlineMath", "e=mc^2") }))[1].expr,
     "e=mc^2", "InlineMath becomes an equation run")

-- Mentions survive the round trip as mentions, not as literal text.
local mention_out = rt.from_inlines({
  pandoc.Span({ pandoc.Str("Ada") },
              pandoc.Attr("", { "mention", "mention-user" }, { { "url", "abc-123" } }))
})
t.eq(mention_out[1].type, "mention", "a mention Span becomes a mention run")
t.eq(mention_out[1].mention.type, "user", "the kind is recovered from the class")

-- Arrays must be pandoc.List, or they encode as {} and Notion rejects them.
t.eq(json.encode(rt.from_inlines({})), "[]", "an empty result encodes as []")

-- The inverse property, asserted in this direction only (design doc 4.4).
for _, ann in ipairs({
  {}, { bold = true }, { italic = true }, { code = true },
  { bold = true, italic = true }, { color = "blue" },
  { bold = true, underline = true, strikethrough = true, color = "red_background" },
}) do
  local original = { seg("sample", ann) }
  local recovered = rt.from_inlines(rt.to_inlines(original))
  t.eq(summarize(recovered), summarize(original),
       "from_inlines(to_inlines(x)) == x for " .. t.fmt(ann))
end
```

Add `local json = require "notion.block.json"` to the top of the file if it is
not already there.

- [ ] **Step 2: Run it to verify it fails**

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_richtext_test"; os.exit(require("support.assert").report())'
```
Expected: FAIL with `attempt to call a nil value (field 'from_inlines')`.

- [ ] **Step 3: Write the implementation**

Append to `notion/block/richtext.lua`, immediately **before** the final
`return M`:

```lua
-- ---------------------------------------------------------------------------
-- Write direction: nested tree -> flat runs.
--
-- The tree is walked with the annotation set inherited downward; one segment
-- is emitted per leaf, and adjacent leaves sharing a state merge. This
-- direction is MANY-TO-ONE (Strong[Link[x]] and Link[Strong[x]] encode
-- identically), which is why only from_inlines(to_inlines(x)) == x is asserted.
-- ---------------------------------------------------------------------------

local function new_state()
  return { bold = false, italic = false, underline = false,
           strikethrough = false, code = false, color = nil, href = nil }
end

local function derive(st, key, value)
  local copy = {}
  for k, v in pairs(st) do copy[k] = v end
  copy[key] = value
  return copy
end

local function annotations_for(st)
  return {
    bold          = st.bold,
    italic        = st.italic,
    strikethrough = st.strikethrough,
    underline     = st.underline,
    code          = st.code,
    color         = json.color_to_notion(st.color),
  }
end

local function state_identity(st)
  return table.concat({
    tostring(st.bold), tostring(st.italic), tostring(st.underline),
    tostring(st.strikethrough), tostring(st.code),
    tostring(st.color or ""), tostring(st.href or ""),
  }, "\1")
end

function M.from_inlines(inlines)
  local out  = json.arr()
  local meta = {}   -- parallel bookkeeping: identity + mergeability per entry

  local function emit_text(s, st)
    if s == "" then return end
    local id   = state_identity(st)
    local last = out[#out]
    if last and meta[#out] and meta[#out].mergeable and meta[#out].identity == id then
      last.text.content = last.text.content .. s
      last.plain_text   = last.text.content
      return
    end
    out:insert(json.obj({
      type = "text",
      text = json.obj({
        content = s,
        link    = st.href and json.obj({ url = st.href }) or nil,
      }),
      annotations = json.obj(annotations_for(st)),
      plain_text  = s,
      href        = st.href,
    }))
    meta[#out] = { identity = id, mergeable = true }
  end

  local function emit_atom(entry, st)
    out:insert(entry)
    meta[#out] = { identity = state_identity(st), mergeable = false }
  end

  local walk

  local function walk_span(el, st)
    local classes = el.classes or {}
    local is_mention = false
    local kind
    for _, c in ipairs(classes) do
      if c == "mention" then is_mention = true end
      local m = tostring(c):match("^mention%-(.+)$")
      if m then kind = m:gsub("%-", "_") end
    end
    if is_mention and kind then
      local payload = json.obj({})
      local url = el.attributes.url
      if kind == "date" then
        if el.attributes.start then payload.start = el.attributes.start end
        if el.attributes["end"] then payload["end"] = el.attributes["end"] end
      elseif url then
        payload.id = url
        payload.url = url
      end
      emit_atom(json.obj({
        type = "mention",
        mention = json.obj({ type = kind, [kind] = payload }),
        annotations = json.obj(annotations_for(st)),
        plain_text  = pandoc.utils.stringify(el),
        href        = st.href,
      }), st)
      return
    end
    local color = el.attributes and el.attributes.color
    walk(el.content, color and derive(st, "color", color) or st)
  end

  walk = function(ins, st)
    for _, el in ipairs(ins or {}) do
      local tag = el.t
      if     tag == "Str"       then emit_text(el.text, st)
      elseif tag == "Space"     then emit_text(" ", st)
      elseif tag == "SoftBreak" then emit_text(" ", st)
      elseif tag == "LineBreak" then emit_text("\n", st)
      elseif tag == "Strong"    then walk(el.content, derive(st, "bold", true))
      elseif tag == "Emph"      then walk(el.content, derive(st, "italic", true))
      elseif tag == "Underline" then walk(el.content, derive(st, "underline", true))
      elseif tag == "Strikeout" then walk(el.content, derive(st, "strikethrough", true))
      elseif tag == "Code"      then emit_text(el.text, derive(st, "code", true))
      elseif tag == "Link"      then walk(el.content, derive(st, "href", el.target))
      elseif tag == "Span"      then walk_span(el, st)
      elseif tag == "Math"      then
        emit_atom(json.obj({
          type = "equation",
          equation = json.obj({ expression = el.text }),
          annotations = json.obj(annotations_for(st)),
          plain_text  = el.text,
          href        = st.href,
        }), st)
      elseif el.content then
        -- Defined default: walk transparently. Task 11 replaces this with the
        -- documented lossy fallbacks for SmallCaps, Super/Subscript, Note,
        -- Quoted, Cite, RawInline and Image.
        walk(el.content, st)
      end
    end
  end

  walk(inlines, new_state())
  return out
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_richtext_test"; os.exit(require("support.assert").report())'
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add notion/block/richtext.lua tests/unit/block_richtext_test.lua
git commit -m "feat(block): render pandoc inlines as Notion rich text"
```

---

### Task 5: `notion/block/envelope.lua` — accepted input shapes

Liberal acceptance is deliberate: the list-response form is the literal output
of a single `GET /v1/blocks/:id/children`, which is what a user experimenting
with curl has on hand.

**Files:**
- Create: `notion/block/envelope.lua`
- Create: `tests/unit/block_envelope_test.lua`
- Modify: `tests/run.lua`

**Interfaces:**
- Consumes: `json.get`, `json.arr` (Task 1).
- Produces: `envelope.unwrap(value) -> blocks (pandoc.List), page (table|nil)` — raises on an unrecognized shape.

- [ ] **Step 1: Write the failing test**

Create `tests/unit/block_envelope_test.lua`:

```lua
local t   = require "support.assert"
local env = require "notion.block.envelope"

local BLOCK = { object = "block", type = "divider", divider = {} }

-- Shape 1: a bare array.
local blocks, page = env.unwrap({ BLOCK })
t.eq(#blocks, 1, "bare array yields its blocks")
t.eq(page, nil, "bare array carries no page")

-- Shape 2: a paginated list response, exactly as GET returns it.
blocks, page = env.unwrap({
  object = "list", results = { BLOCK, BLOCK }, has_more = false,
  next_cursor = pandoc.json.null,
})
t.eq(#blocks, 2, "list response yields its results")
t.eq(page, nil, "list response carries no page")

-- Shape 3: a page object.
blocks, page = env.unwrap({
  object = "page",
  properties = { title = { type = "title", title = {} } },
  children = { BLOCK },
})
t.eq(#blocks, 1, "page object yields its children")
t.truthy(page ~= nil, "page object is returned for property extraction")
t.truthy(page.properties ~= nil, "the properties map survives")

-- A page with no children is legal and yields no blocks.
blocks, page = env.unwrap({ object = "page", properties = {} })
t.eq(#blocks, 0, "a childless page yields no blocks")
t.truthy(page ~= nil, "but still returns the page")

-- A page whose children arrived under `results` (some hydrators do this).
blocks = env.unwrap({ object = "page", properties = {}, results = { BLOCK } })
t.eq(#blocks, 1, "results is accepted on a page object too")

-- The empty array is legal: an empty document, not an error.
t.eq(#env.unwrap({}), 0, "an empty array is an empty document")

-- Fatal path 2 of 2 (design doc 6.5): an unrecognized envelope.
for _, bad in ipairs({ 42, "a string", true,
                       { object = "user", id = "x" },
                       { object = "database", id = "x" } }) do
  local ok, err = pcall(env.unwrap, bad)
  t.truthy(not ok, "unrecognized envelope raises: " .. t.fmt(bad))
  t.truthy(tostring(err):find("array", 1, true),
           "the diagnostic names the accepted shapes")
end

-- The result is always a pandoc.List, so downstream code can rely on :map etc.
t.truthy(pandoc.utils.type(env.unwrap({ BLOCK })) == "List",
         "blocks come back as a pandoc.List")
```

- [ ] **Step 2: Register the suite and run it to verify it fails**

Add `"unit.block_envelope_test",` to `tests/run.lua` after `"unit.block_richtext_test",`.

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_envelope_test"; os.exit(require("support.assert").report())'
```
Expected: FAIL with `module 'notion.block.envelope' not found`.

- [ ] **Step 3: Write the implementation**

Create `notion/block/envelope.lua`:

```lua
-- Accepts the three shapes real callers actually have on hand, and unwraps
-- each to a block array plus an optional page object (design doc 6.1).
local json = require "notion.block.json"

local M = {}

local ACCEPTED = "expected a bare array of blocks, a list response " ..
                 '({"object":"list","results":[...]}), or a page object ' ..
                 '({"object":"page","properties":{...}})'

local function is_array(v)
  if type(v) ~= "table" then return false end
  if next(v) == nil then return true end     -- empty: treat as an empty array
  return v[1] ~= nil
end

function M.unwrap(value)
  if type(value) ~= "table" then
    error("notion-block-reader: " .. ACCEPTED, 0)
  end

  local object = json.get(value, "object")

  if object == "page" then
    local children = json.get(value, "children") or json.get(value, "results") or {}
    return json.arr(children), value
  end

  if object == "list" then
    return json.arr(json.get(value, "results") or {}), nil
  end

  -- No `object` discriminator: it is either a bare array or not our format.
  if is_array(value) then
    return json.arr(value), nil
  end

  error("notion-block-reader: " .. ACCEPTED, 0)
end

return M
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_envelope_test"; os.exit(require("support.assert").report())'
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add notion/block/envelope.lua tests/unit/block_envelope_test.lua tests/run.lua
git commit -m "feat(block): accept the three real input envelope shapes"
```

---

### Task 6: `notion/block/props.lua` — page properties → `Meta`

Read direction only (spec §4.6). Every property type gets a deterministic
flattening; an unrecognized type is skipped with `pandoc.log.info` rather than
crashing, because Notion adds property types over time.

**Files:**
- Create: `notion/block/props.lua`
- Create: `tests/unit/block_props_test.lua`
- Modify: `tests/run.lua`

**Interfaces:**
- Consumes: `json.get` (Task 1), `richtext.to_inlines` (Task 3).
- Produces: `props.to_meta(properties) -> table` mapping property name → Meta value.

- [ ] **Step 1: Write the failing test**

Create `tests/unit/block_props_test.lua`:

```lua
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
```

- [ ] **Step 2: Register the suite and run it to verify it fails**

Add `"unit.block_props_test",` to `tests/run.lua` after `"unit.block_envelope_test",`.

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_props_test"; os.exit(require("support.assert").report())'
```
Expected: FAIL with `module 'notion.block.props' not found`.

- [ ] **Step 3: Write the implementation**

Create `notion/block/props.lua`:

```lua
-- Page properties -> pandoc Meta. Read direction only: property WRITES must
-- validate against a database schema (a select value must already exist as an
-- option), which is the API client's job. See design doc 4.6 and 12.2.
local json     = require "notion.block.json"
local richtext = require "notion.block.richtext"

local M = {}

-- Decode yields floats, so 87 arrives as 87.0. Render integral values without
-- a decimal part.
local function num_to_string(n)
  local i = math.tointeger(n)
  if i then return tostring(i) end
  return tostring(n)
end

local function names_of(list, key)
  local out = {}
  for _, item in ipairs(list or {}) do
    local v = json.get(item, key)
    if v ~= nil then out[#out + 1] = tostring(v) end
  end
  return out
end

-- Resolve a formula or rollup to whichever typed field it carries.
local function resolve_value(v)
  if v == nil then return nil end
  local kind = json.get(v, "type")
  local inner = kind and json.get(v, kind) or nil
  if inner == nil then return nil end
  if type(inner) == "number" then return num_to_string(inner) end
  if type(inner) == "boolean" then return inner end
  if type(inner) == "table" then
    local start_ = json.get(inner, "start")
    if start_ then return tostring(start_) end
    return nil
  end
  return tostring(inner)
end

local DISPATCH = {
  title = function(p)
    return pandoc.MetaInlines(richtext.to_inlines(json.get(p, "title")))
  end,
  rich_text = function(p)
    return pandoc.MetaInlines(richtext.to_inlines(json.get(p, "rich_text")))
  end,
  number = function(p)
    local n = json.get(p, "number")
    return n and num_to_string(n) or nil
  end,
  select = function(p)
    local v = json.get(p, "select")
    local name = json.get(v, "name")
    return name and tostring(name) or nil
  end,
  status = function(p)
    local v = json.get(p, "status")
    local name = json.get(v, "name")
    return name and tostring(name) or nil
  end,
  multi_select = function(p) return names_of(json.get(p, "multi_select"), "name") end,
  people       = function(p) return names_of(json.get(p, "people"), "name") end,
  relation     = function(p) return names_of(json.get(p, "relation"), "id") end,
  date = function(p)
    local d = json.get(p, "date")
    local start_ = json.get(d, "start")
    if not start_ then return nil end
    local end_ = json.get(d, "end")
    if end_ then return tostring(start_) .. "/" .. tostring(end_) end
    return tostring(start_)
  end,
  checkbox = function(p)
    local v = json.get(p, "checkbox")
    if v == nil then return nil end
    return v == true
  end,
  url          = function(p) local v = json.get(p, "url");          return v and tostring(v) or nil end,
  email        = function(p) local v = json.get(p, "email");        return v and tostring(v) or nil end,
  phone_number = function(p) local v = json.get(p, "phone_number"); return v and tostring(v) or nil end,
  files = function(p)
    local out = {}
    for _, f in ipairs(json.get(p, "files") or {}) do
      local kind = json.get(f, "type")
      local url  = kind and json.get(json.get(f, kind), "url") or nil
      if url then out[#out + 1] = tostring(url) end
    end
    return out
  end,
  formula = function(p) return resolve_value(json.get(p, "formula")) end,
  rollup  = function(p) return resolve_value(json.get(p, "rollup")) end,
  created_time      = function(p) local v = json.get(p, "created_time");      return v and tostring(v) or nil end,
  last_edited_time  = function(p) local v = json.get(p, "last_edited_time");  return v and tostring(v) or nil end,
  created_by = function(p)
    local name = json.get(json.get(p, "created_by"), "name")
    return name and tostring(name) or nil
  end,
  last_edited_by = function(p)
    local name = json.get(json.get(p, "last_edited_by"), "name")
    return name and tostring(name) or nil
  end,
}

function M.to_meta(properties)
  local meta = {}
  if type(properties) ~= "table" then return meta end

  -- Sorted for deterministic log order; Lua's pairs() order is arbitrary.
  local names = {}
  for name in pairs(properties) do names[#names + 1] = name end
  table.sort(names)

  for _, name in ipairs(names) do
    local prop = properties[name]
    local kind = json.get(prop, "type")
    local handler = kind and DISPATCH[kind] or nil
    if handler then
      local value = handler(prop)
      if value ~= nil then
        meta[name] = value
        -- Notion names the title column whatever the database calls it, so
        -- --standalone output would otherwise go untitled.
        if kind == "title" and meta.title == nil then meta.title = value end
      end
    elseif kind then
      pandoc.log.info("Not converting page property of type " .. tostring(kind))
    end
  end
  return meta
end

return M
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_props_test"; os.exit(require("support.assert").report())'
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add notion/block/props.lua tests/unit/block_props_test.lua tests/run.lua
git commit -m "feat(block): flatten page properties into pandoc Meta"
```

---

### Task 7: `notion/block/reader.lua` — regular types, children, error recovery

The table-driven half of the reader. Irregular types (headings, lists, tables,
columns, media, code, synced blocks) are Task 8; until then they fall through
to the `unknown` path, which is a *defined* behavior rather than a crash.

**Files:**
- Create: `notion/block/reader.lua`
- Create: `tests/unit/block_reader_test.lua`
- Modify: `tests/run.lua`

**Interfaces:**
- Consumes: `json.get`, `json.color_to_ast` (Task 1); `schema.NOTION_INDEX` (Task 2); `richtext.to_inlines` (Task 3).
- Produces:
  - `reader.convert(blocks) -> pandoc.Blocks`
  - `reader.convert_block(block) -> pandoc.Block | pandoc.Blocks | nil`
  - `reader.attr_for(block, def, payload) -> pandoc.Attr` (used by Task 8)
  - `reader.children_of(block, payload) -> table` (used by Task 8)
  - `reader.wrap_color(element, color, id) -> pandoc.Block` — applies the §4.2 attribute rule
  - `reader.CUSTOM` — table keyed by Notion type, populated by Task 8
  - `reader.list_item` — assigned by Task 8; called by `reader.convert` for grouped list runs

- [ ] **Step 1: Write the failing test**

Create `tests/unit/block_reader_test.lua`:

```lua
local t      = require "support.assert"
local reader = require "notion.block.reader"

local function run(s) return { type = "text", text = { content = s },
                               annotations = {}, plain_text = s } end
local function native(blocks)
  return pandoc.write(pandoc.Pandoc(blocks), "native")
end

-- Paragraph: the plainest path.
t.eq(native(reader.convert({
       { object = "block", type = "paragraph",
         paragraph = { rich_text = { run("hi") }, color = "default" } } })),
     native({ pandoc.Para({ pandoc.Str("hi") }) }),
     "an uncoloured paragraph is a bare Para")

-- Design doc 4.2: attributes wrap only when the node has nowhere native to put
-- them. An ordinary paragraph must stay ordinary.
local colored = reader.convert({
  { type = "paragraph", paragraph = { rich_text = { run("hi") }, color = "blue_background" } } })
t.eq(colored[1].t, "Div", "a coloured paragraph gains a wrapper Div")
t.eq(colored[1].attributes.color, "blue_bg", "and the colour is translated")
t.eq(colored[1].classes, pandoc.List({}), "the wrapper is class-less")

-- Design doc 4.1: the id lands in the Attr identifier slot; other server
-- metadata is dropped.
local with_id = reader.convert({
  { type = "callout", id = "c02fc1d3-db8b-45c5-a222-27595b15aea7",
    created_time = "2026-08-01T00:00:00Z",
    last_edited_by = { object = "user", id = "u-1" },
    callout = { rich_text = { run("note") }, icon = { type = "emoji", emoji = "💡" },
                color = "blue" } } })
t.eq(with_id[1].identifier, "c02fc1d3-db8b-45c5-a222-27595b15aea7", "id is preserved")
t.eq(with_id[1].classes, pandoc.List({ "callout" }), "callout class")
t.eq(with_id[1].attributes.icon, "💡", "emoji icon is flattened to its character")
t.eq(with_id[1].attributes.color, "blue", "colour is carried")
t.eq(with_id[1].attributes.created_time, nil, "server metadata is dropped")

-- Quote and divider.
t.eq(native(reader.convert({ { type = "quote", quote = { rich_text = { run("q") } } } })),
     native({ pandoc.BlockQuote({ pandoc.Para({ pandoc.Str("q") }) }) }), "quote")
t.eq(native(reader.convert({ { type = "divider", divider = {} } })),
     native({ pandoc.HorizontalRule() }), "divider")

-- Block equation is display math.
t.eq(native(reader.convert({
       { type = "equation", equation = { expression = "e=mc^2" } } })),
     native({ pandoc.Para({ pandoc.Math("DisplayMath", "e=mc^2") }) }), "block equation")

-- Children are followed from the type payload...
local nested = reader.convert({
  { type = "callout", has_children = true,
    callout = { rich_text = { run("outer") },
                children = { { type = "paragraph",
                               paragraph = { rich_text = { run("inner") } } } } } } })
t.eq(#nested[1].content, 2, "callout holds its own text plus one child block")
t.eq(pandoc.utils.stringify(nested[1].content[2]), "inner", "the child is converted")

-- ...and from the top level, since Notion's own docs disagree about placement.
local top = reader.convert({
  { type = "callout", has_children = true,
    callout = { rich_text = { run("outer") } },
    children = { { type = "paragraph", paragraph = { rich_text = { run("inner") } } } } } })
t.eq(#top[1].content, 2, "top-level children are followed too")

-- Design doc 6.4: an unknown type degrades visibly instead of crashing.
local unknown = reader.convert({ { type = "some_future_type", some_future_type = {} } })
t.eq(unknown[1].classes, pandoc.List({ "unknown" }), "unknown type gets the unknown class")
t.eq(unknown[1].attributes.alt, "some_future_type", "and names the type it was")

-- Notion's own "unsupported" type maps to the same class.
local unsupported = reader.convert({
  { type = "unsupported", unsupported = { block_type = "mystery" } } })
t.eq(unsupported[1].classes, pandoc.List({ "unknown" }), "unsupported is unknown")

-- Design doc 6.5: recovery, never fatal.
t.eq(#reader.convert({ { object = "block", id = "x" } }), 0,
     "a block with no type is skipped")
t.eq(#reader.convert({ { type = "paragraph" } }), 1,
     "a missing payload still yields an (empty) block")
t.eq(#reader.convert({}), 0, "an empty array yields no blocks")

-- Design doc 6.3: unhydrated input is emitted with an empty body, not an error.
local unhydrated = reader.convert({
  { type = "callout", has_children = true, id = "u-1",
    callout = { rich_text = { run("outer") } } } })
t.eq(#unhydrated[1].content, 1, "an unhydrated container keeps only its own content")

-- Reuse: these three fold onto classes the NFM pair already defines.
t.eq(reader.convert({ { type = "child_page", id = "p-1",
                        child_page = { title = "Sub" } } })[1].classes,
     pandoc.List({ "page" }), "child_page reuses the page class")
t.eq(reader.convert({ { type = "transcription", transcription = {} } })[1].classes,
     pandoc.List({ "meeting-notes" }), "transcription reuses meeting-notes")

-- The six JSON-only classes.
t.eq(reader.convert({ { type = "bookmark",
                        bookmark = { url = "https://e.com", caption = {} } } })[1].attributes.url,
     "https://e.com", "bookmark carries its url")
t.eq(reader.convert({ { type = "breadcrumb", breadcrumb = {} } })[1].classes,
     pandoc.List({ "breadcrumb" }), "breadcrumb")
```

- [ ] **Step 2: Register the suite and run it to verify it fails**

Add `"unit.block_reader_test",` to `tests/run.lua` after `"unit.block_props_test",`.

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_reader_test"; os.exit(require("support.assert").report())'
```
Expected: FAIL with `module 'notion.block.reader' not found`.

- [ ] **Step 3: Write the implementation**

Create `notion/block/reader.lua`:

```lua
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

local function convert_block(block)
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
    return pandoc.HorizontalRule()
  end

  if type_name == "equation" then
    local expr = json.get(payload, "expression")
    return pandoc.Para({ pandoc.Math("DisplayMath", tostring(expr or "")) })
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
      local converted = convert_block(block)
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_reader_test"; os.exit(require("support.assert").report())'
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add notion/block/reader.lua tests/unit/block_reader_test.lua tests/run.lua
git commit -m "feat(block): read regular Notion block types into the pandoc AST"
```

---

### Task 8: `notion/block/reader_custom.lua` — the irregular types

The hand-written half. These shapes must match **byte for byte** what the NFM
reader already produces, or the cross-pair test in Task 14 fails. The target
shapes, taken from the existing goldens:

```
media:   Figure ("",["audio"],[]) (Caption Nothing [Plain CAPTION])
                                  [Plain [Link ("",[],[]) CAPTION (URL,"")]]
         -- note: the URL lives on the inner Link, NOT in the Figure's attrs
columns: Div ("",["columns"],[]) [Div ("",["column"],[]) [...]]
table:   Table ("",[],[]) (Caption Nothing []) COLSPECS
                (TableHead ("",[],[]) HEAD_ROWS)
                [TableBody ("",[],[]) (RowHeadColumns N) [] ROWS]
                (TableFoot ("",[],[]) [])
         -- has_column_header -> first row moves into TableHead
         -- has_row_header    -> RowHeadColumns 1
```

**Files:**
- Create: `notion/block/reader_custom.lua`
- Modify: `notion/block/reader.lua` (list grouping in `M.convert`)
- Modify: `tests/unit/block_reader_test.lua` (append)
- Modify: `tests/run.lua`

**Interfaces:**
- Consumes: everything from Task 7, plus `richtext.to_inlines`.
- Produces: registrations into `reader.CUSTOM`; `require`ing this module is what activates them.

- [ ] **Step 1: Write the failing test**

Append to `tests/unit/block_reader_test.lua`:

```lua
-- ---- irregular types (Task 8) ----
require "notion.block.reader_custom"

-- Headings, including heading_4, which the API really does have.
for level = 1, 4 do
  local h = reader.convert({ { type = "heading_" .. level,
    ["heading_" .. level] = { rich_text = { run("H") } } } })
  t.eq(h[1].t, "Header", "heading_" .. level .. " is a Header")
  t.eq(h[1].level, level, "heading_" .. level .. " keeps its level")
end

-- A toggle heading with no children needs no wrapper: the flag has a native
-- home on the Header's own Attr.
local toggle_h = reader.convert({ { type = "heading_2",
  heading_2 = { rich_text = { run("H") }, is_toggleable = true } } })
t.eq(toggle_h[1].t, "Header", "a childless toggle heading stays a Header")
t.eq(toggle_h[1].attributes.toggle, "true", "and carries toggle=true")

-- With children it needs the wrapper, since a Header cannot contain blocks.
local toggle_kids = reader.convert({ { type = "heading_2", has_children = true,
  heading_2 = { rich_text = { run("H") }, is_toggleable = true,
                children = { { type = "paragraph", paragraph = { rich_text = { run("k") } } } } } } })
t.eq(toggle_kids[1].classes, pandoc.List({ "toggle-heading" }), "wrapped in toggle-heading")
t.eq(toggle_kids[1].content[1].t, "Header", "the Header is the first child")

-- Consecutive list items group into ONE list.
local bullets = reader.convert({
  { type = "bulleted_list_item", bulleted_list_item = { rich_text = { run("a") } } },
  { type = "bulleted_list_item", bulleted_list_item = { rich_text = { run("b") } } } })
t.eq(#bullets, 1, "two adjacent bullets make one list")
t.eq(bullets[1].t, "BulletList", "of type BulletList")
t.eq(#bullets[1].content, 2, "with two items")

local numbers = reader.convert({
  { type = "numbered_list_item", numbered_list_item = { rich_text = { run("a") } } },
  { type = "numbered_list_item", numbered_list_item = { rich_text = { run("b") } } } })
t.eq(numbers[1].t, "OrderedList", "numbered items make an OrderedList")

-- A non-list block breaks the run.
local split = reader.convert({
  { type = "bulleted_list_item", bulleted_list_item = { rich_text = { run("a") } } },
  { type = "divider", divider = {} },
  { type = "bulleted_list_item", bulleted_list_item = { rich_text = { run("b") } } } })
t.eq(#split, 3, "a divider splits the run into two lists")

-- list_start_index becomes the OrderedList start.
local started = reader.convert({ { type = "numbered_list_item",
  numbered_list_item = { rich_text = { run("a") }, list_start_index = 5 } } })
t.eq(started[1].listAttributes.start, 5, "list_start_index becomes start")

-- to_do uses the checkbox convention pandoc's task_lists extension defines.
local todo = reader.convert({
  { type = "to_do", to_do = { rich_text = { run("task") }, checked = false } },
  { type = "to_do", to_do = { rich_text = { run("done") }, checked = true } } })
t.eq(todo[1].t, "BulletList", "to_do items are bullets")
t.eq(pandoc.utils.stringify(todo[1].content[1]):sub(1, 1), "\9744", "unchecked is U+2610")
t.eq(pandoc.utils.stringify(todo[1].content[2]):sub(1, 1), "\9746", "checked is U+2612")

-- Code.
local code = reader.convert({ { type = "code",
  code = { rich_text = { run("print(1)") }, language = "python", caption = {} } } })
t.eq(code[1].t, "CodeBlock", "code becomes a CodeBlock")
t.eq(code[1].text, "print(1)", "content is literal")
t.eq(code[1].classes, pandoc.List({ "python" }), "language becomes the class")

-- Columns.
local cols = reader.convert({ { type = "column_list", has_children = true,
  column_list = { children = {
    { type = "column", column = { children = {
        { type = "paragraph", paragraph = { rich_text = { run("L") } } } } } },
    { type = "column", column = { width_ratio = 0.5, children = {
        { type = "paragraph", paragraph = { rich_text = { run("R") } } } } } } } } } })
t.eq(cols[1].classes, pandoc.List({ "columns" }), "column_list is the columns Div")
t.eq(cols[1].content[1].classes, pandoc.List({ "column" }), "each child is a column")
t.eq(cols[1].content[2].attributes["width-ratio"], "0.5", "width_ratio is carried")

-- Media: the URL goes on the inner Link, matching the NFM golden exactly.
local vid = reader.convert({ { type = "video",
  video = { type = "external", external = { url = "https://e.com/v.mp4" },
            caption = { run("Video caption") } } } })
t.eq(vid[1].t, "Figure", "video is a Figure")
t.eq(vid[1].classes, pandoc.List({ "video" }), "with its type class")
t.eq(pandoc.utils.stringify(vid[1].caption), "Video caption", "caption is populated")
local link = vid[1].content[1].content[1]
t.eq(link.t, "Link", "the body is a Link")
t.eq(link.target, "https://e.com/v.mp4", "carrying the URL")
t.eq(vid[1].attributes.src, nil, "src is NOT duplicated onto the Figure")

-- A Notion-hosted file uses .file.url; expiry_time is dropped.
local hosted = reader.convert({ { type = "image",
  image = { type = "file", file = { url = "https://s3/i.png",
                                    expiry_time = "2026-08-29T00:00:00Z" },
            caption = {} } } })
t.eq(hosted[1].content[1].content[1].target, "https://s3/i.png", "file.url is used")
t.eq(hosted[1].attributes.expiry_time, nil, "expiry_time is dropped")

-- A file_upload has no URL at all.
local upload = reader.convert({ { type = "pdf",
  pdf = { type = "file_upload", file_upload = { id = "up-1" }, caption = {} } } })
t.eq(upload[1].attributes["data-file-upload-id"], "up-1", "the upload id is kept")

-- Tables.
local tbl = reader.convert({ { type = "table", has_children = true,
  table = { table_width = 2, has_column_header = true, has_row_header = false,
    children = {
      { type = "table_row", table_row = { cells = { { run("Status") }, { run("Owner") } } } },
      { type = "table_row", table_row = { cells = { { run("In progress") }, { run("Ada") } } } } } } } })
t.eq(tbl[1].t, "Table", "table becomes a Table")
t.eq(#tbl[1].colspecs, 2, "table_width becomes the colspec count")
t.eq(#tbl[1].head.rows, 1, "has_column_header moves the first row into the head")
t.eq(#tbl[1].bodies[1].body, 1, "leaving one row in the body")

local tbl_norow = reader.convert({ { type = "table", has_children = true,
  table = { table_width = 1, has_column_header = false, has_row_header = true,
    children = { { type = "table_row", table_row = { cells = { { run("x") } } } } } } } })
t.eq(#tbl_norow[1].head.rows, 0, "without has_column_header the head is empty")
t.eq(tbl_norow[1].bodies[1].row_head_columns, 1, "has_row_header sets row_head_columns")

-- Synced blocks: one Notion type, two AST classes, decided by synced_from.
local original = reader.convert({ { type = "synced_block",
  synced_block = { synced_from = pandoc.json.null, children = {} } } })
t.eq(original[1].classes, pandoc.List({ "synced-block" }), "null synced_from is the original")
local reference = reader.convert({ { type = "synced_block",
  synced_block = { synced_from = { type = "block_id", block_id = "b-1" }, children = {} } } })
t.eq(reference[1].classes, pandoc.List({ "synced-block-reference" }), "a set synced_from is a reference")
t.eq(reference[1].attributes.url, "b-1", "carrying the source block id")

-- A block-level mention.
local bm = reader.convert({ { type = "mention",
  mention = { type = "page", page = { id = "p-9" } } } })
t.eq(bm[1].t, "Para", "a mention block is a Para")
t.eq(bm[1].content[1].classes, pandoc.List({ "mention", "mention-page" }), "holding a mention Span")
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_reader_test"; os.exit(require("support.assert").report())'
```
Expected: FAIL with `module 'notion.block.reader_custom' not found`.

- [ ] **Step 3a: Add list grouping to `notion/block/reader.lua`**

Replace the whole `function M.convert(blocks)` body with:

```lua
-- Notion emits list items as a flat run of sibling blocks; pandoc wants one
-- list node holding many items. Group consecutive runs before dispatch.
local BULLET_TYPES  = { bulleted_list_item = true, to_do = true }
local ORDERED_TYPES = { numbered_list_item = true }

function M.convert(blocks)
  local out = pandoc.Blocks({})
  local list = blocks or {}
  local i = 1

  local function append(converted)
    if converted == nil then return end
    if pandoc.utils.type(converted) == "Blocks" then
      out = out .. converted
    else
      out:insert(converted)
    end
  end

  while i <= #list do
    local block = list[i]
    local type_name = type(block) == "table" and json.get(block, "type") or nil

    if type_name and (BULLET_TYPES[type_name] or ORDERED_TYPES[type_name]) then
      local ordered = ORDERED_TYPES[type_name] ~= nil
      local family  = ordered and ORDERED_TYPES or BULLET_TYPES
      local items, start_index = {}, nil
      while i <= #list do
        local candidate = list[i]
        local ctype = type(candidate) == "table" and json.get(candidate, "type") or nil
        if not (ctype and family[ctype]) then break end
        local payload = json.get(candidate, ctype) or {}
        if ordered and start_index == nil then
          local s = json.get(payload, "list_start_index")
          if s then start_index = math.tointeger(s) or s end
        end
        items[#items + 1] = M.list_item(candidate, ctype, payload)
        i = i + 1
      end
      if ordered then
        append(pandoc.OrderedList(items,
          pandoc.ListAttributes(start_index or 1, "Decimal", "Period")))
      else
        append(pandoc.BulletList(items))
      end
    else
      if type(block) == "table" then append(M.convert_block(block)) end
      i = i + 1
    end
  end
  return out
end
```

Then make two names visible to `reader_custom.lua` by changing their
declarations in the same file:

- `local function convert_block(block)` becomes `function M.convert_block(block)`
  (and the single call site inside `M.convert` already uses `M.convert_block`).
- Add `M.list_item = nil` near `M.CUSTOM = {}`; `reader_custom.lua` assigns it.

- [ ] **Step 3b: Write `notion/block/reader_custom.lua`**

```lua
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
    local mark = json.get(payload, "checked") == true and "\9746" or "\9744"
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
    { pandoc.TableBody(rows, row_head_columns) },
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_reader_test"; os.exit(require("support.assert").report())'
```
Expected: PASS.

Then the full suite:
```bash
pandoc lua tests/run.lua
```
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add notion/block/reader_custom.lua notion/block/reader.lua tests/unit/block_reader_test.lua
git commit -m "feat(block): read headings, lists, tables, columns, media and synced blocks"
```

---

### Task 9: `notion-block-reader.lua` — entry point and end-to-end

Wiring only, matching the NFM entry point's prelude exactly. This is the first
task whose deliverable is runnable from a shell.

**Files:**
- Create: `notion-block-reader.lua`
- Create: `tests/support/blockjson.lua`
- Create: `tests/unit/block_reader_entry_test.lua`
- Modify: `tests/run.lua`

**Interfaces:**
- Consumes: `envelope.unwrap` (Task 5), `props.to_meta` (Task 6), `reader.convert` (Tasks 7–8).
- Produces:
  - the `Reader(input, opts)` global
  - `blockjson.to_native(json_text) -> string`
  - `blockjson.to_nfm(json_text) -> string`
  - `blockjson.from_nfm(nfm_text) -> string`
  - `blockjson.to_json(json_text) -> string`
  - `blockjson.from_markdown(text) -> string`
  - `blockjson.from_markdown_verbose(text) -> string, string`
  - `blockjson.list(subdir) -> table` of `.json` paths
  - `blockjson.read_file(path) -> string`

- [ ] **Step 1: Write the failing test**

Create `tests/unit/block_reader_entry_test.lua`:

```lua
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
```

- [ ] **Step 2: Create the support helper, register the suite, run to verify it fails**

Create `tests/support/blockjson.lua`:

```lua
-- Helpers that shell out to pandoc for the block-JSON pair. Mirrors
-- tests/support/nfm.lua, which does the same for the NFM pair.
local M = {}

local ROOT = (arg[0] or ""):match("^(.*)[/\\]tests[/\\]") or "."
M.ROOT = ROOT

M.READER     = ROOT .. "/notion-block-reader.lua"
M.WRITER     = ROOT .. "/notion-block-writer.lua"
M.NFM_READER = ROOT .. "/notion-markdown-reader.lua"
M.NFM_WRITER = ROOT .. "/notion-markdown-writer.lua"

function M.to_native(text)
  return pandoc.pipe("pandoc", { "-f", M.READER, "-t", "native" }, text)
end

function M.to_json(text)
  return pandoc.pipe("pandoc", { "-f", M.READER, "-t", M.WRITER }, text)
end

function M.to_nfm(text)
  return pandoc.pipe("pandoc", { "-f", M.READER, "-t", M.NFM_WRITER }, text)
end

function M.from_nfm(text)
  return pandoc.pipe("pandoc", { "-f", M.NFM_READER, "-t", M.WRITER }, text)
end

function M.nfm_roundtrip(text)
  return pandoc.pipe("pandoc", { "-f", M.NFM_READER, "-t", M.NFM_WRITER }, text)
end

function M.from_markdown(text)
  return pandoc.pipe("pandoc", { "-f", "markdown", "-t", M.WRITER }, text)
end

-- pandoc.pipe cannot split stdout from stderr, and pandoc.log.info is only
-- emitted under --verbose, so log assertions shell out via temp files.
function M.from_markdown_verbose(text)
  local tmp_in, tmp_err = os.tmpname(), os.tmpname()
  local fh = assert(io.open(tmp_in, "wb"))
  fh:write(text)
  fh:close()

  local cmd = string.format("pandoc --verbose -f markdown -t %q %q 2>%q",
                            M.WRITER, tmp_in, tmp_err)
  local out = ""
  local p = io.popen(cmd, "r")
  if p then out = p:read("a"); p:close() end

  local errtext = ""
  local ef = io.open(tmp_err, "rb")
  if ef then errtext = ef:read("a"); ef:close() end

  os.remove(tmp_in)
  os.remove(tmp_err)
  return out, errtext
end

function M.read_file(path)
  local fh = assert(io.open(path, "rb"))
  local data = fh:read("a")
  fh:close()
  return data
end

function M.list(subdir)
  local dir = ROOT .. "/tests/corpus/json/" .. subdir
  local out = {}
  local p = io.popen("ls " .. dir .. "/*.json 2>/dev/null")
  if p then
    for line in p:lines() do out[#out + 1] = line end
    p:close()
  end
  table.sort(out)
  return out
end

return M
```

Add `"unit.block_reader_entry_test",` to `tests/run.lua` after `"unit.block_reader_test",`.

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_reader_entry_test"; os.exit(require("support.assert").report())'
```
Expected: FAIL — the reader entry point does not exist yet.

- [ ] **Step 3: Write the entry point**

Create `notion-block-reader.lua`:

```lua
-- Put this script's own directory on package.path. Pandoc does NOT do this:
-- package.path contains only the system paths and ./?.lua. Note this fails
-- through a symlink, since PANDOC_SCRIPT_FILE reports the link path -- invoke
-- by real path.
local dir = PANDOC_SCRIPT_FILE:match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. package.path

local json     = require "notion.block.json"
local envelope = require "notion.block.envelope"
local props    = require "notion.block.props"
local reader   = require "notion.block.reader"
require "notion.block.reader_custom"   -- registers the irregular types

function Reader(input, opts)
  local blocks, page = envelope.unwrap(json.decode_or_diagnose(tostring(input)))
  local doc = pandoc.Pandoc(reader.convert(blocks))
  if page then
    for key, value in pairs(props.to_meta(json.get(page, "properties"))) do
      doc.meta[key] = value
    end
  end
  return doc
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_reader_entry_test"; os.exit(require("support.assert").report())'
```
Expected: PASS.

Sanity-check by hand:
```bash
echo '[{"type":"paragraph","paragraph":{"rich_text":[{"type":"text","text":{"content":"hello"},"annotations":{},"plain_text":"hello"}]}}]' \
  | pandoc -f ./notion-block-reader.lua -t native
```
Expected: `[ Para [ Str "hello" ] ]`

- [ ] **Step 5: Commit**

```bash
git add notion-block-reader.lua tests/support/blockjson.lua \
        tests/unit/block_reader_entry_test.lua tests/run.lua
git commit -m "feat: add the Notion block JSON reader entry point"
```

---

### Task 10: `notion/block/writer.lua` — core block types

Dispatch on `el.t`, producing a `pandoc.List` of block objects. Two invariants
the tests enforce directly: every array is a `pandoc.List`, and `id` is omitted
by default so output is directly postable.

**Files:**
- Create: `notion/block/writer.lua`
- Create: `tests/unit/block_writer_test.lua`
- Modify: `tests/run.lua`

**Interfaces:**
- Consumes: `json.arr/obj/encode/color_to_notion` (Task 1); `schema.class_to_notion` (Task 2); `richtext.from_inlines` (Task 4).
- Produces:
  - `writer.convert(blocks) -> pandoc.List` of block objects
  - `writer.set_options({ preserve_ids = boolean })`
  - `writer.HANDLERS` — table keyed by `el.t`, extended by Task 11
  - `writer.block(type_name, payload, element) -> table` — the block-object constructor
  - `writer.color_of(element) -> string` — `"default"` when absent

- [ ] **Step 1: Write the failing test**

Create `tests/unit/block_writer_test.lua`:

```lua
local t      = require "support.assert"
local json   = require "notion.block.json"
local writer = require "notion.block.writer"

local function one(block) return writer.convert({ block })[1] end
local function text_of(b) return b[b.type].rich_text[1].text.content end

-- Paragraph.
local para = one(pandoc.Para({ pandoc.Str("hi") }))
t.eq(para.object, "block", "every block declares object=block")
t.eq(para.type, "paragraph", "Para becomes paragraph")
t.eq(text_of(para), "hi", "carrying its text")
t.eq(para[para.type].color, "default", "and an explicit default colour")

-- Plain is a paragraph too.
t.eq(one(pandoc.Plain({ pandoc.Str("x") })).type, "paragraph", "Plain becomes paragraph")

-- Headings, including level 4, which the API really has.
for level = 1, 4 do
  t.eq(one(pandoc.Header(level, { pandoc.Str("H") })).type, "heading_" .. level,
       "Header " .. level)
end
-- Levels beyond 4 clamp, matching NFM's h5/h6 -> h4.
t.eq(one(pandoc.Header(5, { pandoc.Str("H") })).type, "heading_4", "H5 clamps to heading_4")
t.eq(one(pandoc.Header(6, { pandoc.Str("H") })).type, "heading_4", "H6 clamps to heading_4")

-- is_toggleable round-trips through the Header's native Attr.
local toggle_h = one(pandoc.Header(2, { pandoc.Str("H") },
                                  pandoc.Attr("", {}, { { "toggle", "true" } })))
t.eq(toggle_h.heading_2.is_toggleable, true, "toggle=true becomes is_toggleable")

-- Quote, divider, code.
t.eq(one(pandoc.BlockQuote({ pandoc.Para({ pandoc.Str("q") }) })).type, "quote", "BlockQuote")
t.eq(one(pandoc.HorizontalRule()).type, "divider", "HorizontalRule")
local code = one(pandoc.CodeBlock("print(1)", pandoc.Attr("", { "python" }, {})))
t.eq(code.type, "code", "CodeBlock")
t.eq(code.code.language, "python", "the class becomes the language")
t.eq(code.code.rich_text[1].text.content, "print(1)", "content is literal")
t.eq(one(pandoc.CodeBlock("x")).code.language, "plain text",
     "a class-less CodeBlock is plain text")

-- Lists.
local bullets = writer.convert({ pandoc.BulletList({
  { pandoc.Plain({ pandoc.Str("a") }) }, { pandoc.Plain({ pandoc.Str("b") }) } }) })
t.eq(#bullets, 2, "a BulletList becomes two sibling blocks")
t.eq(bullets[1].type, "bulleted_list_item", "of type bulleted_list_item")

local ordered = writer.convert({ pandoc.OrderedList({
  { pandoc.Plain({ pandoc.Str("a") }) } },
  pandoc.ListAttributes(5, "Decimal", "Period")) })
t.eq(ordered[1].type, "numbered_list_item", "OrderedList")
t.eq(ordered[1].numbered_list_item.list_start_index, 5, "start becomes list_start_index")

-- The checkbox convention becomes a to_do, with the marker stripped.
local todos = writer.convert({ pandoc.BulletList({
  { pandoc.Plain({ pandoc.Str("\9744"), pandoc.Space(), pandoc.Str("task") }) },
  { pandoc.Plain({ pandoc.Str("\9746"), pandoc.Space(), pandoc.Str("done") }) } }) })
t.eq(todos[1].type, "to_do", "an unchecked marker makes a to_do")
t.eq(todos[1].to_do.checked, false, "unchecked")
t.eq(todos[1].to_do.rich_text[1].text.content, "task", "the marker is stripped from the text")
t.eq(todos[2].to_do.checked, true, "checked")

-- Divs dispatch on class.
local callout = one(pandoc.Div({ pandoc.Para({ pandoc.Str("note") }) },
  pandoc.Attr("", { "callout" }, { { "icon", "💡" }, { "color", "blue_bg" } })))
t.eq(callout.type, "callout", "the callout class")
t.eq(callout.callout.icon.emoji, "💡", "icon becomes an emoji object")
t.eq(callout.callout.color, "blue_background", "_bg becomes _background")
t.eq(callout.callout.rich_text[1].text.content, "note", "leading text becomes rich_text")

t.eq(one(pandoc.Div({}, pandoc.Attr("", { "breadcrumb" }, {}))).type, "breadcrumb",
     "breadcrumb")
t.eq(one(pandoc.Div({}, pandoc.Attr("", { "table-of-contents" }, {}))).type,
     "table_of_contents", "table_of_contents")
t.eq(one(pandoc.Div({}, pandoc.Attr("", { "unknown" }, { { "alt", "widget" } }))).type,
     "unsupported", "unknown maps back to unsupported")

-- Reuse: the page/database classes map back to child_page/child_database.
t.eq(one(pandoc.Div({}, pandoc.Attr("", { "page" }, { { "title", "Sub" } }))).type,
     "child_page", "the page class becomes child_page")
t.eq(one(pandoc.Div({}, pandoc.Attr("", { "meeting-notes" }, {}))).type, "meeting_notes",
     "meeting-notes becomes meeting_notes, not transcription")

-- Synced blocks: two classes, one type, distinguished by synced_from.
t.eq(one(pandoc.Div({}, pandoc.Attr("", { "synced-block" }, {}))).synced_block.synced_from,
     pandoc.json.null, "an original has a null synced_from")
local ref = one(pandoc.Div({}, pandoc.Attr("", { "synced-block-reference" },
                                           { { "url", "b-1" } })))
t.eq(ref.synced_block.synced_from.block_id, "b-1", "a reference names its source")

-- A class-less attribute-only Div is the colour wrapper: unwrap it.
local wrapped = one(pandoc.Div({ pandoc.Para({ pandoc.Str("hi") }) },
                               pandoc.Attr("", {}, { { "color", "red" } })))
t.eq(wrapped.type, "paragraph", "the wrapper does not survive as a block")
t.eq(wrapped.paragraph.color, "red", "its colour lands on the block inside")

-- An unrecognized class is unwrapped, its children kept (design doc 8).
local mystery = writer.convert({ pandoc.Div({ pandoc.Para({ pandoc.Str("kept") }) },
                                            pandoc.Attr("", { "mystery" }, {})) })
t.eq(#mystery, 1, "an unknown class yields its children")
t.eq(mystery[1].type, "paragraph", "unwrapped, not dropped")

-- Nested children go inside the type payload (design doc 3.4).
local nested = one(pandoc.Div({ pandoc.Para({ pandoc.Str("head") }),
                                pandoc.Para({ pandoc.Str("kid") }) },
                              pandoc.Attr("", { "callout" }, {})))
t.eq(#nested.callout.children, 1, "the trailing block becomes a child")
t.eq(nested.callout.children[1].type, "paragraph", "converted normally")

-- Design doc 4.1: id is omitted by default so output is directly postable.
writer.set_options({ preserve_ids = false })
t.eq(one(pandoc.Para({ pandoc.Str("x") }, pandoc.Attr("abc", {}, {}))).id, nil,
     "id is omitted by default")
writer.set_options({ preserve_ids = true })
t.eq(one(pandoc.Div({}, pandoc.Attr("abc", { "breadcrumb" }, {}))).id, "abc",
     "and emitted under the opt-in")
writer.set_options({ preserve_ids = false })

-- Every array must be a pandoc.List, or Notion rejects it (design doc 2.1).
t.eq(json.encode(writer.convert({})), "[]", "an empty document encodes as []")
t.eq(json.encode(one(pandoc.Para({}))[  "paragraph" ].rich_text), "[]",
     "an empty rich_text encodes as [], not {}")
t.eq(json.encode(one(pandoc.Div({}, pandoc.Attr("", { "breadcrumb" }, {}))).breadcrumb),
     "{}", "an empty payload object encodes as {}")
```

- [ ] **Step 2: Register the suite and run it to verify it fails**

Add `"unit.block_writer_test",` to `tests/run.lua` after `"unit.block_reader_entry_test",`.

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_writer_test"; os.exit(require("support.assert").report())'
```
Expected: FAIL with `module 'notion.block.writer' not found`.

- [ ] **Step 3: Write the implementation**

Create `notion/block/writer.lua`:

```lua
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
local CHECKED, UNCHECKED = "\9746", "\9744"

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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_writer_test"; os.exit(require("support.assert").report())'
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add notion/block/writer.lua tests/unit/block_writer_test.lua tests/run.lua
git commit -m "feat(block): render core pandoc blocks as Notion block JSON"
```

---

### Task 11: `notion/block/writer_custom.lua` — tables, figures and the lossy fallbacks

The remaining structural types plus every §8 degradation. After this task the
writer handles all 14 `Block` and all 20 `Inline` constructors, which Task 13
verifies mechanically.

**Files:**
- Create: `notion/block/writer_custom.lua`
- Modify: `notion/block/richtext.lua` (lossy inline fallbacks)
- Modify: `tests/unit/block_writer_test.lua` (append)

**Interfaces:**
- Consumes: `writer.HANDLERS`, `writer.block`, `writer.convert` (Task 10).
- Produces: registrations into `writer.HANDLERS` for `Table`, `Figure`, `LineBlock`, `DefinitionList`, `RawBlock`; extended inline handling in `richtext.from_inlines`.

**The §8 fallback table, restated so it can be implemented without re-reading the spec:**

| pandoc construct | JSON fallback | log |
|---|---|---|
| `Note` (footnote) | `[n]` marker inline, bodies appended as endnote blocks | silent |
| `DefinitionList` | bold term paragraph, definition as child blocks | silent |
| `LineBlock` | one paragraph, lines joined by `\n` — genuinely native | silent |
| `SmallCaps` | uppercased text | silent |
| `Superscript`/`Subscript` | Unicode where it exists, else literal | silent |
| `Header` level > 4 | `heading_4` (done in Task 10) | silent |
| unrecognized `Div`/`Span` class | unwrapped, children kept (done in Task 10) | silent |
| `Table` cell containing blocks | flattened to rich text | **INFO** |
| `RawBlock`/`RawInline`, foreign format | dropped | **INFO** |

- [ ] **Step 1: Write the failing test**

Append to `tests/unit/block_writer_test.lua`:

```lua
-- ---- structural and lossy (Task 11) ----
require "notion.block.writer_custom"

-- Tables.
local tbl = one(pandoc.Table(
  pandoc.Caption(pandoc.Blocks({})),
  { { pandoc.AlignDefault, nil }, { pandoc.AlignDefault, nil } },
  pandoc.TableHead({ pandoc.Row({
    pandoc.Cell({ pandoc.Plain({ pandoc.Str("Status") }) }),
    pandoc.Cell({ pandoc.Plain({ pandoc.Str("Owner") }) }) }) }),
  { pandoc.TableBody({ pandoc.Row({
    pandoc.Cell({ pandoc.Plain({ pandoc.Str("Doing") }) }),
    pandoc.Cell({ pandoc.Plain({ pandoc.Str("Ada") }) }) }) }, 0) },
  pandoc.TableFoot()))
t.eq(tbl.type, "table", "Table becomes table")
t.eq(tbl.table.table_width, 2, "table_width comes from the colspecs")
t.eq(tbl.table.has_column_header, true, "a populated head sets has_column_header")
t.eq(#tbl.table.children, 2, "head and body rows are all table_row children")
t.eq(tbl.table.children[1].type, "table_row", "rows are table_row blocks")
t.eq(tbl.table.children[1].table_row.cells[1][1].text.content, "Status",
     "cells are arrays of rich text")

-- has_row_header comes from row_head_columns.
local rh = one(pandoc.Table(
  pandoc.Caption(pandoc.Blocks({})), { { pandoc.AlignDefault, nil } },
  pandoc.TableHead({}),
  { pandoc.TableBody({ pandoc.Row({
      pandoc.Cell({ pandoc.Plain({ pandoc.Str("x") }) }) }) }, 1) },
  pandoc.TableFoot()))
t.eq(rh.table.has_row_header, true, "row_head_columns sets has_row_header")
t.eq(rh.table.has_column_header, false, "an empty head means no column header")

-- Figures round-trip back to media blocks.
local fig = one(pandoc.Figure(
  pandoc.Blocks({ pandoc.Plain({ pandoc.Link({ pandoc.Str("Cap") },
                                             "https://e.com/v.mp4") }) }),
  pandoc.Caption(pandoc.Blocks({ pandoc.Plain({ pandoc.Str("Cap") }) })),
  pandoc.Attr("", { "video" }, {})))
t.eq(fig.type, "video", "a classed Figure becomes its media type")
t.eq(fig.video.type, "external", "with an external file object")
t.eq(fig.video.external.url, "https://e.com/v.mp4", "carrying the URL")
t.eq(fig.video.caption[1].text.content, "Cap", "and the caption")

-- A plain Figure with an Image is an image block.
local img = one(pandoc.Figure(
  pandoc.Blocks({ pandoc.Plain({ pandoc.Image({ pandoc.Str("A") }, "https://e.com/i.png") }) }),
  pandoc.Caption(pandoc.Blocks({ pandoc.Plain({ pandoc.Str("A") }) })),
  pandoc.Attr()))
t.eq(img.type, "image", "an unclassed Figure defaults to image")
t.eq(img.image.external.url, "https://e.com/i.png", "from the Image target")

-- LineBlock is genuinely native: one paragraph with newlines.
local lb = one(pandoc.LineBlock({
  { pandoc.Str("one") }, { pandoc.Str("two") } }))
t.eq(lb.type, "paragraph", "LineBlock is one paragraph")
t.eq(lb.paragraph.rich_text[1].text.content, "one\ntwo", "lines joined by newline")

-- DefinitionList: bold term, definition as children.
local dl = one(pandoc.DefinitionList({
  { { pandoc.Str("Term") }, { { pandoc.Plain({ pandoc.Str("Meaning") }) } } } }))
t.eq(dl.type, "paragraph", "the term is a paragraph")
t.eq(dl.paragraph.rich_text[1].annotations.bold, true, "with the term bolded")
t.eq(dl.paragraph.children[1].paragraph.rich_text[1].text.content, "Meaning",
     "and the definition as a child block")

-- SmallCaps uppercases.
t.eq(one(pandoc.Para({ pandoc.SmallCaps({ pandoc.Str("quiet") }) }))
       .paragraph.rich_text[1].text.content, "QUIET", "SmallCaps uppercases")

-- Super/subscript use Unicode where it exists.
t.eq(one(pandoc.Para({ pandoc.Str("x"), pandoc.Superscript({ pandoc.Str("2") }) }))
       .paragraph.rich_text[1].text.content, "x²", "superscript 2 has a Unicode form")
t.eq(one(pandoc.Para({ pandoc.Str("H"), pandoc.Subscript({ pandoc.Str("2") }) }))
       .paragraph.rich_text[1].text.content, "H₂", "subscript 2 does too")
t.eq(one(pandoc.Para({ pandoc.Superscript({ pandoc.Str("qz") }) }))
       .paragraph.rich_text[1].text.content, "qz", "no Unicode form falls back to literal")

-- Footnotes: a marker inline plus endnote blocks at the end.
-- Note numbering is module-level state on richtext, reset per document by the
-- writer entry point. Reset it here too, or an earlier test's notes would
-- shift this one's numbering.
require("notion.block.richtext").reset_notes()
local noted = writer.convert({
  pandoc.Para({ pandoc.Str("text"),
                pandoc.Note({ pandoc.Para({ pandoc.Str("aside") }) }) }) })
t.eq(noted[1].paragraph.rich_text[2].text.content, "[1]", "the marker is inline")
t.truthy(#noted > 1, "the note body is appended as an endnote block")

-- Quoted and Cite pass their content through rather than vanishing.
t.eq(one(pandoc.Para({ pandoc.Quoted("DoubleQuote", { pandoc.Str("q") }) }))
       .paragraph.rich_text[1].text.content, '"q"', "Quoted keeps its quotes")

-- A cell containing blocks is flattened, and that IS a real drop, so it logs.
local nested_cell = one(pandoc.Table(
  pandoc.Caption(pandoc.Blocks({})), { { pandoc.AlignDefault, nil } },
  pandoc.TableHead({}),
  { pandoc.TableBody({ pandoc.Row({ pandoc.Cell({
      pandoc.Para({ pandoc.Str("a") }), pandoc.Para({ pandoc.Str("b") }) }) }) }, 0) },
  pandoc.TableFoot()))
t.eq(nested_cell.table.children[1].table_row.cells[1][1].text.content, "a b",
     "a multi-block cell is flattened to rich text")

-- Raw content in a foreign format is dropped.
t.eq(#writer.convert({ pandoc.RawBlock("latex", "\\vspace{1cm}") }), 0,
     "a foreign RawBlock is dropped")
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_writer_test"; os.exit(require("support.assert").report())'
```
Expected: FAIL with `module 'notion.block.writer_custom' not found`.

- [ ] **Step 3a: Extend `notion/block/richtext.lua` with the inline fallbacks**

In `M.from_inlines`, replace the `elseif el.content then` default branch with
these explicit cases, keeping the transparent walk as the final fallback:

```lua
      elseif tag == "SmallCaps" then
        emit_text(pandoc.text.upper(pandoc.utils.stringify(el)), st)
      elseif tag == "Superscript" then
        emit_text(M.script_text(pandoc.utils.stringify(el), M.SUPERSCRIPT), st)
      elseif tag == "Subscript" then
        emit_text(M.script_text(pandoc.utils.stringify(el), M.SUBSCRIPT), st)
      elseif tag == "Quoted" then
        local open_q, close_q = '"', '"'
        if el.quotetype == "SingleQuote" then open_q, close_q = "'", "'" end
        emit_text(open_q, st)
        walk(el.content, st)
        emit_text(close_q, st)
      elseif tag == "Note" then
        M.note_count = (M.note_count or 0) + 1
        M.notes = M.notes or {}
        M.notes[#M.notes + 1] = el.content
        emit_text("[" .. M.note_count .. "]", st)
      elseif tag == "Image" then
        emit_text(pandoc.utils.stringify(el.caption or {}), st)
      elseif tag == "RawInline" then
        pandoc.log.info("Not rendering RawInline (Format \"" ..
                        tostring(el.format) .. "\")")
      elseif el.content then
        walk(el.content, st)
```

And add these near the top of the module, before `M.to_inlines`:

```lua
-- Unicode super/subscript forms, where they exist. Characters without one
-- fall back to their literal form (design doc 8).
M.SUPERSCRIPT = {
  ["0"]="⁰", ["1"]="¹", ["2"]="²", ["3"]="³", ["4"]="⁴", ["5"]="⁵",
  ["6"]="⁶", ["7"]="⁷", ["8"]="⁸", ["9"]="⁹", ["+"]="⁺", ["-"]="⁻",
  ["="]="⁼", ["("]="⁽", [")"]="⁾", ["n"]="ⁿ", ["i"]="ⁱ",
}
M.SUBSCRIPT = {
  ["0"]="₀", ["1"]="₁", ["2"]="₂", ["3"]="₃", ["4"]="₄", ["5"]="₅",
  ["6"]="₆", ["7"]="₇", ["8"]="₈", ["9"]="₉", ["+"]="₊", ["-"]="₋",
  ["="]="₌", ["("]="₍", [")"]="₎", ["a"]="ₐ", ["e"]="ₑ", ["o"]="ₒ",
  ["x"]="ₓ", ["h"]="ₕ", ["k"]="ₖ", ["l"]="ₗ", ["m"]="ₘ", ["n"]="ₙ",
  ["p"]="ₚ", ["s"]="ₛ", ["t"]="ₜ",
}

-- Map each character through `table`, or keep it verbatim when absent. If NO
-- character has a mapping, return the input unchanged so the fallback reads as
-- plain literal text rather than a half-converted mixture.
function M.script_text(s, table_)
  local out, any = {}, false
  for _, code in utf8.codes(s) do
    local ch = utf8.char(code)
    local mapped = table_[ch]
    if mapped then any = true end
    out[#out + 1] = mapped or ch
  end
  if not any then return s end
  return table.concat(out)
end

-- Footnote bookkeeping, reset per document by the writer entry point.
M.note_count = 0
M.notes = {}

function M.reset_notes()
  M.note_count = 0
  M.notes = {}
end
```

- [ ] **Step 3b: Write `notion/block/writer_custom.lua`**

```lua
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
pandoc lua -e 'package.path="tests/?.lua;?.lua;"..package.path; require "unit.block_writer_test"; os.exit(require("support.assert").report())'
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add notion/block/writer_custom.lua notion/block/richtext.lua \
        tests/unit/block_writer_test.lua
git commit -m "feat(block): write tables, figures and the lossy fallbacks"
```

---

### Task 12: `notion-block-writer.lua`, the corpus, and round-trip idempotence

The first task where both directions run end to end. The round-trip test is
self-checking — it needs no hand-written expected output — so adding a fixture
costs exactly one file.

**Files:**
- Create: `notion-block-writer.lua`
- Create: `tests/corpus/json/**` (fixtures, enumerated below)
- Create: `tests/block_roundtrip_test.lua`
- Modify: `tests/run.lua`

**Interfaces:**
- Consumes: `writer.convert`, `writer.set_options` (Task 10); `richtext.reset_notes` (Task 11).
- Produces: the `Writer(doc, opts)` global.

- [ ] **Step 1: Write the entry point**

Create `notion-block-writer.lua`:

```lua
-- Put this script's own directory on package.path (see the reader entry point).
local dir = PANDOC_SCRIPT_FILE:match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. package.path

local json     = require "notion.block.json"
local richtext = require "notion.block.richtext"
local writer   = require "notion.block.writer"
require "notion.block.writer_custom"

-- Output is a deliberately forgiving superset of the API shape: no limit
-- enforcement, no chunking, no nesting-depth check (design doc 8.2).
function Writer(doc, opts)
  local variables = (opts and opts.variables) or {}
  writer.set_options({ preserve_ids = variables["preserve-ids"] ~= nil })
  richtext.reset_notes()

  local blocks = writer.convert(doc.blocks)

  -- Footnote bodies collected during conversion become endnote blocks at the
  -- end of the document, since Notion has no footnote construct.
  for index, body in ipairs(richtext.notes or {}) do
    local marker = pandoc.Para({ pandoc.Str("[" .. index .. "]") })
    for _, b in ipairs(writer.convert(pandoc.Blocks({ marker }) .. body)) do
      blocks:insert(b)
    end
  end

  return json.encode(blocks)
end
```

- [ ] **Step 2: Create the corpus**

**Fixture authoring convention — load-bearing.** Canonical fixtures (everything
outside `adversarial/`) **omit** keys whose value would be `null`. The writer
omits `text.link` and `href` when there is no link, so a fixture that spells
them `"link": null` cannot come back unchanged and would fail the no-loss check
for a reason that has nothing to do with correctness. Real Notion output does
include those nulls; `adversarial/nulls.json` is where that case is covered,
and it is already on the exception list below.

Create `tests/corpus/json/blocks/paragraph.json` verbatim:

```json
[
  {
    "object": "block",
    "type": "paragraph",
    "paragraph": {
      "rich_text": [
        {
          "type": "text",
          "text": { "content": "Plain text with " },
          "annotations": { "bold": false, "italic": false, "strikethrough": false,
                           "underline": false, "code": false, "color": "default" },
          "plain_text": "Plain text with "
        },
        {
          "type": "text",
          "text": { "content": "bold" },
          "annotations": { "bold": true, "italic": false, "strikethrough": false,
                           "underline": false, "code": false, "color": "default" },
          "plain_text": "bold"
        },
        {
          "type": "text",
          "text": { "content": " inside." },
          "annotations": { "bold": false, "italic": false, "strikethrough": false,
                           "underline": false, "code": false, "color": "default" },
          "plain_text": " inside."
        }
      ],
      "color": "default"
    }
  }
]
```

Create `tests/corpus/json/adversarial/nulls.json` verbatim — every optional
field explicitly `null`, which is the case the `json.get` guard exists for:

```json
[
  {
    "object": "block",
    "id": "b-1",
    "parent": null,
    "type": "paragraph",
    "paragraph": {
      "rich_text": [
        {
          "type": "text",
          "text": { "content": "text", "link": null },
          "annotations": { "bold": false, "italic": false, "strikethrough": false,
                           "underline": false, "code": false, "color": "default" },
          "plain_text": "text", "href": null
        }
      ],
      "color": "default"
    }
  },
  {
    "object": "block",
    "type": "synced_block",
    "synced_block": { "synced_from": null, "children": [] }
  }
]
```

Create `tests/corpus/json/unhydrated/has-children.json` verbatim:

```json
{
  "object": "list",
  "results": [
    {
      "object": "block",
      "id": "u-1",
      "type": "callout",
      "has_children": true,
      "callout": {
        "rich_text": [
          {
            "type": "text",
            "text": { "content": "Body not fetched", "link": null },
            "annotations": { "bold": false, "italic": false, "strikethrough": false,
                             "underline": false, "code": false, "color": "default" },
            "plain_text": "Body not fetched", "href": null
          }
        ],
        "icon": { "type": "emoji", "emoji": "💡" },
        "color": "blue_background"
      }
    }
  ],
  "has_more": false,
  "next_cursor": null
}
```

Then create the remaining fixtures, following the same field conventions (every
rich text object carries a complete `annotations` set, `plain_text`, and
explicit `null` for `link`/`href`). Each file is a bare array unless noted:

| file | must exercise |
|---|---|
| `blocks/headings.json` | `heading_1` through `heading_4`, one with `is_toggleable: true` and no children, one with `is_toggleable: true` and a `children` array |
| `blocks/lists-bullet.json` | three consecutive `bulleted_list_item`, one with nested `children` |
| `blocks/lists-ordered.json` | three consecutive `numbered_list_item`, the first with `list_start_index: 3` |
| `blocks/todo.json` | two `to_do`, one `checked: true`, one `checked: false` |
| `blocks/quote.json` | `quote` with `children` |
| `blocks/callout.json` | `callout` with an emoji `icon` and `color: "blue_background"` |
| `blocks/toggle.json` | `toggle` with `rich_text` and two child blocks |
| `blocks/code.json` | `code` with `language: "python"`, a `caption`, and content containing `<`, `>`, `"` and a backslash |
| `blocks/equation.json` | `equation` with a LaTeX `expression` |
| `blocks/divider.json` | a single `divider` |
| `blocks/table.json` | `table` with `table_width: 2`, `has_column_header: true`, `has_row_header: false`, and two `table_row` children |
| `blocks/table-headers.json` | `table` with `has_row_header: true` and `has_column_header: false` |
| `blocks/columns.json` | `column_list` with two `column` children, one carrying `width_ratio` |
| `blocks/media-image.json` | `image` with `type: "external"` and a caption |
| `blocks/media-hosted.json` | `image` with `type: "file"`, a `url` and an `expiry_time` |
| `blocks/media-upload.json` | `pdf` with `type: "file_upload"` and an `id` |
| `blocks/media-av.json` | one each of `audio`, `video`, `file` |
| `blocks/synced-block.json` | `synced_block` with `synced_from: null` and children |
| `blocks/synced-reference.json` | `synced_block` with `synced_from: {"type":"block_id","block_id":"b-9"}` |
| `blocks/page-database.json` | `child_page` and `child_database`, each with a `title` |
| `blocks/toc.json` | `table_of_contents` with a `color` |
| `blocks/meeting-notes.json` | `meeting_notes` with children, and a `transcription` block |
| `blocks/bookmark-embed.json` | `bookmark` (with `caption`), `embed`, `link_preview` |
| `blocks/breadcrumb-tab.json` | `breadcrumb`, `tab`, `template` |
| `blocks/unsupported.json` | `unsupported` with `block_type: "widget"` |
| `inlines/annotations.json` | one paragraph whose runs cover every single annotation, and one run with all five at once plus a colour |
| `inlines/coalescing.json` | four consecutive runs with identical annotations that must merge into one |
| `inlines/links.json` | a run with `text.link.url`, and a run with `href` set but `text.link` null |
| `inlines/equation.json` | an inline `equation` run beside text runs |
| `inlines/mentions.json` | one run per mention kind: `user`, `page`, `database`, `date` (with and without `end`), `link_preview`, `template_mention` |
| `inlines/linebreak.json` | a run whose `content` contains `\n` |
| `properties/all-types.json` | a page object whose `properties` covers every row of design doc §4.6 |
| `adversarial/unknown-type.json` | a block of type `some_future_type` |
| `adversarial/missing-payload.json` | a block declaring `"type":"paragraph"` with no `paragraph` key |
| `adversarial/empty.json` | the literal `[]` |

- [ ] **Step 3: Write the round-trip test**

Create `tests/block_roundtrip_test.lua`:

```lua
local t  = require "support.assert"
local bj = require "support.blockjson"

-- Byte-identity on the first pass is expected for fixtures authored in
-- canonical form. Entries here have a documented reason not to be.
local KNOWN_NOT_BYTE_IDENTICAL = {
  -- Server-owned metadata is deliberately dropped (design doc 4.1), so a
  -- fixture carrying ids and timestamps cannot come back byte-identical.
  ["nulls.json"]        = "carries id and parent, which are dropped by design",
  ["has-children.json"] = "list-response envelope is normalized to a bare array",
  ["media-hosted.json"] = "expiry_time is dropped; file becomes external",
  ["media-upload.json"] = "file_upload is preserved via a data- attribute",
  ["all-types.json"]    = "page properties are read-only (design doc 4.6)",
}

local function basename(path) return path:match("([^/\\]+)$") end

for _, subdir in ipairs({ "blocks", "inlines", "properties",
                          "unhydrated", "adversarial" }) do
  for _, path in ipairs(bj.list(subdir)) do
    local name     = basename(path)
    local original = bj.read_file(path)

    local once  = bj.to_json(original)
    local twice = bj.to_json(once)

    -- The primary gate: stability. f(f(x)) == f(x).
    t.eq(twice, once, subdir .. "/" .. name .. " round-trips stably")

    -- The stronger additional check, where it is expected to hold.
    if not KNOWN_NOT_BYTE_IDENTICAL[name] then
      -- Compare structurally rather than by bytes, so insignificant whitespace
      -- in the hand-authored fixture does not count as a difference.
      t.eq(pandoc.json.decode(once), pandoc.json.decode(original),
           subdir .. "/" .. name .. " round-trips without loss")
    end
  end
end

-- Design doc 9.7: array discipline. Every key Notion specifies as an array must
-- serialize as one. A bare {} here is the failure this check exists to catch.
local ARRAY_KEYS = { rich_text = true, children = true, cells = true,
                     caption = true, results = true }

local function check_arrays(value, path, label)
  if type(value) ~= "table" then return end
  for key, child in pairs(value) do
    local here = path .. "." .. tostring(key)
    if ARRAY_KEYS[key] then
      -- An empty Lua table is ambiguous, so re-encode and inspect the text.
      local encoded = pandoc.json.encode(child)
      t.truthy(encoded:sub(1, 1) == "[",
               label .. here .. " must encode as an array, got " .. encoded:sub(1, 12))
    end
    check_arrays(child, here, label)
  end
end

for _, subdir in ipairs({ "blocks", "inlines", "adversarial" }) do
  for _, path in ipairs(bj.list(subdir)) do
    local produced = pandoc.json.decode(bj.to_json(bj.read_file(path)))
    check_arrays(produced, "", basename(path) .. " ")
  end
end
```

- [ ] **Step 4: Register and run**

Add `"block_roundtrip_test",` to `tests/run.lua` after `"unit.block_writer_test",`.

Run:
```bash
pandoc lua tests/run.lua
```
Expected: all pass. Where a fixture fails byte-identity for a legitimate reason,
add it to `KNOWN_NOT_BYTE_IDENTICAL` **with its reason** — never silently.

Sanity-check the full pipeline by hand:
```bash
pandoc -f ./notion-block-reader.lua -t ./notion-block-writer.lua \
  tests/corpus/json/blocks/paragraph.json
```
Expected: a JSON array containing one `paragraph` block.

- [ ] **Step 5: Commit**

```bash
git add notion-block-writer.lua tests/corpus/json tests/block_roundtrip_test.lua tests/run.lua
git commit -m "feat: add the block JSON writer entry point and round-trip corpus"
```

---

### Task 13: Goldens, completeness on two axes, and degradation

Three verification suites that pin the convention, prove nothing is unhandled,
and assert the §8 fallbacks log at exactly the right level.

**Files:**
- Create: `tests/block_golden_test.lua`
- Create: `tests/block_completeness_test.lua`
- Create: `tests/block_degrade_test.lua`
- Create: `tests/regenerate_block_goldens.lua`
- Create: `tests/golden/json/**` (generated)
- Modify: `tests/run.lua`

**Interfaces:**
- Consumes: `bj.to_native`, `bj.list`, `bj.from_markdown_verbose` (Task 9); `writer.HANDLERS` (Tasks 10–11); `schema.NOTION_INDEX` (Task 2).

- [ ] **Step 1: Write the golden generator and test**

Create `tests/regenerate_block_goldens.lua`:

```lua
local dir = (arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/../?.lua;" .. dir .. "/?.lua;" .. package.path

local bj = require "support.blockjson"

for _, subdir in ipairs({ "blocks", "inlines", "properties",
                          "unhydrated", "adversarial" }) do
  for _, path in ipairs(bj.list(subdir)) do
    local name = path:match("([^/\\]+)%.json$")
    local out  = bj.ROOT .. "/tests/golden/json/" .. subdir .. "/" .. name .. ".native"
    os.execute("mkdir -p " .. bj.ROOT .. "/tests/golden/json/" .. subdir)
    local fh = assert(io.open(out, "wb"))
    fh:write(bj.to_native(bj.read_file(path)))
    fh:close()
    print("wrote " .. out)
  end
end
```

Create `tests/block_golden_test.lua`:

```lua
local t  = require "support.assert"
local bj = require "support.blockjson"

-- These exist to PIN the design doc 4 convention, not to check correctness --
-- the round-trip test covers that. A refactor cannot silently rename a class
-- and still pass.
for _, subdir in ipairs({ "blocks", "inlines", "properties",
                          "unhydrated", "adversarial" }) do
  for _, path in ipairs(bj.list(subdir)) do
    local name   = path:match("([^/\\]+)%.json$")
    local golden = bj.ROOT .. "/tests/golden/json/" .. subdir .. "/" .. name .. ".native"
    local fh = io.open(golden, "rb")
    t.truthy(fh ~= nil, "golden exists for " .. subdir .. "/" .. name ..
                        " (run tests/regenerate_block_goldens.lua)")
    if fh then
      local expected = fh:read("a")
      fh:close()
      t.eq(bj.to_native(bj.read_file(path)), expected,
           subdir .. "/" .. name .. " matches its golden")
    end
  end
end
```

- [ ] **Step 2: Write the completeness test**

Create `tests/block_completeness_test.lua`:

```lua
local t      = require "support.assert"
local schema = require "notion.schema"
local writer = require "notion.block.writer"
local reader = require "notion.block.reader"
require "notion.block.writer_custom"
require "notion.block.reader_custom"

-- ---- Axis 1: every pandoc constructor is handled by the writer ----
-- pandoc.Block itself is not enumerable, but .constructor is. Enumerating it
-- live is what makes this check self-maintaining across pandoc versions.
for name in pairs(pandoc.Block.constructor) do
  t.truthy(writer.HANDLERS[name] ~= nil,
           "writer handles Block constructor " .. name)
end

-- Inline constructors are handled inside richtext.from_inlines rather than a
-- dispatch table, so assert behaviourally: every one must survive conversion
-- without raising.
local SAMPLE_INLINES = {
  Str = pandoc.Str("x"), Space = pandoc.Space(),
  SoftBreak = pandoc.SoftBreak(), LineBreak = pandoc.LineBreak(),
  Emph = pandoc.Emph({ pandoc.Str("x") }),
  Strong = pandoc.Strong({ pandoc.Str("x") }),
  Underline = pandoc.Underline({ pandoc.Str("x") }),
  Strikeout = pandoc.Strikeout({ pandoc.Str("x") }),
  Superscript = pandoc.Superscript({ pandoc.Str("2") }),
  Subscript = pandoc.Subscript({ pandoc.Str("2") }),
  SmallCaps = pandoc.SmallCaps({ pandoc.Str("x") }),
  Quoted = pandoc.Quoted("DoubleQuote", { pandoc.Str("x") }),
  Cite = pandoc.Cite({ pandoc.Str("x") }, {}),
  Code = pandoc.Code("x"),
  Math = pandoc.Math("InlineMath", "x"),
  RawInline = pandoc.RawInline("latex", "\\x"),
  Link = pandoc.Link({ pandoc.Str("x") }, "https://e.com"),
  Image = pandoc.Image({ pandoc.Str("x") }, "https://e.com/i.png"),
  Note = pandoc.Note({ pandoc.Para({ pandoc.Str("x") }) }),
  Span = pandoc.Span({ pandoc.Str("x") }),
}

local richtext = require "notion.block.richtext"
for name in pairs(pandoc.Inline.constructor) do
  local sample = SAMPLE_INLINES[name]
  t.truthy(sample ~= nil, "the completeness test has a sample for Inline " .. name)
  if sample then
    local ok = pcall(richtext.from_inlines, { sample })
    t.truthy(ok, "richtext.from_inlines handles Inline constructor " .. name)
  end
end

-- ---- Axis 2: every documented Notion type is handled by the reader ----
-- Pinned to the design doc 3.1 list, so a newly documented type fails loudly
-- rather than silently falling through to `unknown`.
local DOCUMENTED_TYPES = {
  "audio", "bookmark", "breadcrumb", "bulleted_list_item", "callout",
  "child_database", "child_page", "code", "column", "column_list", "divider",
  "embed", "equation", "file", "heading_1", "heading_2", "heading_3",
  "heading_4", "image", "link_preview", "meeting_notes", "mention",
  "numbered_list_item", "paragraph", "pdf", "quote", "synced_block", "tab",
  "table", "table_of_contents", "table_row", "template", "to_do", "toggle",
  "transcription", "unsupported", "video",
}

t.eq(#DOCUMENTED_TYPES, 37, "the pinned list is the documented 37")

for _, ntype in ipairs(DOCUMENTED_TYPES) do
  local handled = reader.CUSTOM[ntype] ~= nil or schema.NOTION_INDEX[ntype] ~= nil
  t.truthy(handled, "reader handles Notion type " .. ntype)
end

-- Cross-check both directions, so a type added to one and not the other fails.
local pinned = {}
for _, ntype in ipairs(DOCUMENTED_TYPES) do pinned[ntype] = true end
for ntype in pairs(schema.NOTION_INDEX) do
  t.truthy(pinned[ntype], ntype .. " is in NOTION_INDEX and must be in the pinned list")
end
```

- [ ] **Step 3: Write the degradation test**

Create `tests/block_degrade_test.lua`:

```lua
local t  = require "support.assert"
local bj = require "support.blockjson"

-- Design doc 8: degradation is deterministic and SILENT at default verbosity.
-- INFO is emitted only when content is genuinely dropped. Silence is asserted
-- as strictly as output, since the policy makes silence a requirement.
local function convert(markdown)
  return bj.from_markdown_verbose(markdown)
end

local function text_of(out, index)
  local decoded = pandoc.json.decode(out)
  local block = decoded[index or 1]
  local payload = block[block.type]
  local parts = {}
  for _, run in ipairs(payload.rich_text or {}) do
    parts[#parts + 1] = run.text and run.text.content or run.plain_text
  end
  return table.concat(parts)
end

-- LineBlock is native, not lossy.
local out, log = convert("| one\n| two\n")
t.eq(text_of(out), "one\ntwo", "LineBlock becomes one paragraph with newlines")
t.truthy(not log:find("%[INFO%]"), "and logs nothing, since nothing was dropped")

-- SmallCaps uppercases, silently.
out, log = convert("[quiet]{.smallcaps}\n")
t.eq(text_of(out), "QUIET", "SmallCaps uppercases")
t.truthy(not log:find("%[INFO%]"), "silently")

-- Super/subscript, silently.
out, log = convert("x^2^ and H~2~O\n")
t.truthy(text_of(out):find("²", 1, true), "superscript uses its Unicode form")
t.truthy(text_of(out):find("₂", 1, true), "so does subscript")
t.truthy(not log:find("%[INFO%]"), "silently")

-- Definition lists, silently.
out, log = convert("Term\n\n:   Meaning\n")
local dl = pandoc.json.decode(out)[1]
t.eq(dl.paragraph.rich_text[1].annotations.bold, true, "the term is bolded")
t.truthy(dl.paragraph.children ~= nil, "the definition becomes a child block")
t.truthy(not log:find("%[INFO%]"), "silently")

-- Footnotes, silently.
out, log = convert("Text[^1]\n\n[^1]: The note.\n")
t.truthy(text_of(out):find("[1]", 1, true), "a marker is left inline")
t.truthy(#pandoc.json.decode(out) > 1, "and the body is appended as an endnote")
t.truthy(not log:find("%[INFO%]"), "silently")

-- Headings beyond 4 clamp, silently.
out, log = convert("##### Deep\n")
t.eq(pandoc.json.decode(out)[1].type, "heading_4", "H5 clamps to heading_4")
t.truthy(not log:find("%[INFO%]"), "silently")

-- A genuine drop: raw content in a foreign format. This one MUST log.
out, log = convert("```{=latex}\n\\vspace{1cm}\n```\n")
t.eq(#pandoc.json.decode(out), 0, "a foreign RawBlock is dropped")
t.truthy(log:find("Not rendering RawBlock", 1, true), "and logs at INFO")

-- A genuine drop: block content inside a table cell.
out, log = convert("+---------+\n| - a\n  - b   |\n+---------+\n")
t.truthy(log:find("Not rendering block content inside table cell", 1, true),
         "a multi-block cell logs at INFO")
```

- [ ] **Step 4: Generate goldens, register, and run**

```bash
pandoc lua tests/regenerate_block_goldens.lua
```

Add these to `tests/run.lua` after `"block_roundtrip_test",`:
```
  "block_golden_test",
  "block_completeness_test",
  "block_degrade_test",
```

Run:
```bash
pandoc lua tests/run.lua
```
Expected: all pass. If the completeness test reports an unhandled constructor,
add the handler — do not add an exception.

- [ ] **Step 5: Commit**

```bash
git add tests/block_golden_test.lua tests/block_completeness_test.lua \
        tests/block_degrade_test.lua tests/regenerate_block_goldens.lua \
        tests/golden/json tests/run.lua
git commit -m "test: pin the block JSON convention, completeness and degradation"
```

---

### Task 14: The cross-pair round trip, and documentation

The flagship test, and the whole reason both pairs were built against one
schema. It reuses the ~60 NFM fixtures that already exist, so it costs one file
and covers every future schema row automatically.

**Files:**
- Create: `tests/crosspair_test.lua`
- Modify: `tests/run.lua`
- Modify: `README.md`

- [ ] **Step 1: Write the test**

Create `tests/crosspair_test.lua`:

```lua
local t  = require "support.assert"
local nfm = require "support.nfm"
local bj  = require "support.blockjson"

-- The executable assertion that both pairs meet in ONE AST:
--
--   NFM -> AST -> JSON -> AST -> NFM   must equal   NFM -> AST -> NFM
--
-- If the two pairs ever disagree about a class name, an attribute spelling or
-- a colour form, this fails. It is what would have caught the _bg /
-- _background mismatch on its own.

-- Detours through block JSON that lose something NFM can express, each with a
-- documented reason. Anything not listed here must survive the detour intact.
local KNOWN_LOSSY_DETOUR = {
  -- NFM's <empty-block/> has no Notion block type: an empty paragraph is the
  -- closest equivalent, and it comes back as an ordinary empty paragraph.
  ["empty-block.nfm"] = "empty-block has no block-JSON counterpart",
}

local function basename(path) return path:match("([^/\\]+)$") end

for _, subdir in ipairs({ "blocks", "inlines", "nesting" }) do
  for _, path in ipairs(nfm.list(subdir)) do
    local name   = basename(path)
    local source = nfm.read_file(path)

    local direct  = nfm.to_nfm(source)              -- NFM -> AST -> NFM
    local via_json = bj.to_nfm(bj.from_nfm(source)) -- NFM -> AST -> JSON -> AST -> NFM

    if KNOWN_LOSSY_DETOUR[name] then
      -- Still assert stability, just not equality.
      t.eq(bj.to_nfm(bj.from_nfm(via_json)), via_json,
           subdir .. "/" .. name .. " is stable through the JSON detour")
    else
      t.eq(via_json, direct,
           subdir .. "/" .. name .. " survives the JSON detour unchanged")
    end
  end
end

-- The reverse direction: JSON -> AST -> NFM -> AST -> JSON. Asserted for
-- stability only, since NFM's vocabulary is strictly smaller than the block
-- API's, so bookmark/embed/breadcrumb genuinely cannot survive the detour.
for _, path in ipairs(bj.list("blocks")) do
  local source = bj.read_file(path)
  local once   = bj.to_json(source)
  local detour = bj.from_nfm(bj.to_nfm(source))
  t.eq(bj.to_json(bj.from_nfm(bj.to_nfm(bj.to_json(detour)))),
       bj.to_json(bj.from_nfm(bj.to_nfm(detour))),
       basename(path) .. " is stable through the NFM detour")
  t.truthy(once ~= nil, basename(path) .. " converts")
end
```

- [ ] **Step 2: Register and run**

Add `"crosspair_test",` to `tests/run.lua` as the last entry.

Run:
```bash
pandoc lua tests/run.lua
```
Expected: all pass.

A failure here is almost always a genuine disagreement between the two pairs
about a class name, attribute spelling, or colour form — fix the disagreement
rather than adding to `KNOWN_LOSSY_DETOUR`. Add an entry only when NFM
genuinely cannot express a construct, and record the reason.

- [ ] **Step 3: Update the README**

In `README.md`, replace the entire `## Not yet implemented` section with:

```markdown
## Notion block JSON

`notion-block-reader.lua` and `notion-block-writer.lua` convert Notion's block
object JSON to and from the pandoc AST, targeting the same AST convention as
the NFM pair.

```bash
# Block JSON -> anything
pandoc -f ~/.local/share/pandoc-notion/notion-block-reader.lua \
       -t docx page.json -o page.docx

# Anything -> block JSON, ready to POST
pandoc -f docx -t ~/.local/share/pandoc-notion/notion-block-writer.lua report.docx

# NFM <-> block JSON, which falls out of the shared AST
pandoc -f ...notion-markdown-reader.lua -t ...notion-block-writer.lua page.nfm
pandoc -f ...notion-block-reader.lua    -t ...notion-markdown-writer.lua page.json
```

The reader accepts a bare array of blocks, a paginated list response
(`{"object":"list","results":[…]}`) as returned by
`GET /v1/blocks/:id/children`, or a page object — following nested `children`
arrays wherever they appear.

The writer emits a hydrated array with `children` nested inside each type
payload, which is the shape `POST /v1/pages` and `PATCH /v1/blocks/:id/children`
accept. Block ids are omitted by default so output is directly postable; pass
`-V preserve-ids` to keep them.

### Deliberate limits

**API limits are not enforced.** The output is a forgiving superset of the
Notion block shape: no splitting of long text runs, no chunking of oversized
`children` arrays, no nesting-depth check. A script that uploads via the API
owns all of that. Notion's limits are 100 blocks per request, two levels of
nesting per request, 2000 characters per `text.content`, and 100 elements per
`rich_text` array.

**Page properties are read-only.** A page object's properties are flattened
into pandoc `Meta`, so `--standalone` output is titled. The writer ignores
`Meta` and emits a bare block array, because property writes must validate
against a database schema. See §12.2 of the design document.

**Server-owned metadata is dropped.** Only the block `id` survives, in the
pandoc `Attr` identifier slot. Timestamps, `created_by`, `last_edited_by`,
`parent`, `archived` and `in_trash` are all re-derived by the server and are
rejected on write.
```

Also update the `## Requirements` and `## Usage` sections' framing sentence at
the top of the file from "Pandoc custom readers and writers for Notion Flavored
Markdown (NFM)" to:

```markdown
Pandoc custom readers and writers for the two formats Notion's APIs speak:
[Notion Flavored Markdown][nfm] (NFM), the enhanced markdown dialect of the
markdown endpoints, and Notion's block object JSON. Both target the same pandoc
AST convention, so converting between them is a matter of piping through
pandoc.
```

- [ ] **Step 4: Verify the whole suite and the documented commands**

```bash
pandoc lua tests/run.lua
```
Expected: all pass, zero failures.

Verify each README command actually runs:
```bash
pandoc -f ./notion-block-reader.lua -t ./notion-markdown-writer.lua \
  tests/corpus/json/blocks/callout.json
pandoc -f ./notion-markdown-reader.lua -t ./notion-block-writer.lua \
  tests/corpus/blocks/callout.nfm
pandoc -f ./notion-block-reader.lua -t ./notion-block-writer.lua \
  -V preserve-ids tests/corpus/json/adversarial/nulls.json
```
Expected: the first emits NFM, the second JSON, the third JSON that retains
`"id"` fields.

- [ ] **Step 5: Commit**

```bash
git add tests/crosspair_test.lua tests/run.lua README.md
git commit -m "test: assert both pairs meet in one AST, and document the block pair"
```

---

## Verification checklist

Run after the final task. Each line maps to a success criterion in design doc §11.

- [ ] `pandoc lua tests/run.lua` reports zero failures.
- [ ] Every `tests/corpus/json/` fixture round-trips stably; the byte-identity exception list carries a reason per entry.
- [ ] Every fixture in the pre-existing NFM corpus survives the cross-pair detour unchanged, or is listed in `KNOWN_LOSSY_DETOUR` with a reason.
- [ ] Every §4.3 block row and §4.5 mention kind has a golden.
- [ ] The completeness test passes on both axes with no exceptions added.
- [ ] Every §8 fallback produces its documented output at its documented log level.
- [ ] `--standalone` HTML from a page object carries its title.
- [ ] The reader does not crash on unhydrated input, unknown types, `null` in any optional field, or a missing payload key.
- [ ] No JSON object appears where Notion specifies an array.
- [ ] The 866 pre-existing NFM tests still pass.
