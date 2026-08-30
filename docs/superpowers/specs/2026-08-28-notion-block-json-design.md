# Notion Block JSON ↔ Pandoc: Reader and Writer Design

Date: 2026-08-28
Status: Approved for planning
Scope: `notion-block-reader.lua`, `notion-block-writer.lua`

Companion to `2026-08-28-notion-flavored-markdown-design.md`, which built the
NFM pair and deferred this one. That document's Section 4 (the AST convention)
is normative here; this document extends it rather than replacing it, and
every extension is additive.

## 1. Purpose and scope

Make Notion's **block object JSON** — the payloads of `GET /v1/blocks/:id/children`,
`POST /v1/pages`, and `PATCH /v1/blocks/:id/children` — a first-class pandoc
format in both directions.

Both pairs target the same pandoc AST. That is the whole point of building them
against one `notion/schema.lua`: once this pair lands, NFM ↔ block-JSON
conversion falls out of piping through pandoc, with no additional mapping code.

### In scope

- A custom pandoc Lua reader that parses Notion block JSON into the pandoc AST.
- A custom pandoc Lua writer that renders the pandoc AST as Notion block JSON.
- Extension of the shared `notion/schema.lua` with a third coordinate: the
  Notion block type.
- Page properties flattened into pandoc `Meta`, read direction only.
- A dependency-free test suite, including a cross-pair test asserting that both
  pairs genuinely meet in one AST.

### Out of scope

- Any Notion API client. These are pandoc readers and writers; fetching,
  hydrating, chunking, and pushing content is the caller's job.
- Enforcement of Notion's API limits. See §8.2 — this is a deliberate decision,
  not an omission.
- Writing page properties. `Meta` is read-only in this version; see §4.6, and
  §12.2 for the planned direction.
