# notion-upload

Creates a Notion page from Notion block JSON, uploading local media and
reproducing block trees of any depth within the API's per-request limits.

```bash
pandoc --extract-media=media -f docx -t ../notion-block-writer.lua report.docx \
  | notion-upload --parent 24f1b2c3d4e5f6a7b8c9d0e1f2a3b4c5
```

`--extract-media` matters: it normalizes embedded images (docx, odt, epub) and
on-disk images into one directory of real files, which is the only case this
tool has to handle. Without it, a docx yields media references that resolve to
nothing, and pre-flight will say so before anything is created.

## Install

```bash
cd notion-upload && uv sync
```

Set `NOTION_TOKEN`, and share the parent page with your integration.

## Usage

| flag | purpose |
|---|---|
| `INPUT` | block JSON file; defaults to stdin |
| `--parent ID` | parent page, database or data source; an id or a Notion URL |
| `--title TEXT` | page title; defaults to the leading `heading_1`, which is then removed |
| `--base-dir DIR` | resolve relative media paths against this (default: the input's directory, or cwd) |
| `--dry-run` | run pre-flight, print the request plan, create nothing |
| `--token` | overrides `NOTION_TOKEN` |
| `-v` / `-q` | warning verbosity |

The created page URL goes to stdout alone; warnings and errors go to stderr.

## A note on trust

`notion-upload` reads whatever local files the block JSON refers to and
uploads them to Notion. That is the whole point when you are converting
your own document, and it is why relative and absolute paths both work.

It does mean the input document decides which files leave your machine.
Converting a document someone else wrote — and then uploading the result
without reading it — would let that document name any file you can read.
If you ever do that, check the media references first:

```bash
notion-upload doc.json --parent <id> --dry-run
```

## Exit codes

| code | meaning |
|---|---|
| 0 | success |
| 2 | bad input, missing title, or missing token |
| 3 | local media could not be resolved or uploaded |
| 4 | content exceeds a limit that splitting cannot fix |
| 5 | Notion rejected a request, or was unreachable |
| 6 | the page was created but is incomplete; the URL is still printed |

## Design

`docs/superpowers/specs/2026-08-30-notion-upload-cli-design.md`. The two ideas
worth knowing: a block inlines a leading run of its children up to the two
levels of nesting one request allows, taking a child that has children of its
own only when that child's entire subtree comes with it - which means every
block id the recursion needs arrives in a response it already reads, and a
`column_list` still reaches Notion with its columns, as Notion demands; and
splitting respects bytes as well as characters, because
Notion caps content in characters but caps requests in bytes.

## Tests

```bash
uv run pytest          # no pandoc, no network
make fixtures          # from the repo root, to regenerate corpus fixtures
```

Dev tooling (`pytest`, `hypothesis`, `ruff`) is declared in the `dev`
dependency group and installed by `uv sync`.

```bash
uv run ruff check .    # lint, or: make lint-py from the repo root
```
