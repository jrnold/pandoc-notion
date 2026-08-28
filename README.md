# Pandoc Notion Filters

Pandoc custom readers and writers for [Notion Flavored Markdown][nfm] (NFM),
the enhanced markdown dialect spoken by Notion's markdown API endpoints.

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

## Lossy conversion

Constructs Notion cannot express are degraded deterministically and silently,
matching how pandoc's own writers behave. `[INFO]` is logged (visible under
`--verbose`) only when content is genuinely dropped. Fallbacks are NFM-native
rather than raw HTML, because NFM's HTML vocabulary is a closed set.

## Tests

```bash
pandoc lua tests/run.lua
```

## Not yet implemented

`notion-block-reader` and `notion-block-writer`, which convert Notion's block
object JSON to and from the pandoc AST. They are a separate sub-project and
will target the same AST convention, at which point NFM ↔ block-JSON
conversion falls out of piping through pandoc.

[nfm]: https://developers.notion.com/guides/data-apis/enhanced-markdown