- Notion database *schemas* (the definition of a database's columns, as opposed
  to a page's property values).

## 2. Verified environment facts

Every fact below was confirmed empirically on the development machine rather
than taken from documentation, following the convention of the companion
document's §2. Several are load-bearing and eliminated designs that looked
correct on paper. Re-verify when the pinned pandoc version changes.

Environment: pandoc 3.10.2, Lua 5.4, `PANDOC_API_VERSION` 1.23.1.2, macOS.

### 2.1 `pandoc.json` array/object discipline

- **`pandoc.json.encode({})` produces `{}` — a JSON object, not an array.**
  Notion requires an array everywhere it specifies one (`rich_text`,
  `children`, `cells`, `caption`), and rejects an object there.
- **`pandoc.json.encode(pandoc.List{})` produces `[]`.**
- The distinction is invisible in Lua and invisible at the call site. A bare
  `{}` that should have been a `pandoc.List` produces valid JSON that Notion
  rejects, with no local symptom.

This single fact is why `notion/block/json.lua` exists (§5.2): the discipline
gets one owner and one test rather than depending on every author remembering.

### 2.2 Key ordering is deterministic

`pandoc.json.encode` emits object keys in **recursively alphabetical** order,
stable across runs:

```
encode{type="callout", object="block", callout={rich_text=…}}
  →  {"callout":{…},"object":"block","type":"callout"}
encode{z={y=1,a=2,m=3}, a={n=1,b=2}}
  →  {"a":{"b":2,"n":1},"z":{"a":2,"m":3,"y":1}}
```

Byte-stable writer output is therefore free. No canonicalizing serializer is
needed, and byte-comparison goldens are viable (§9).

### 2.3 `decode` fails silently

`pandoc.json.decode` returns **`nil`** on malformed input and never raises.
Verified against `{bad`, the empty string, `[1,`, and `nonsense` — all returned
`nil` under `pcall` with no error. Wrapping the call in `pcall` is therefore
useless; the `nil` must be checked for explicitly, or the failure surfaces much
later as an unrelated crash (§6.5).

### 2.4 `null` is a truthy singleton

`pandoc.json.decode('null')` returns a userdata sentinel identical to
`pandoc.json.null`, and `decode('{"a":null}').a == pandoc.json.null` is true.

Because userdata is truthy in Lua, **`if block.caption then` is true when
`caption` is `null`.** Notion uses explicit `null` liberally (`synced_from`,
`text.link`, `date.end`, every unset property), so every optional field must be
compared against `pandoc.json.null` rather than tested for truthiness.

### 2.5 Numbers

Integers encode without a decimal part (`3`, not `3.0`), and a Lua float
holding an integral value also encodes as `3`. Decoding yields floats
(`math.type` reports `"float"`), recoverable with `math.tointeger`. Notion's
only integer-valued block fields are `table_width` and `list_start_index`, and
both survive a decode/encode cycle unchanged.

### 2.6 Writer mechanics

A custom `Writer(doc, opts)` may return a plain Lua string, which is emitted
verbatim. No use of `pandoc.scaffolding.Writer` is needed or wanted; the output
is a single serialized value, not a nested layout.

### 2.7 Pandoc inline nesting constrains the rich-text mapping

- **`Code` holds a string, not inlines.** `**\`bolded code\`**` parses to
  `Para [Strong [Code ("",[],[]) "bolded code"]]`. There is no way to construct
  `Code` containing `Strong`, so a segment with `code:true` must place `Code`
  innermost. This is a type constraint, not a stylistic preference.
- **Link nesting is genuinely bidirectional in pandoc.** `**[t](u)**` yields
  `Strong [Link … [Str "t"] …]` and `[**t**](u)` yields
  `Link … [Strong [Str "t"]] …` — two distinct ASTs. Notion has exactly one
  encoding for both (`bold:true` plus `href`), so the AST → JSON direction is
  many-to-one (§4.4).

## 3. Facts established from Notion's documentation

Sourced from <https://developers.notion.com/reference/block>,
<https://developers.notion.com/reference/rich-text>,
<https://developers.notion.com/reference/file-object>, and
<https://developers.notion.com/reference/patch-block-children>.

### 3.1 Block objects

Common fields on every block: `object`, `id`, `parent`, `type`, `created_time`,
`created_by`, `last_edited_time`, `last_edited_by`, `archived` (deprecated),
`in_trash`, `has_children`, and one type-specific payload key matching `type`.

Thirty-seven block types are documented: `audio`, `bookmark`, `breadcrumb`,
`bulleted_list_item`, `callout`, `child_database`, `child_page`, `code`,
`column`, `column_list`, `divider`, `embed`, `equation`, `file`, `heading_1`,
`heading_2`, `heading_3`, `heading_4`, `image`, `link_preview`,
`meeting_notes`, `mention`, `numbered_list_item`, `paragraph`, `pdf`, `quote`,
`synced_block`, `tab`, `table`, `table_of_contents`, `table_row`, `template`,
`to_do`, `toggle`, `transcription`, `unsupported`, `video`.

**`heading_4` exists.** An earlier assumption that the API stopped at
`heading_3` was wrong, and checking rather than assuming removed a whole
degradation path: NFM's H1–H4 maps one-to-one with no loss in either direction.

Notable payload details:

- `heading_1`–`heading_4`: `rich_text`, `color`, `is_toggleable`.
- `numbered_list_item`: `rich_text`, `color`, `list_start_index`, `list_format`.
- `column`: `width_ratio`. `column_list`: empty.
- `table`: `table_width`, `has_column_header`, `has_row_header`.
  `table_row`: `cells`, an array of arrays of rich text.
- `synced_block`: `synced_from` — `null` for an original, `{block_id}` for a
  reference. This single field is what distinguishes NFM's `<synced_block>`
  from `<synced_block_reference>`.
- `unsupported`: `block_type`.
- `child_page` / `child_database`: `title`, a plain string rather than rich text.
- `transcription` is documented as the predecessor of `meeting_notes` in older
  API versions.

### 3.2 The file object

Three variants, all of which the media block types use:

```json
{"type":"external",    "external":{"url":"https://example.com/a.png"}}
{"type":"file",        "file":{"url":"https://s3…","expiry_time":"2026-…"}}
{"type":"file_upload", "file_upload":{"id":"43833259-…"}}
```

`file` URLs are signed and expire after roughly one hour. `expiry_time` is a
property of the signed URL rather than of the document, so it is dropped (§4.3).

### 3.3 Rich text

Every rich text object carries `type` (`text` | `mention` | `equation`),
`annotations`, `plain_text`, `href`, and one type-specific payload key.

`annotations` is a flat set: `bold`, `italic`, `strikethrough`, `underline`,
`code` (all boolean) and `color`. Colors are `default`, the nine hues
(`gray` `brown` `orange` `yellow` `green` `blue` `purple` `pink` `red`), and
each hue suffixed `_background` — 19 legal values.

**The API spells background colors `blue_background`; NFM spells them
`blue_bg`.** The shared AST keeps NFM's form, and this pair translates at its
own boundary (§4.2). Without this, piping NFM → JSON would emit colors Notion
rejects.

Mention subtypes: `database`, `date`, `link_preview`, `page`, `user`,
`template_mention`. NFM's `mention-data-source` and `mention-agent` have no
documented counterpart, which §4.5 handles generically rather than by omission.

### 3.4 Children placement is ambiguous in the documentation

The append-children reference states that `children` goes **inside the
type-specific payload object**, while the literal example on the same page
shows it at the **top level** of the block object, as a sibling of the payload.

Treated as a known ambiguity rather than resolved by guessing: the reader
accepts either position, the writer emits the documented one (inside the
payload). Verifying against a live API call is recorded as follow-up work.

### 3.5 Documented limits

100 block children per append request; two levels of nesting per request;
`text.content` ≤ 2000 characters; `equation.expression` ≤ 1000; URLs ≤ 2000;
`rich_text` arrays ≤ 100 elements. None of these are enforced by this project;
see §8.2.

## 4. The AST convention

Additive extensions to the companion document's §4. The governing rule is
**reuse an existing class wherever the semantics match; add a class only for a
genuine gap.** Every reuse below is a row where NFM ↔ block-JSON conversion
works with zero new NFM code.

### 4.1 Block-level metadata

The block's `id` is carried in the pandoc `Attr` identifier slot — the field
that already exists for exactly this purpose. All other server-owned metadata
(`created_time`, `created_by`, `last_edited_time`, `last_edited_by`, `parent`,
`archived`, `in_trash`) is dropped: none is accepted on write, and the server
re-derives all of it.

```
{"id":"c02fc1d3-…","type":"callout","callout":{"icon":…}}
  →  Div ("c02fc1d3-…", {"callout"}, {icon="💡"})
```

The writer omits `id` by default, so its output is directly postable, and emits
it under an opt-in flag for callers targeting specific existing blocks.

### 4.2 Colors

One normalizer, applied to block `color`, `annotations.color`, and row/cell
colors alike:

| Notion | AST |
|---|---|
| `"default"` | attribute omitted entirely |
| `"blue"` | `"blue"` |
| `"blue_background"` | `"blue_bg"` |

`attr.is_color` remains the single validator for both pairs.

### 4.3 Block mapping

Rows marked ✅ reuse a class the companion document already defined; rows
marked ✏️ are new here.

| Notion type | pandoc AST | |
|---|---|---|
| `paragraph` | `Para`, wrapped in `Div ("",{},{color=C})` only if colored | ✅ |
| `heading_1`–`heading_4` | `Header 1`–`4`; `is_toggleable` → `toggle="true"`; with children → `Div ("",{"toggle-heading"},{})` | ✅ |
| `bulleted_list_item` | `BulletList` item | ✅ |
| `numbered_list_item` | `OrderedList` item; `list_start_index` → `start` | ✅ |
| `to_do` | item `Plain [Str "☐"/"☒", Space, …]` | ✅ |
| `quote` | `BlockQuote` | ✅ |
| `callout` | `Div ("",{"callout"},{icon,color})` | ✅ |
| `toggle` | `Div ("",{"toggle"},{color})` with a `Div ("",{"summary"},{})` first child | ✅ |
| `code` | `CodeBlock ((id,{lang},{}), text)`; `caption` → attribute | ✅ |
| `equation` | `Para [Math DisplayMath expression]` | ✅ |
| `divider` | `HorizontalRule` | ✅ |
| `table` + `table_row` | `Table`/`Row`/`Cell`; `has_column_header`, `has_row_header`, `table_width` | ✅ |
| `column_list` / `column` | `Div ("",{"columns"})` / `Div ("",{"column"},{["width-ratio"]=R})` | ✅ |
| `image` `video` `audio` `pdf` `file` | `Figure` with the type class | ✅ |
| `synced_block`, `synced_from` null | `Div ("",{"synced-block"},{})` | ✅ |
| `synced_block`, `synced_from` set | `Div ("",{"synced-block-reference"},{url})` from `block_id` | ✅ |
| `table_of_contents` | `Div ("",{"table-of-contents"},{color})` | ✅ |
| `child_page` | `Div (id,{"page"},{title})` — reuses NFM's `page` | ✅ |
| `child_database` | `Div (id,{"database"},{title})` — reuses NFM's `database` | ✅ |
| `meeting_notes` | `Div ("",{"meeting-notes"},{})` | ✅ |
| `transcription` | `Div ("",{"meeting-notes"},{})` — legacy alias, same class | ✅ |
| `unsupported` | `Div ("",{"unknown"},{alt=block_type})` | ✅ |
| `mention` (block-level) | `Para [Span …]` per §4.5 | ✅ |
| `bookmark` | `Div ("",{"bookmark"},{url})`, caption as content | ✏️ |
| `embed` | `Div ("",{"embed"},{url})` | ✏️ |
| `link_preview` | `Div ("",{"link-preview"},{url})` | ✏️ |
| `breadcrumb` | `Div ("",{"breadcrumb"},{}) []` | ✏️ |
| `template` | `Div ("",{"template"},{})` | ✏️ |
| `tab` | `Div ("",{"tab"},{})` | ✏️ |

Six new classes. Folding `child_page`/`child_database` onto NFM's existing
`page`/`database`, and `transcription` onto `meeting-notes`, is what keeps that
number down and keeps the NFM pair working on this pair's output untouched.

**Media file objects** collapse to NFM's single `src`:

```
{"type":"external","external":{"url":U}}          → src=U
{"type":"file","file":{"url":U,"expiry_time":T}}  → src=U, T dropped
{"type":"file_upload","file_upload":{"id":I}}     → data-file-upload-id=I, no src
```

### 4.4 Rich text ↔ inlines

Notion stores style as a property of each character run; pandoc stores it as
containment. The conversion is therefore flat ↔ nested, and needs four rules.

**Reading (flat → nested).** Adjacent segments carrying identical annotation
sets are coalesced first — Notion splits runs at arbitrary points, and without
coalescing the output would depend on a page's edit history. Each coalesced run
is then wrapped in a **fixed canonical order**, outermost to innermost:

| | | rationale |
|---|---|---|
| outermost | `Link` | `href` is per-segment; an outer `Link` spans coalesced runs |
| | `Span ("",{},{color=C})` | `annotations.color` |
| | `Strong` · `Emph` · `Underline` · `Strikeout` | mutually arbitrary; pinned purely for determinism |
| innermost | `Code` | forced by §2.7 — `Code` holds a string |

The order must be fixed because `{bold, italic}` maps equally well onto
`Strong[Emph[x]]` and `Emph[Strong[x]]`. An unpinned choice makes the
conversion non-deterministic and the round-trip tests flap.

**Writing (nested → flat).** The tree is walked with the annotation set
inherited downward; one segment is emitted per leaf. Per §2.7 this direction is
many-to-one, so **the stable round trip is JSON → AST → JSON, never
AST → JSON → AST**, and §9 asserts only the former.

Other rich text types: `equation` → `Math InlineMath`; `text` with a `link` →
`Link`; `\n` inside `text.content` → `LineBreak`.

### 4.5 Mentions

| Notion mention | pandoc | |
|---|---|---|
| `user` | `Span ("",{"mention","mention-user"},{url})` | ✅ |
| `page` | `Span ("",{"mention","mention-page"},{url})` from `id` | ✅ |
| `database` | `Span ("",{"mention","mention-database"},{url})` | ✅ |
| `date` | `Span ("",{"mention","mention-date"},{start,end})` | ✅ |
| `link_preview` | `Span ("",{"mention","mention-link-preview"},{url})` | ✏️ |
| `template_mention` | `Span ("",{"mention","mention-template"},{kind})` | ✏️ |

Any mention kind not listed is handled generically: its `plain_text` is kept as
content and it receives `mention-<kind>` as its second class. NFM's
`mention-data-source` and `mention-agent` are covered by this path, as is any
kind a future API version adds, with no code change.

### 4.6 Page properties → `Meta`

Read direction only **in this version**. The writer ignores `Meta` entirely and
emits a bare block array, because property *writes* must validate against a
database schema — a `select` value must already exist as an option — which is
squarely the API client's responsibility under §8.2.

This is a deferral, not a permanent boundary. Property writes are planned; see
§12.2 for the intended direction and the constraint that makes it non-trivial.

| property type | `Meta` value |
|---|---|
| `title`, `rich_text` | `MetaInlines` (formatting preserved via §4.4) |
| `number` | `MetaString` |
| `select`, `status` | `MetaString` of `.name` |
| `multi_select`, `people`, `relation` | `MetaList` of `MetaString` |
| `date` | `MetaString` `start`, or `"start/end"` when ranged |
| `checkbox` | `MetaBool` |
| `url`, `email`, `phone_number` | `MetaString` |
| `files` | `MetaList` of URL `MetaString` |
| `formula`, `rollup` | `MetaString` of the resolved value |
| `created_time`, `last_edited_time` | `MetaString`, ISO 8601 |
| `created_by`, `last_edited_by` | `MetaString` of `.name` |
| unrecognized type | skipped, `pandoc.log.info` |

The `title` property additionally populates `Meta.title`, so `--standalone`
output is titled.

## 5. Architecture

### 5.1 Packaging

Identical to the companion document's §5.1: each entry point begins with the
`PANDOC_SCRIPT_FILE` prelude that puts its own directory on `package.path`, and
carries the same documented symlink limitation.

### 5.2 Module layout

```
notion-block-reader.lua      prelude + wiring only
notion-block-writer.lua      prelude + wiring only
notion/
  schema.lua        EXTENDED — gains the Notion-type axis (§5.3)
  attr.lua          unchanged
  escape.lua        unchanged — NFM-only; this pair never escapes
  block/
    json.lua        array/object discipline, null guards, decode-or-diagnose
    envelope.lua    bare array | list response | page object → blocks + page
    reader.lua      JSON blocks → pandoc Blocks
    writer.lua      pandoc Blocks → JSON blocks
    richtext.lua    rich_text[] ↔ Inlines, both directions
    props.lua       page properties → Meta
```

`json.lua` exists because of §2.1 and §2.4: it owns `arr()` / `obj()`
constructors and a `get()` that returns `nil` for `pandoc.json.null`, so the two
traps that produce silent, non-local failures have one owner and one test.

`richtext.lua` holds **both** directions, deliberately diverging from the NFM
pair's `reader/inlines.lua` + `writer/inlines.lua` split. The flat ↔ nested
conversions of §4.4 are a genuine inverse pair, and colocating them makes
`from_inlines(to_inlines(x)) == x` visible and testable in one place.

### 5.3 The extended `schema.lua` row

```lua
callout = {
  class = "callout",                      -- pandoc AST   (existing)
  attrs = { "icon", "color" },            -- NFM tag      (existing)
  notion = { type      = "callout",       -- block JSON   (new)
             rich_text = true,
             children  = true,
             fields    = { icon = "icon", color = "color" } },
}
```

`notion.fields` maps JSON payload key to AST attribute name; `rich_text` and
`children` declare whether the generic path handles content. Irregular types —
`table`, `column_list`, headings, media, list items — set
`notion = { type = …, custom = true }` and dispatch to hand-written converters.

That split is the design's central compromise. A fully declarative table would
need escape hatches for exactly the hard cases (a `table` spanning two block
types with three structural fields, list items that are flat-with-nesting where
pandoc wants grouped, three heading levels folded with `is_toggleable`), leaving
the abstraction paying for itself only on the easy ones.

### 5.4 Data flow

```
READ                                      WRITE

input string                              Pandoc doc
  │ json.decode_or_diagnose                 │ writer.convert(doc.blocks)
  ▼                                         │   dispatch on el.t
Lua value                                   │   richtext.from_inlines(…)
  │ envelope.unwrap                         ▼
  ▼                                       List of block tables
{ blocks=List, page=table? }                │ json.encode
  │                                         ▼
  ├─ props.to_meta(page.properties)  ──►  JSON string
  │      ▼ Meta
  └─ reader.convert(blocks)
         dispatch on b.type via schema
         payload  = b[b.type]
         inlines  = richtext.to_inlines(payload.rich_text)
         children = reader.convert(payload.children or b.children)
         ▼ Blocks
       pandoc.Pandoc(blocks, meta)
```

## 6. Reader design

### 6.1 Accepted input shapes

`envelope.unwrap` accepts three shapes, unwrapping each to a block array plus an
optional page object:

```
[ {block}, … ]                                  bare array
{ "object":"list", "results":[…], "has_more":… } list response
{ "object":"page", "properties":{…}, … }         page object
```

Liberal acceptance is deliberate: the list-response form is the literal output
of a single `GET /v1/blocks/:id/children`, which is what a user experimenting
with curl has on hand. Anything else is a hard error naming all three shapes.

### 6.2 Children

Followed recursively from `payload.children` or top-level `children`, per the
documentation ambiguity of §3.4.

### 6.3 Unhydrated input

A block with `has_children: true` and no `children` array is emitted with an
empty body, and `pandoc.log.info` names its id.

This is not malformed input — it is the ordinary, unhydrated output of one API
call, since Notion returns children only on a separate request per level.
Failing would be wrong. Marking it with a class would leak a Notion-fetch
artifact into every docx and HTML file produced. INFO tells the user why a
callout came out empty without corrupting the document.

### 6.4 Unknown block types

Emitted as `Div ("",{"unknown"},{alt=type})` — precisely what Notion's own
markdown endpoint does for block types it cannot express. This is the
forward-compatibility path: an API version that adds a type degrades to
something visible and traversable rather than crashing.

### 6.5 Malformed input

The reader has **exactly two fatal paths**, both at the outer boundary, where
the input is not the format at all:

1. `json.decode_or_diagnose` checks for the `nil` of §2.3 and raises with the
   first 80 characters of input.
2. `envelope.unwrap` raises when the decoded value is none of the three shapes
   of §6.1, naming all three.

Both are cases where nothing can be recovered, and pandoc's own readers error on
unparseable input too. Everything *inside* a recognized envelope is recovered
rather than fatal, matching the companion document's §6.5:

| condition | behavior |
|---|---|
| unknown `type` string | `Div ("",{"unknown"},{alt=type})` (§6.4) |
| missing `type` | skipped, `pandoc.log.warn` with the id |
| payload key absent | emitted as an empty block of its declared type, `pandoc.log.warn` with the id |
| `null` where an object was expected | treated as absent, via the §2.4 guard |
| `has_children` without `children` | empty body, `pandoc.log.info` (§6.3) |

## 7. Writer design

A plain global `Writer(doc, opts)` over a dispatch table keyed on `el.t`,
returning the string of §2.6. No `pandoc.scaffolding.Writer`: the output is one
serialized value, not a nested layout.

Two invariants the tests enforce directly:

1. **Every JSON array is a `pandoc.List`** (§2.1), constructed through
   `json.arr`.
2. **`id` is omitted by default** (§4.1), so output is directly postable.

Output is emitted through `pandoc.json.encode`, whose deterministic key order
(§2.2) makes it byte-stable without a canonicalizing pass.

## 8. Lossy input policy

Principles are inherited from the companion document's §8 — deterministic
fallbacks, silent at default verbosity, `pandoc.log.info` only when content is
genuinely dropped — but the table differs, because the block JSON vocabulary is
larger than NFM's.

| pandoc construct | JSON fallback |
|---|---|
| `Note` (footnote) | `[n]` marker inline; note bodies as endnote blocks at document end |
| `DefinitionList` | bold term paragraph, definition as child blocks |
| `LineBlock` | one paragraph with `\n` inside `text.content` — genuinely native |
| `SmallCaps` | uppercased text |
| `Superscript` / `Subscript` | Unicode equivalents where they exist, else literal text |
| `Header` level > 4 | `heading_4`, matching NFM's h5/h6 → h4 |
| `Div`/`Span` with an unrecognized class | unwrapped, children kept |
| `Table` cell containing blocks | flattened to rich text; **INFO** — Notion cells are rich text only |
| `RawBlock` / `RawInline` in a foreign format | dropped; **INFO** |

### 8.1 A note on `LineBlock`

Unlike in NFM, this is not a degradation. Notion renders a literal `\n` inside
`text.content` as a line break within a single block, so a `LineBlock` maps onto
it exactly.

### 8.2 API limits are not enforced

The writer's output is a deliberately **forgiving superset** of the Notion block
shape. No splitting of over-long text runs, no warnings on oversized
`rich_text` or `children` arrays, no nesting-depth check — none of the §3.5
limits are enforced or reported.

A script that uploads via the API must handle chunking and splitting to respect
those limits. Placing that responsibility in the uploader rather than the writer
keeps the writer a pure, predictable function of the AST, and avoids a converter
that refuses documents pandoc understands perfectly well.

## 9. Testing

All layers run under `pandoc lua` with no external dependencies.

### 9.1 Cross-pair round trip

The highest-value test, and the executable assertion that both pairs really do
meet in one AST. For every fixture already in `tests/corpus/`:

```
NFM → AST → JSON → AST → NFM     must equal     NFM → AST → NFM
```

It costs one test file, reuses a corpus of roughly sixty fixtures that already
exists, and covers every future `schema.lua` row automatically. It would have
caught the `_bg` / `_background` mismatch of §3.3 on its own.

### 9.2 Unit tests

- **`json.lua`** — the `{}` vs `[]` rule of §2.1, the `null` guards of §2.4,
  and the decode-failure diagnosis of §2.3.
- **`richtext.lua`** — canonical wrapper order, run coalescing, and the inverse
  property `from_inlines(to_inlines(x)) == x`. Asserted in that direction only;
  §4.4 established the other is many-to-one.
- **`envelope.lua`** — all three accepted shapes of §6.1, plus rejection.
- **`props.lua`** — one case per property type of §4.6.

### 9.3 Round-trip idempotence

`JSON → AST → JSON` applied twice must produce the same output the second time
as the first. Canonically-authored fixtures additionally round-trip
byte-identically on the first pass, which is viable because of §2.2.

### 9.4 AST goldens

`JSON → native`, diffed against checked-in `.native` files, pinning the §4
convention exactly as `tests/golden/` pins NFM's.

### 9.5 Completeness, two axes

- Every pandoc `Block` and `Inline` constructor is handled by the writer,
  mirroring `tests/completeness_test.lua` and using the same live
  `.constructor` enumeration as its self-maintaining primary check.
- Every one of the §3.1 block types is handled by the reader, pinned against
  the documented list so that a newly documented type fails loudly rather than
  silently falling through to `unknown`.

### 9.6 Degradation

One case per §8 row: a pandoc-side input document, the exact expected JSON, and
an assertion about whether `[INFO]` was logged. Silence is asserted as strictly
as output.

### 9.7 Array discipline

A recursive assertion over encoded corpus output that every array-valued key
(`rich_text`, `children`, `cells`, `caption`, `results`) serializes as `[` and
never `{`. This is the one mistake of §2.1 that no type system will catch.

### 9.8 Corpus

```
tests/corpus/json/
  blocks/       one fixture per §4.3 row
  inlines/      annotation combinations, canonical order, coalescing,
                every §4.5 mention kind
  properties/   one fixture per §4.6 property type
  unhydrated/   has_children:true with no children array
  adversarial/  null in every optional field, unknown block type,
                missing payload key, malformed JSON, empty input,
                unrecognized envelope
```

## 10. Decision log

| Decision | Rationale |
|---|---|
| Liberal read, one canonical write | The list-response shape is what a single API call actually returns; one write shape keeps output postable |
| Preserve `id` only, in the `Attr` identifier slot | The slot exists for this; other server fields are unwritable and re-derived |
| `id` omitted from writer output by default | Keeps output directly postable; opt-in flag for callers targeting existing blocks |
| Real classes for API-only types, `unknown` as catch-all | JSON pair stays lossless; NFM pair degrades honestly per its own §8 |
| Reuse `page`/`database`/`meeting-notes` for `child_page`/`child_database`/`transcription` | Semantics match; every reuse is a row needing zero new NFM code |
| AST keeps NFM's `_bg` colour spelling | One convention must win; NFM's is established and the corpus is written in it |
| `richtext.lua` holds both directions | They are a genuine inverse pair, unlike NFM's tag folding |
| Canonical wrapper order, `Code` innermost | `Code` holds a string (§2.7) — a type constraint; the rest is pinned for determinism |
| Round trip asserted JSON → AST → JSON only | AST → JSON is many-to-one (§2.7); the reverse assertion would chase a bug that does not exist |
| Table-driven for regular types, hand-written for irregular | A declarative layer would need escape hatches for exactly the hard cases |
| `has_children` without children is INFO, not error or class | It is ordinary unhydrated output; a class would leak a fetch artifact into every format |
| `decode` nil check, not `pcall` | `pandoc.json.decode` never raises (§2.3) |
| No API-limit enforcement | Output is a forgiving superset; the uploader owns chunking |
| `Meta` is read-only *for now* | Property writes need a database schema to validate against; deferred, not foreclosed (§12.2) |
| Cross-pair round trip as the flagship test | Directly asserts the shared-AST payoff both specs were written for |

## 11. Success criteria

1. Every `tests/corpus/json/` fixture round-trips stably (`f(f(x)) == f(x)`);
   canonically-authored fixtures additionally round-trip byte-identically.
2. Every fixture in the existing NFM corpus survives the §9.1 cross-pair round
   trip unchanged.
3. Every §4.3 block row and §4.5 mention kind has a passing golden test.
4. Every pandoc `Block` and `Inline` constructor is handled by the writer, and
   every §3.1 Notion block type by the reader.
5. Every §8 fallback produces its documented output at its documented log level.
6. A page object's properties reach `Meta`, and `--standalone` output is titled.
7. The reader does not crash on unhydrated input, unknown block types, `null` in
   any optional field, or a missing payload key.
8. Writer output contains no JSON object where Notion specifies an array (§9.7).

## 12. Follow-up work

### 12.1 Deferred verification

Neither item blocks implementation. Both are recorded here so that a later
finding lands against a written expectation rather than a memory.

- **Children placement (§3.4).** Verify against a live API call which position
  Notion actually accepts. Until then the reader accepts both positions and the
  writer emits the one the prose documents (inside the type payload). If the
  live behaviour contradicts that, only the writer needs correcting — the
  reader is already tolerant by construction — and the finding should be
  recorded in §3.4.
- **Mention kinds (§4.5).** Confirm whether `mention-data-source` and
  `mention-agent` exist in the current API under names the documentation does
  not list. The generic `mention-<kind>` fallback means a positive finding
  requires no code change, only a golden fixture.

### 12.2 Deferred features

- **Writing page properties.** `Meta` is read-only in this version (§4.6). The
  intended future direction is for the writer to emit a page object with a
  `properties` map when `Meta` is populated, rather than a bare block array.

  What makes this more than a mapping exercise is validation: a `select` or
  `status` value must already exist as an option on the target database, and a
  `relation` must reference real page ids, so the writer cannot know whether a
  given `Meta` value is legal without the database schema. Two shapes are worth
  considering when it is picked up — emitting properties unvalidated, consistent
  with the forgiving-superset stance of §8.2 and leaving rejection to the API;
  or accepting an optional schema so the writer can fail early. The first is
  more consistent with everything else here.

  Nothing in the current design forecloses either: `props.lua` already owns the
  per-type mapping table, and adding the write direction to it mirrors what
  `richtext.lua` does for rich text.
