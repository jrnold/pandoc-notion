# Pandoc Notion Filters

Pandoc custom readers and writers for the two formats Notion's APIs speak:
[Notion Flavored Markdown][nfm] (NFM), the enhanced markdown dialect of the
markdown endpoints, and Notion's block object JSON. Both target the same pandoc
AST convention, so converting between them is a matter of piping through
pandoc.

## Requirements

pandoc 3.10.2 or later. No other dependencies.

## Install

Copy this directory somewhere and invoke the entry points by real path:

```bash
git clone <this repo> ~/.local/share/pandoc-notion
```

Note: invoke by real path, not through a symlink. Pandoc reports the symlink
path in `PANDOC_SCRIPT_FILE`, so the sibling `notion/` modules would not be
found.

## Usage

```bash
# Notion markdown -> anything
pandoc -f ~/.local/share/pandoc-notion/notion-markdown-reader.lua \
       -t docx page.nfm -o page.docx

# Anything -> Notion markdown
pandoc -f docx -t ~/.local/share/pandoc-notion/notion-markdown-writer.lua \
       report.docx

# Round-trip (useful for verifying fidelity)
pandoc -f ...notion-markdown-reader.lua -t ...notion-markdown-writer.lua page.nfm
```

## AST convention

Notion constructs are represented structurally, as `Div` and `Span` with
classes and attributes, so content stays visible in every output format and
traversable by other Lua filters. See the design document for the full mapping
table: `docs/superpowers/specs/2026-08-28-notion-flavored-markdown-design.md`.

Where pandoc already had a convention, this project adopts it rather than
inventing one — columns (`Div class="columns"`), task lists (☐/☒ prefixes),
emoji, `Underline`, `Figure`, and math are all native.

## Known limitations

**Tabs inside fenced code blocks become spaces.** Pandoc expands tabs to
spaces before any custom reader runs; only the built-in `t2t`, `man`, and
`tsv` formats are exempted, via a hardcoded list in pandoc's source that a
custom Lua reader cannot join. NFM's own structural tab-nesting is
unaffected — the reader reconstructs indent levels from `--tab-stop`-wide
space runs, and the writer re-emits tabs — but a **literal tab typed inside a
fenced code block** (a Makefile recipe, gofmt'd Go source) is expanded to
spaces like any other input. A Makefile recipe with a tab expanded to spaces
breaks `make` ("missing separator"); gofmt'd Go gets silently reformatted.

**Mitigation:** pass `--preserve-tabs` on the pandoc command line when a
document contains code blocks whose content is tab-sensitive:

```bash
pandoc --preserve-tabs -f ...notion-markdown-reader.lua -t docx page.nfm
```

This limitation is pinned by `tests/corpus/adversarial/tab-in-fence.nfm` and
`tests/tab_in_fence_test.lua`.

**`--tab-stop` is honored for indentation.** One NFM indent level is either a
literal tab or a run of `--tab-stop` spaces (default 4), matching pandoc's
own convention for that flag.

**An attribute value containing a literal `>` breaks tag parsing.** Tag
scanning ends an opening tag at the first `>`, so
`<callout icon="a>b">hi</callout>` is read as a `<callout>` whose body is
`b">hi`, and the `icon` is lost. No realistic NFM attribute value (a colour
name, a URL, a date, an emoji) contains `>`, so this is documented rather
than worked around.

## Lossy conversion

Constructs Notion cannot express are degraded deterministically and silently,
matching how pandoc's own writers behave. `[INFO]` is logged (visible under
`--verbose`) only when content is genuinely dropped. Fallbacks are NFM-native
rather than raw HTML, because NFM's HTML vocabulary is a closed set.

## Tests

```bash
pandoc lua tests/run.lua
```

## Linting

```bash
luacheck .
```

Optional, and the only tool outside pandoc this repo mentions — the test
suite itself still has zero dependencies. `brew install luacheck`, or
`luarocks install luacheck`.

### Type checking

```bash
lua-language-server --check . --checklevel=Warning
```

Also optional. `brew install lua-language-server`. Type information comes from
LuaCATS annotations in `types/pandoc-annotations/` — comments only, so they have
no effect on `pandoc lua`. See that directory's README for provenance.

### Configuration

`.luacheckrc` declares pandoc's globals as read-only. That list was enumerated
from the interpreter rather than copied from documentation:

```bash
pandoc lua -e 'for k in pairs(_G) do print(k) end'
```

pandoc ships no `.luacheckrc` of its own, so there is no upstream config to
follow; the settings here follow pandoc's *calling* conventions instead — each
entry point defines exactly one global (`Reader` or `Writer`), declared
per file so a stray global anywhere else is still reported.

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
against a database schema. See §12.3 of the design document.

**Server-owned metadata is dropped.** Only the block `id` survives, in the
pandoc `Attr` identifier slot. Timestamps, `created_by`, `last_edited_by`,
`parent`, `archived` and `in_trash` are all re-derived by the server and are
rejected on write.

**NFM can say a few things the block API cannot.** Converting NFM → JSON → NFM
loses six NFM-only constructs, because the corresponding Notion block has no
field for them at all:

| lost | why |
|---|---|
| `url` on `<page>`, `<database>` | `child_page`/`child_database` carry only `title` |
| `inline` on `<database>` | no such field on the block |
| `url` on an original `<synced_block>` | an original has `synced_from: null` and no url |
| `url` on `<unknown>` | `unsupported` carries only `block_type` |
| `{color=}` on an image | Notion's image block has no colour field |
| `:shortcode:` spelling of an emoji | Notion stores the character, not the name |
| `[^URL]` citation | no citation construct; degrades to a link on the URL, preserving the source |

This is the mirror of the better-known asymmetry in the other direction, where
the API's block-type set is larger than NFM's. Inventing fields for these would
emit JSON the API rejects. Each case is enumerated with its reason in
`tests/crosspair_test.lua`; everything else round-trips unchanged.

[nfm]: https://developers.notion.com/guides/data-apis/enhanced-markdown
