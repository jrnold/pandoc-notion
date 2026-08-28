# Notion Flavored Markdown ↔ Pandoc: Reader and Writer Design

Date: 2026-08-28
Status: Approved for planning
Scope: `notion-markdown-reader.lua`, `notion-markdown-writer.lua`

## 1. Purpose and scope

Make Notion Flavored Markdown (NFM, also called "enhanced markdown") a
first-class pandoc format in both directions, so that any format pandoc
supports can be converted to and from the markdown dialect that Notion's
`POST /v1/pages`, `GET /v1/pages/:page_id/markdown`, and
`PATCH /v1/pages/:page_id/markdown` endpoints speak.

This project is a general-purpose toolkit. Neither direction is privileged:
the reader and the writer both get real attention, and NFM should behave the
way any built-in pandoc format behaves.

### In scope

- A custom pandoc Lua reader that parses NFM into the pandoc AST.
- A custom pandoc Lua writer that renders the pandoc AST as NFM.
- A shared, documented AST convention describing how each Notion construct is
  represented in the pandoc AST.
- A dependency-free test suite.

### Out of scope (deliberately deferred)

- `notion-block-reader` / `notion-block-writer`, which convert Notion's block
  object JSON to and from the pandoc AST. These are a separate sub-project
  with their own spec, plan, and implementation cycle. Section 4 of this
  document is written so that pair can target the identical AST convention.
- Any Notion API client. These are pandoc readers and writers; fetching and
  pushing content is the caller's job.
- Notion database property schemas and page property metadata.

### Why the NFM pair comes first

It is the smallest independently useful deliverable, and it is what the
markdown endpoints actually speak. Because both sub-projects will target the
same AST convention (Section 4), building this pair first also means that once
the block pair lands, NFM ↔ block-JSON conversion falls out of piping through
pandoc, with no additional mapping code.

## 2. Verified environment facts

Every fact below was confirmed empirically on the development machine rather
than taken from documentation. They are load-bearing: several of them
eliminated designs that looked correct on paper. Re-verify them when the
pinned pandoc version changes.

Environment: pandoc 3.10.2, Lua 5.4, `PANDOC_API_VERSION` 1.23.1.2, macOS.

### 2.1 Module loading

- `package.path` inside a custom reader or writer contains only the system Lua
  paths and `./?.lua`. **The script's own directory is not on it.** A bare
  `require "notion.attr"` therefore succeeds only when the user's working
  directory happens to be the script directory.
- Pandoc's user data directory (`~/.local/share/pandoc`) is **not** searched
  for Lua modules by `require`.
- Prepending the script's directory via `PANDOC_SCRIPT_FILE` works for
  absolute, relative, and bare-name invocation.
- That prelude **fails through a symlink**: `PANDOC_SCRIPT_FILE` reports the
  link path, not the resolved target, so sibling lookup resolves relative to
  the wrong directory.

### 2.2 Logging

- `pandoc.log.warn`, `pandoc.log.info`, and `pandoc.log.silence` exist.
- `pandoc.log.warn` prints `[WARNING]` at default verbosity and is suppressed
  by `--quiet`. `pandoc.log.info` prints `[INFO]` only under `--verbose`.
- Lua's native `warn()` is wired to the same channel as `pandoc.log.warn`.

### 2.3 Bundled libraries

`lpeg`, `re`, `pandoc.text`, `pandoc.scaffolding`, `pandoc.template`, and
`pandoc.json` are all available. `lpeg` is therefore an option if the
line-based block scanner ever proves insufficient, with no new dependency.

### 2.4 Parsing NFM with pandoc's own markdown readers

These results ruled out the cheapest possible design (delegate everything to
pandoc's markdown reader, then post-process):

- A tab-indented child block is parsed as an **indented code block**. Feeding
  a `<callout>` containing a tab-indented `- a` / `- b` list to either
  `-f markdown` or `-f commonmark_x` yields `CodeBlock "- a\n- b"`. Tab
  indentation is NFM's entire nesting model, so this is fatal.
- `indented_code_blocks` is **not** a toggleable extension for `markdown`, so
  there is no flag out of the previous point.
- `{color="blue"}` is not an attribute to either reader. `markdown` produces
  literal text (`Str "{color="`, `Quoted DoubleQuote [Str "blue"]`);
  `commonmark_x` produces a spurious `Span` with `wrapper="1"` wrapped around
  a single space.
- A block-level `<callout>` is glued into the following paragraph by
  `markdown`, and split into two unbalanced `RawBlock`s by `commonmark_x`.
- Pandoc's HTML reader flattens `<details>`/`<summary>` and drops unknown tags
  such as `<callout>` entirely, so it is not a usable fallback either.

### 2.5 Parsing NFM inline content with pandoc

By contrast, the inline layer delegates cleanly:

- Custom tags arrive as balanced `RawInline (Format "html")` pairs.
- Under the full `markdown` reader, pandoc **fabricates structure NFM does not
  have**: `Subscript` from `~sub~` and `H~2~O`, and a full `Cite` node from
  `@citekey`. Notion has neither construct.
- Under the pinned extension set of Section 6.1, those same inputs remain
  literal `Str`, which is correct.
- `pandoc.read` is callable from inside a custom `Reader` function and returns
  a normal `Pandoc` value.

### 2.6 Existing pandoc conventions we can adopt

- **Columns**: pandoc already uses `Div class="columns"` containing
  `Div class="column"` for beamer and reveal.js. NFM's `<columns>`/`<column>`
  maps onto it one-to-one.
- **Task lists**: the `task_lists` extension represents checkboxes as a
  `Str "\9744"` (☐, U+2610) or `Str "\9746"` (☒, U+2612) prefix inside `Plain`.
- **Emoji**: the `emoji` extension produces
  `Span ("",{"emoji"},{["data-emoji"]=name})`.
- **Underline**: pandoc has a **native `Underline` node**.
- **Figures**: an image alone in a paragraph already becomes a `Figure` with a
  populated `Caption`.
- **Math**: `$…$` and `$$…$$` map to native `Math InlineMath` / `Math
  DisplayMath`.

### 2.7 Writer mechanics

- `pandoc.scaffolding.Writer` works only when assigned to the **global**
  `Writer`; handlers are then added to `Writer.Block.*` and `Writer.Inline.*`.
  `Writer.Blocks(blocks, separator)` takes a `Doc` separator, not
  `WriterOptions`.
- Scaffolding **errors loudly** on an unhandled element rather than dropping it.
- `pandoc.layout.nest(doc, 1)` indents with **one space, not a tab**. Because
  NFM's nesting is tab-defined, layout-based indentation cannot express it.
  This is why the writer does not use scaffolding (Section 7).
- `pandoc.Block` and `pandoc.Inline` themselves are **not enumerable** (each
  is a 1-key table). Their `.constructor` sub-tables ARE enumerable, though:
  `pandoc.Block.constructor` has 14 keys and `pandoc.Inline.constructor` has
  20, matching the pinned lists in `tests/completeness_test.lua` exactly.
  The completeness test therefore enumerates `.constructor` live as its
  primary check, and cross-checks a pinned list against that live
  enumeration in both directions, so a version bump that changes the
  constructor set fails loudly instead of silently under-checking.

### 2.8 Test harness

`pandoc lua script.lua` runs standalone with the full pandoc API, including
`pandoc.read` and `pandoc.write`. The test suite therefore needs **no external
dependencies** — no luarocks, no busted.

## 3. Facts established from Notion's documentation

Sourced from the two official pages, which must both be treated as normative
because **neither is complete on its own**:

- <https://developers.notion.com/guides/data-apis/enhanced-markdown>
- <https://developers.notion.com/guides/data-apis/working-with-markdown-content>

### 3.1 From the enhanced-markdown page

- Indentation uses **tabs**; child blocks are indented one tab deeper than
  their parent.
- Outside code blocks, these characters are escaped with a backslash:
  `\` `*` `~` `` ` `` `$` `[` `]` `<` `>` `{` `}` `|` `^`
- Code block content is **literal**; nothing inside is escaped.
- Headings 1–4 only. Headings 5 and 6 are converted to heading 4.
- Headings do not support children, except toggle headings
  (`{toggle="true"}`), which do.
- Multiple consecutive `>` lines are **separate quote blocks**, not one
  multi-line quote. A multi-line quote uses `<br>` inside a single `>` line.
- Table cells can contain **rich text only**, never block content.
- Table color precedence, highest to lowest: cell, row, column.
- Blank lines are stripped; `<empty-block/>` is the only way to spell an empty
  paragraph, and it must be on its own line.
- Text colors: `gray` `brown` `orange` `yellow` `green` `blue` `purple` `pink`
  `red`; each also has a `_bg` background variant, for 18 legal values.
- Block color is `{color="…"}` on the block's first line; inline color is
  `<span color="…">`. These are genuinely distinct constructs.

### 3.2 From the working-with-markdown page

- **Block separation is a single newline.** Quoting the page: "Retrieved
  markdown uses a single newline (`\n`) between adjacent top-level blocks.
  Line breaks inside a single block are represented as `<br>`." Their own
  example payload confirms it:
  `"# Meeting Notes\nDiscussed roadmap priorities.\n## Action items\n- [ ] Draft proposal\n- [ ] Schedule follow-up"`
  is a heading, a paragraph, a heading, and two to-do blocks.

  This is a real divergence from CommonMark, where two adjacent text lines are
  one paragraph joined by a soft break. It independently confirms that block
  parsing cannot be delegated to pandoc, and it explains why `<empty-block/>`
  needs to exist.

- **Two tags the enhanced-markdown page never documents:**
  - `<unknown url="…" alt="block_type"/>` — emitted for unsupported block
    types, for pages truncated past roughly 20,000 blocks, and for child
    content the connection lacks permission to read. Any real page can contain
    these, so the reader must handle them.
  - `<meeting-notes>` — the Transcription block type.

- Media URLs in retrieved markdown are pre-signed and expire after a short
  period. Documentation note only; no design impact.

## 4. The AST convention

This is the shared core. Both the reader and the writer consult a single
table, `notion/schema.lua`, so that a construct's class name and attribute
spelling cannot drift between directions. The future block-JSON pair targets
this same table.

### 4.1 Representation strategy

Notion-only constructs are represented **structurally** — as `Div` and `Span`
carrying a class and the construct's attributes — never as opaque
`RawBlock`/`RawInline`. NFM's own syntax is already attribute-based, so it
maps almost directly onto pandoc's `Attr` type, and structural representation
keeps content visible and traversable in every other output format and to
other Lua filters.

### 4.2 The attribute gap

Only `Div`, `Span`, `Header`, `CodeBlock`, `Table`/`Row`/`Cell`, `Figure`,
`Link`, `Image`, and `Code` carry an `Attr` in pandoc's AST. `Para`, `Plain`,
`BlockQuote`, `BulletList`, and list items carry nothing — but NFM's
`{color="…"}` can attach to any block.

**Rule: use the node's native `Attr` where pandoc has one; wrap in a
class-less, attribute-only `Div` only where it does not.** A block with no
attributes is never wrapped, so ordinary content stays ordinary.

```
# Heading {color="blue"}   →  Header 1 ("",{},{color="blue"}) [...]      native
Hello {color="blue"}       →  Div ("",{},{color="blue"}) [Para [...]]    wrapped
Hello                      →  Para [...]                                untouched
- item {color="red"}       →  BulletList [[ Div ("",{},{color="red"})
                                              [Plain [...]] ]]          wrapped
```

A class-less `Div` carrying only attributes therefore has exactly one meaning:
"these attributes belong to the single block inside me."

### 4.3 Block mapping

Rows marked ✅ reuse an existing pandoc convention; rows marked ✏️ are
invented for this project.

| NFM | pandoc AST | |
|---|---|---|
| `Rich text` | `Para` | ✅ |
| `Rich text {color=C}` | `Div ("",{},{color=C}) [Para …]` | ✏️ |
| `# H1` … `#### H4` | `Header n ("",{},{color=C})` | ✅ |
| `# H {toggle="true"}` (no children) | `Header n ("",{},{toggle="true",color=C})` | ✅ native attr |
| `# H {toggle="true"}` + children | `Div ("",{"toggle-heading"},{}) [Header n ("",{},{toggle="true",…}), children…]` | ✏️ |
| `<details><summary>T</summary>…</details>` | `Div ("",{"toggle"},{color=C}) [Div ("",{"summary"},{}) [Plain T], children…]` | ✏️ |
| `- item` | `BulletList` | ✅ |
| `1. item` | `OrderedList` | ✅ |
| `- [ ]` / `- [x]` | item `Plain [Str "☐"/"☒", Space, …]` | ✅ |
| `> quote` | `BlockQuote` | ✅ |
| `> a<br>b` | `BlockQuote [Para [… LineBreak …]]` | ✅ |
| `<callout icon="E" color=C>` | `Div ("",{"callout"},{icon=E,color=C})` | ✏️ |
| ` ```lang ` | `CodeBlock (("",{"lang"},{}), text)` | ✅ |
| `$$…$$` | `Para [Math DisplayMath …]` | ✅ |
| `<table>`/`<tr>`/`<td color=>` | `Table`/`Row`/`Cell`, colors in native `Attr` | ✅ |
| `---` | `HorizontalRule` | ✅ |
| `<empty-block/>` | `Div ("",{"empty-block"},{}) []` | ✏️ |
| `<columns><column>` | `Div ("",{"columns"}) [Div ("",{"column"}) …]` | ✅ |
| `![Caption](URL)` | `Figure` with populated `Caption` | ✅ |
| `<video src=U color=C>Cap</video>` | `Figure ("",{"video"},{color=C}) (Caption … ) [Plain [Link ("",{},{}) [Cap] (U,"")]]` | ✏️ |
| `<audio>`, `<file>`, `<pdf>` | as `<video>`, differing only by class | ✏️ |
| `<page url=U color=C>Title</page>` | `Div ("",{"page"},{url=U,color=C}) [Plain Title]` | ✏️ |
| `<database url=U inline=B icon=E>` | `Div ("",{"database"},{url=U,inline=B,icon=E}) [Plain Title]` | ✏️ |
| `<table_of_contents/>` | `Div ("",{"table-of-contents"},{}) []` | ✏️ |
| `<synced_block url=U>` | `Div ("",{"synced-block"},{url=U}) [children…]` | ✏️ |
| `<synced_block_reference url=U>` | `Div ("",{"synced-block-reference"},{url=U}) [children…]` | ✏️ |
| `<unknown url=U alt=T/>` | `Div ("",{"unknown"},{url=U,alt=T}) []` | ✏️ |
| `<meeting-notes>` | `Div ("",{"meeting-notes"},{}) [children…]` | ✏️ |

Toggle headings and `<details>` toggles are **separate Notion block types and
get separate classes** (`toggle-heading` and `toggle`). An earlier draft gave
both the `toggle` class and distinguished them by whether the first child was
a `Header`; that made the difference implicit and positional, which would
break any filter that reordered or wrapped children. A toggle heading with no
children needs no wrapper at all, because `toggle="true"` lives on the
`Header`'s native `Attr`.

Media blocks use `Figure` rather than a plain `Div` for consistency with
`![Caption](URL)`, which pandoc already turns into a `Figure`. Captions land
in the native `Caption` slot and other writers render something meaningful
instead of an unstyled div.

### 4.4 Inline mapping

| NFM | pandoc | |
|---|---|---|
| `**b**` | `Strong` | ✅ |
| `*i*` | `Emph` | ✅ |
| `~~s~~` | `Strikeout` | ✅ |
| `` `c` `` | `Code` | ✅ |
| `[t](URL)` | `Link` | ✅ |
| `$eq$` | `Math InlineMath` | ✅ |
| `<br>` | `LineBreak` | ✅ |
| `<span underline="true">t</span>` | `Underline` | ✅ |
| `<span color=C>t</span>` | `Span ("",{},{color=C})` | ✅ |
| `:emoji_name:` | `Span ("",{"emoji"},{["data-emoji"]=name})` | ✅ |
| `[^URL]` | `Span ("",{"citation"},{url=URL}) []` | ✏️ |
| `<mention-user url=U>Ada</mention-user>` | `Span ("",{"mention","mention-user"},{url=U}) [Str "Ada"]` | ✏️ |
| `<mention-page>`, `<mention-database>`, `<mention-data-source>`, `<mention-agent>` | as above, differing only by second class | ✏️ |
| `<mention-date start=S end=E …/>` | `Span ("",{"mention","mention-date"},{start=S,end=E,…}) []` | ✏️ |

`[^URL]` maps to a `Span`, not pandoc's `Cite`. Notion's citation is a bare
source URL, whereas `Cite` expects an identifier resolvable against a
bibliography; using `Cite` would make citeproc emit unresolved-reference
warnings for well-formed input.

Every mention carries both a generic `mention` class and a specific
`mention-<kind>` class, so filters can match all mentions or one kind.

## 5. Architecture

### 5.1 Packaging

Each entry point begins with a prelude that puts its own directory on
`package.path` using `PANDOC_SCRIPT_FILE`:

```lua
local dir = PANDOC_SCRIPT_FILE:match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. package.path
```

Installation is "copy the directory"; invocation is by real path. Per §2.1
this breaks when the entry point is reached through a symlink, which is a
documented limitation rather than an engineered-around one. If it becomes a
problem, the fix is an amalgamation build step that concatenates the modules
into a single self-contained file per entry point. That is not built now.

### 5.2 Module layout

```
notion-markdown-reader.lua     Reader(input, opts)  — prelude and wiring only
notion-markdown-writer.lua     Writer(doc, opts)    — prelude and wiring only
notion/
  schema.lua        SHARED: the §4 mapping as one table
  attr.lua          SHARED: {key="value"} parse and serialize, color validation
  escape.lua        SHARED: the §3.1 escape set
  reader/tree.lua   text → tab-indented node tree (no pandoc types)
  reader/blocks.lua node tree → pandoc Blocks
  reader/inlines.lua RawInline folding → the §4.4 convention
  writer/blocks.lua pandoc Blocks → NFM lines (owns indent depth)
  writer/inlines.lua pandoc Inlines → NFM text
```

Rationale for the seams:

- `schema.lua` is the single source of truth both directions consult, and the
  target for the future block-JSON pair.
- `reader/tree.lua` is deliberately free of pandoc types: pure text in, plain
  Lua tables out. It carries the highest-risk logic (tab nesting, fence
  awareness, single-newline block separation) and can therefore be tested
  exhaustively with plain table assertions.
- The entry points hold wiring only, so no logic is reachable except through a
  named module.

## 6. Reader design

### 6.1 Inline delegation flavor

Inline content is parsed by pandoc's own (Haskell) markdown reader through
`pandoc.read`, using a pinned extension set rather than the full `markdown`
format:

```
markdown_strict +strikeout +tex_math_dollars +backtick_code_blocks
                +pipe_tables +task_lists +emoji +raw_html +all_symbols_escapable
```

The pin exists because full `markdown` fabricates constructs NFM lacks (§2.5).
It also has a simplifying consequence: without `native_spans`, **every** NFM
tag arrives uniformly as a balanced `RawInline "html"` pair, so
`reader/inlines.lua` needs one folding routine for the whole tag vocabulary
rather than separate paths for tags pandoc happens to parse natively.

### 6.2 `reader/tree.lua`

Two passes over the input.

**Pass 1 — classify lines, fence-aware.** A ` ``` ` fence toggles a literal
mode in which nothing is interpreted: no indent arithmetic, no attribute
peeling, no unescaping. This is exactly what §3.1 requires of code content.
Each line becomes `{indent, kind, text}` where `kind` is one of `fence_open`,
`fence_body`, `fence_close`, `tag_open`, `tag_close`, `self_closing`, `text`,
`blank`.

**Pass 2 — nest.** Indentation-nested blocks nest by tab depth; the closed set
of **multi-line** container tags (`callout`, `details`, `columns`, `column`,
`table`, `synced_block`, `synced_block_reference`, `meeting-notes`) nests by
tag balance. Tags that open and close on one line (`page`, `database`) or are
self-closing (`table_of_contents`, `empty-block`, `unknown`) are complete in a
single line node and never open a nesting level. Attribute suffixes are peeled here via `attr.lua`, so no downstream
module ever sees raw `{color="…"}` text.

Rules:

- **Indentation is strict tabs**, per §3.1. Leading spaces are not
  indentation.
- Inside tag-balanced containers, leading whitespace is cosmetic and stripped.
  This reconciles strict tabs with Notion's own documentation examples, which
  show space-indented `<callout>` and `<table>` children: nesting there is
  determined by tag balance, so the whitespace carries no meaning.
- **A single newline separates blocks** (§3.2). Each text line at a given
  indent is its own block. Blank lines are stripped.

### 6.3 `reader/blocks.lua`

Walks the node tree, dispatching through `schema.lua`. Groups consecutive
`-` / `1.` siblings at the same depth into `BulletList` / `OrderedList`.
Applies the §4.2 attribute rule.

Because each text line is its own block, a naive implementation would call
`pandoc.read` once per line. Instead, all leaf inline runs in a document are
batched into a **single** `pandoc.read` call, joined by `\n\n` so pandoc keeps
them as separate `Para`s, and mapped back positionally. If the returned block
count does not equal the chunk count — possible if a run's content is itself
block-like after marker stripping — the batch is discarded and the runs are
read individually. Correctness never depends on the optimization.

### 6.4 `reader/inlines.lua`

Folds balanced `RawInline (Format "html")` pairs into the §4.4 convention, and
handles the two syntaxes pandoc leaves as literal text under the pinned
extension set: `[^URL]` citations, and any `:emoji:` the `emoji` extension did
not already convert.

### 6.5 Malformed input

Recovered, never fatal, matching how pandoc's own readers treat bad HTML. An
unbalanced `</callout>` or an unrecognized tag is emitted as literal text.

## 7. Writer design

The writer is a plain global `Writer(doc, opts)` over two dispatch tables
keyed on `el.t`. It deliberately does **not** use `pandoc.scaffolding.Writer`,
because scaffolding's nesting goes through `pandoc.layout`, which indents with
spaces (§2.7), and NFM's nesting is tab-defined.

- `writer/blocks.lua` — `render(blocks, depth) → string`, prefixing `depth`
  literal tabs. Explicit depth threading is what layout could not provide, and
  it makes the one thing NFM is strictest about impossible to get subtly
  wrong. Blocks are joined with a **single** `\n` (§3.2).
- `writer/inlines.lua` — `render(inlines) → string`. No depth concern.
  Escaping via `escape.lua`, suppressed inside `Code` and `CodeBlock`.

Abandoning scaffolding costs its loud failure on unhandled elements. That
guarantee is replaced by the completeness test of §9.4 — moved from runtime to
CI, which is the right place for a converter that is required to degrade
rather than crash.

## 8. Lossy input policy

The writer will receive pandoc constructs Notion cannot express. The policy
matches what pandoc's own writers actually do, which was established by
testing rather than assumption.

**Observed pandoc behavior.** Its writers degrade footnotes, definition lists,
line blocks, small caps, sub/superscripts, and complex tables **silently**,
with a deterministic documented fallback and no warning at all. The only log
pandoc emits in this area is INFO-level, for content genuinely dropped:
`[INFO] Not rendering RawBlock (Format "latex")`.

**Our policy, accordingly:**

1. Every unsupported construct has a deterministic, documented fallback.
2. Degradation is **silent at default verbosity**.
3. `pandoc.log.info` is emitted only when content is genuinely **dropped**,
   phrased in pandoc's own style (e.g. `Not rendering BulletList inside table
   cell`).
4. No `--strict` flag. Round-trip verification is better served by
   `pandoc -f notion -t notion` and a diff than by a writer option.

**One deliberate divergence from pandoc.** Pandoc's markdown writers degrade
by falling back to raw HTML (`<span class="smallcaps">`, `<sub>`, a whole
`<table>`), because raw HTML is legal in markdown. NFM's HTML vocabulary is a
**closed set**, so an `<sub>` or a `class="smallcaps"` span would reach Notion
as literal text or be dropped. Our fallbacks must be NFM-native, which points
to the `plain` writer's strategy rather than the markdown writers':

| pandoc construct | NFM fallback |
|---|---|
| `Note` (footnote) | `[n]` marker inline, note body as endnote blocks at document end |
| `DefinitionList` | bold term, definition as an indented child block |
| `LineBlock` | `<br>` separated lines in one block (genuinely NFM-native) |
| `SmallCaps` | uppercased text |
| `Superscript` / `Subscript` | Unicode equivalents where they exist, else literal text |
| `Table` cell containing blocks | cell content flattened to rich text; **INFO logged** (a true drop) |
| `RawBlock` / `RawInline` in a foreign format | dropped; **INFO logged** |

## 9. Testing

All layers run under `pandoc lua` with no external dependencies (§2.8).

### 9.1 Unit tests for `reader/tree.lua`

Pure text in, plain tables out, no pandoc types. The riskiest module gets the
cheapest and most exhaustive tests: tab depth, fence awareness, tag balance,
single-newline block separation, attribute peeling.

### 9.2 Round-trip idempotence

The primary gate is **stability**: `nfm → AST → nfm` applied twice must
produce the same output the second time as the first (`f(f(x)) == f(x)`).
The user has explicitly waived byte-for-byte compatibility as a hard
requirement — official fixtures transcribed verbatim from Notion's docs are
not ours to reformat, so only stability is asserted for them
(`tests/roundtrip_test.lua`, `official` section). Byte-identity on the first
pass is an **additional**, stronger check that holds for the authored
corpus (fixtures written in canonical form), with a small pinned exception
list (`KNOWN_NOT_BYTE_IDENTICAL`) for cases with a documented reason not to
be. This is still self-checking: it needs no hand-written expected output,
so adding a fixture costs one file, and it catches the reader and writer
drifting apart even when neither is obviously wrong on its own.

### 9.3 AST goldens

`nfm → native`, diffed against checked-in `.native` files. These exist not for
correctness — §9.2 covers that — but to **pin the §4 convention**, so a
refactor cannot silently rename a class and still pass.

### 9.4 Completeness

A hardcoded list of pandoc's `Block` and `Inline` constructors, asserted
present in both writer dispatch tables. The live `.constructor` tables (§2.7)
are the primary, self-maintaining check; the hardcoded list is cross-checked
against that live enumeration in both directions and is pinned to the
pandoc version in §2.

### 9.5 Degradation

For each row of the §8 fallback table: a pandoc-side input document, the exact
expected NFM output, and an assertion about whether `[INFO]` was logged.
Silence is asserted as strictly as output, since §8 makes silence a
requirement rather than an absence.

### 9.6 Cross-format regression

NFM `<columns>` → reveal.js must produce a real two-column slide, protecting
the interoperability gained by adopting pandoc's existing convention (§2.6).

### 9.7 Corpus

```
tests/corpus/
  blocks/      one fixture per §4.3 row:
    paragraph · headings (incl. h5/h6 → h4) · toggle-heading · details ·
    lists-bullet · lists-ordered · todo ·
    quote (single, <br> multiline, and consecutive > lines as separate blocks) ·
    callout · code (language, mermaid, no escaping inside) · equation ·
    table (header-row/column, colgroup, cell colors, precedence) · divider ·
    empty-block · columns · media-image · media-av (audio/video/file/pdf) ·
    page-database · toc · synced-block · unknown-block · meeting-notes
  inlines/     emphasis · underline-color · links-math · mentions (all six) ·
               emoji · citation · linebreak
  nesting/     deep-tabs (4 levels) · callout-in-column ·
               list-with-block-children · single-newline-blocks ·
               fence-containing-nfm
  adversarial/ escapes (every character in the §3.1 set) ·
               literal-attrs (prose that merely looks like {color="x"}) ·
               unbalanced-tags · crlf-trailing-ws
  official/    every example from BOTH Notion doc pages of §3, verbatim,
               including the NFM payloads embedded in their API snippets
tests/degrade/ pandoc-side inputs, not NFM: footnote · deflist · lineblock ·
               smallcaps · subsup · nested-table
```

`fence-containing-nfm` and `literal-attrs` carry the most weight: both target
the failure mode §2.4 exposed, where a parser eagerly interprets syntax that
should have stayed text.

The `official/` fixtures are mandatory. Both doc pages are normative and
neither is complete alone, so covering both is what keeps the tag vocabulary
honest — it is precisely how `<unknown>` and `<meeting-notes>` were found.

## 10. Decision log

| Decision | Rationale |
|---|---|
| NFM pair first, block-JSON pair deferred | Smallest independently useful deliverable; shared convention makes the second pair cheap |
| Structural `Div`/`Span`, not `RawBlock` | Content stays visible and traversable in all formats; NFM's attribute syntax maps naturally onto pandoc `Attr` |
| Native `Attr` first, wrap only on need | Ordinary content stays ordinary; avoids a div around every paragraph |
| Hybrid reader: hand-written blocks, delegated inlines | §2.4 disproves full delegation; §2.5 shows inline delegation is clean and free |
| Pinned extension set, not `markdown` | Full `markdown` fabricates `Subscript` and `Cite` from plain text |
| Strict tabs on read as well as write | Matches the spec; tag-balanced containers make it compatible with Notion's own space-indented examples |
| Separate `toggle` and `toggle-heading` classes | Two distinct Notion block types; sharing a class would force implicit, positional discrimination |
| Media as `Figure` with a type class | Consistent with `![](…)`; captions use the native slot |
| `[^URL]` as `Span`, not `Cite` | It is a bare URL, not a bibliography key; `Cite` would trigger citeproc warnings |
| Plain writer, not `pandoc.scaffolding.Writer` | `pandoc.layout` indents with spaces; NFM requires tabs |
| Silent deterministic degradation | Matches measured pandoc writer behavior |
| NFM-native fallbacks, never raw HTML | NFM's HTML vocabulary is closed, unlike markdown's |
| Round-trip idempotence as the primary test | Self-checking; needs no hand-written expectations |

## 11. Success criteria

1. Every fixture in `tests/corpus/` round-trips stably (`f(f(x)) == f(x)`);
   the authored corpus additionally round-trips byte-identically on the
   first pass, with a small pinned exception list for documented cases that
   don't (byte-identity is a strong additional check, not the gate — the
   user has waived it as a hard requirement, see §9.2).
2. Every example from both Notion documentation pages parses and round-trips
   stably.
3. Every row of §4.3 and §4.4 has a passing golden test.
4. Every pandoc `Block` and `Inline` constructor is handled by the writer.
5. Every §8 fallback produces its documented output, with `[INFO]` emitted on
   true drops and nothing emitted otherwise.
6. NFM `<columns>` converts to a real two-column reveal.js slide.
7. The reader does not crash on any real Notion page, including one containing
   `<unknown>` tags.
