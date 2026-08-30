# notion-upload: A Block JSON Uploader for the Notion API

Date: 2026-08-30
Status: Approved for planning
Scope: `notion-upload/` — a Python package, distinct from the Lua filters

Third sub-project in the sequence begun by
`2026-08-28-notion-flavored-markdown-design.md` and continued by
`2026-08-28-notion-block-json-design.md`. Both of those documents list "any
Notion API client" as explicitly out of scope and deferred; §8.2 of the block
JSON design goes further and names the thing deferred to:

> A script that uploads via the API must handle chunking and splitting to
> respect those limits. Placing that responsibility in the uploader rather
> than the writer keeps the writer a pure, predictable function of the AST.

This document specifies that uploader. Nothing here changes the Lua tree.

## 1. Purpose and scope

Take Notion block object JSON — the output of `notion-block-writer.lua`, or of
anything else that emits the same shape — and create a Notion page from it,
handling the two things the writer deliberately refuses to handle: media that
lives on the local disk, and documents whose nesting or size exceeds what a
single API request accepts.

```bash
pandoc -f docx -t notion-block-writer.lua report.docx \
  | notion-upload --parent 24f1b2c3d4e5f6a7b8c9d0e1f2a3b4c5
```

### In scope

- A CLI that reads block JSON from stdin or a file and creates one new Notion
  page from it.
- Uploading local media of every type the writer emits (`image`, `video`,
  `audio`, `pdf`, `file`) through Notion's File Upload API.
- Planning and executing the append requests needed to reproduce a block tree
  of arbitrary depth and size within the documented API limits.
- Splitting content that exceeds per-block limits, deterministically and with
  a warning.
- A test suite that does not require pandoc or network access.

### Out of scope

- Updating, replacing, or appending to an existing page. v1 creates pages.
- Downloading from Notion. The readers already exist; a `notion-download`
  is a separate sub-project if it is ever wanted.
- Invoking pandoc. The package's input contract is block JSON; conversion is
  the caller's business, exactly as conversion was the *filters'* business and
  uploading was not.
- Re-hosting remote media. An `http(s)` URL in the input passes through as an
  `external` file object, because the author wrote a URL and meant one.
  §11.2 records the cheap path if this is ever revisited.
- Writing page properties beyond `title`. This inherits the block JSON
  design's §12.3 deferral for the same reason: validation needs the data
  source schema.

### Why a distinct package

The Lua tree's defining constraint is that it depends on nothing but pandoc.
An uploader cannot honor that — pandoc 3.11's Lua exposes only
`pandoc.mediabag.fetch`, a GET, with no POST and no multipart (§2.1). Rather
than dilute the constraint, this sub-project takes the mirror-image one: the
uploader depends on nothing but Python and its declared dependencies, and
never shells out to pandoc, not even in its tests.

The two halves compose through a pipe and a documented JSON shape. Neither
imports the other.

## 2. Verified facts

Following the convention of both companion documents, facts here were
confirmed rather than assumed. Re-verify when `Notion-Version` changes.

### 2.1 pandoc's Lua cannot make the required requests

`pandoc.mediabag` exposes `delete`, `items`, `list`, `fill`, `lookup`,
`empty`, `fetch`, `make_data_uri`, `write`, `insert`. `fetch` is a GET. There
is no POST, no multipart encoder, and no third-party HTTP module on
`package.path`:

```
$ pandoc lua -e 'print(pcall(function() return require("http.request") end))'
false   module 'http.request' not found
```

This is what rules out implementing the uploader in Lua alongside the filters.

### 2.2 `--extract-media` normalizes every input format to one case

Run on a markdown file with a local image:

```
$ pandoc --extract-media=media -f markdown -t notion-block-writer.lua doc.md
… "external":{"url":"media/img.png"} …
$ find media -type f
media/img.png
```

Pandoc copies the file into the directory and rewrites the URL to a relative
path. For `docx`, `odt` and `epub` — where images are embedded in the
container rather than on disk — the same flag extracts them to the same place
with the same rewriting.

The consequence for this design is that media discovery has exactly one case
to handle: a relative or absolute filesystem path in `external.url`. It does
not need to know the input format, and it does not need to read containers.

The consequence for *users* is that `--extract-media` is mandatory for
embedded-media formats and the uploader cannot supply it on their behalf.
§6.1 makes that a first-class diagnostic.

### 2.3 The documented limits, including two the companion document missed

`2026-08-28-notion-block-json-design.md` §3.5 lists: 100 block children per
append request; two levels of nesting per request; `text.content` ≤ 2000;
`equation.expression` ≤ 1000; URLs ≤ 2000; `rich_text` arrays ≤ 100 elements.

Two further limits apply per request and are load-bearing here:

| limit | value |
|---|---|
| total block elements per request, counting nested | 1000 |
| total serialized payload | 500 KB |

The 500 KB cap is the one that changes the design: a document can sit
comfortably under 100 children and still be refused, because a handful of
large code blocks blew the byte budget. The planner therefore packs against
bytes as well as counts (§5.2).

`POST /v1/pages` accepts up to 100 `children` in the creation request itself.

### 2.4 Rate limiting and retryable failures

Roughly three requests per second per connection, with bursts tolerated.
Rate limiting returns `429` with a `Retry-After` header in seconds. Temporary
overload returns `529` with error code `service_overload`.

### 2.5 The File Upload API

```
POST /v1/file_uploads
  body: mode ∈ {single_part, multi_part, external_url}, filename,
        content_type, number_of_parts (multi_part only)
  → { id, upload_url, status ∈ {pending,uploaded,expired,failed}, expiry_time }

POST /v1/file_uploads/{id}/send
  multipart/form-data, file bytes in a field named `file`
  part_number required only for multi_part
  → 200, status becomes "uploaded"

POST /v1/file_uploads/{id}/complete    (multi_part only)
```

Files over 20 MiB must use `multi_part`. Per-file ceilings are 5 MiB on free
workspaces and 5 GiB on paid ones.

### 2.6 Parent shapes and the title property

`POST /v1/pages` accepts a `parent` of `page_id`, `database_id`,
`data_source_id`, or `workspace`. `database_id` has not been removed in favor
of `data_source_id`; both remain valid.

When the parent is a page, `title` is the **only** valid key in `properties`.

### 2.7 Append responses identify only top-level blocks

`PATCH /v1/blocks/:id/children` returns a paginated list whose `results` array
holds the newly created blocks in creation order. It reports the ids of the
blocks in the request's top-level array. It does not report ids for blocks
nested inside those blocks' `children`.

This single fact determines the planner's central rule (§5.1). Recovering a
nested child's id would require a follow-up `GET /v1/blocks/:id/children`.

### 2.8 The markdown endpoints cannot reference uploaded files

`POST /v1/pages` (via the `markdown` body param) and
`PATCH /v1/pages/:page_id/markdown` accept Notion Flavored Markdown, and the
server performs all nesting and chunking itself. Their media syntax admits
only external URLs; there is no spelling for a `file_upload` id.

This is why the uploader targets block JSON. §10 records the alternative in
full, because it would otherwise look like an oversight: if uploading local
media were not a requirement, the markdown endpoint would be the better design
by a wide margin.

## 3. Architecture

```
                         ┌─ media on disk (via pandoc --extract-media)
   block JSON  ──────────┤
   (stdin or file)       └─ external.url = "media/img.png"
        │
   ┌────┴──────────────────────────────────────────────┐
   │  PRE-FLIGHT — nothing exists in Notion yet         │
   │   1. document.parse    validate the envelope       │
   │   2. retrieve_parent   is the target reachable?    │
   │   3. limits.normalize  merge runs, split overflow  │
   │   4. media.resolve     local refs → real files     │
   │   5. media.upload      dedupe by hash → file_upload│
   │   6. planner.plan      tree → ordered request waves│
   └────┬──────────────────────────────────────────────┘
        │            ── point of no return ──
   7. POST /v1/pages  (empty; see §5.4)
   8. PATCH /v1/blocks/{id}/children, wave by wave
```

Two orderings inside pre-flight are load-bearing rather than arbitrary:

**Normalization precedes media discovery.** `normalize` rebuilds every block
it touches, so references to file objects captured beforehand would point at
payload dictionaries no longer in the tree. Rewriting them would mutate
orphans while the blocks actually uploaded kept their local paths — a bug that
produces a page full of broken images and no error at all.

**The parent is checked first.** It costs one cheap request, and discovering
that the target is unreachable *after* uploading forty megabytes of images
would be an unforced insult.

### 3.1 Module layout

`notion-upload/src/notion_upload/`:

| module | responsibility |
|---|---|
| `cli.py` | argument parsing, exit codes, diagnostics |
| `document.py` | parse and validate the incoming JSON envelope |
| `media.py` | discover, resolve, dedupe and upload local media |
| `limits.py` | the documented constants; splitting and normalization |
| `planner.py` | block tree → ordered waves of append requests |
| `client.py` | auth, `Notion-Version`, rate limiting, retry |
| `errors.py` | the exception hierarchy that maps to exit codes |

The split that matters is `planner` from `client`. Planning is a pure
function of a tree and a limit set; it performs no I/O, and the whole of §9's
test strategy rests on that.

### 3.2 No Lua changes are required

`notion/block/writer_custom.lua:82` already emits
`{"type":"file_upload","file_upload":{"id":…}}` when a `Figure` carries a
`data-file-upload-id` attribute, and `{"type":"external","external":{"url":…}}`
otherwise. The uploader rewriting an `external` node to a `file_upload` node
produces output byte-identical to what that hook produces.

The hook therefore remains useful to anyone driving the writer directly with
ids they already hold, and the uploader needs no cooperation from it.

## 4. Input contract

Accepted: a bare JSON array of block objects, which is what
`notion-block-writer.lua` emits. Also accepted, for symmetry with the reader's
`notion/block/envelope.lua`: a list response
(`{"object":"list","results":[…]}`) and a page object.

Rejected with a diagnostic naming the accepted shapes: anything else.

Blocks are read as the forgiving superset the writer produces. `children` may
appear nested inside the type payload, which is where the writer puts it and
what the append endpoints accept.

Any `id` present on an input block (which the writer emits only under
`-V preserve-ids`) is **discarded**. Ids belong to the server; sending one is
rejected. This mirrors the reader's treatment of server-owned metadata.

## 5. The planner

The interesting part of the tool, and the part the two companion documents
deferred to it.

### 5.1 The inlining rule

> A block carries inline the **longest leading run** of its children that are
> leaves and that fit within the per-request bounds. Everything from the first
> child with children of its own, or the first child that would breach a
> bound, is deferred to a wave keyed to the id the response hands back.

The leaf condition follows from §2.7. Because a response identifies only
top-level blocks, any block whose id we will later need to append to must
itself appear at the top level of some request. A child with children is a
child we will need an id for; therefore it cannot be inlined.

**A leading run, not an arbitrary subset.** Deferred children are *appended*
to the parent, so they land after whatever was already inlined. Taking a
prefix is therefore exactly what preserves document order — and it comes free,
with no use of the `position` parameter.

The payoff is that **no `GET` is ever required**. Every id the recursion needs
arrives in a `results` array it already had to read.

**The bound that is easy to miss.** The 100-children cap applies to *every*
`children` array, not only the array at the top level of a request. An
all-or-nothing rule — inline every child or none — emits a block with 120
inlined children whenever no child has children of its own: one legal-looking
request, rejected by the API. The run is therefore capped at 100 as well as by
elements and bytes.

This was found by construction, not in production: an earlier draft of this
section used the all-or-nothing rule, and it survived review because the test
fake validated only the request's own children array. The fake now validates
every array at every depth (§9.1).

Worked on `A` with 120 leaf children:

```
PATCH page/children      [A + 100 inlined leaves]
PATCH A/children         [the remaining 20]        2 requests, both legal
```

Worked on `A > B₁..B₅₀`, each `Bᵢ` holding one leaf `Cᵢ`:

```
POST  /v1/pages          children: [A]                (A has grandchildren)
PATCH A/children         [B₁+C₁, …, B₅₀+C₅₀]          (each Bᵢ inlines its leaf)
                                                       2 requests
```

Stripping children unconditionally and recursing costs 52 requests for the
same tree. On a 4-level spine the rule ties the alternative design that inlines
two levels and pays for a `GET` to recover the ids — three requests either
way — so there is no shape on which the `GET` version wins.

### 5.2 Packing

Within one wave — appending an ordered list of blocks to one parent — blocks
are packed greedily into requests bounded simultaneously by:

- ≤ 100 top-level children
- ≤ 1000 total block elements, counting inlined children
- ≤ 500 KB serialized
- ≤ 2 levels of nesting, which §5.1 guarantees structurally

A block whose inlined children push it past a limit even in an otherwise
empty request is **stripped and deferred**: it is sent childless, and its
children become a wave of their own. This is the same transformation §5.1
applies for depth, applied here for size, and it is always available because
§7.2 guarantees that a *childless* block always fits alone.

Together those two facts make the packer total: every block is sendable,
either with its children or without them, and the recursion terminates because
each deferral strictly reduces the depth of what remains.

### 5.3 Ordering

Waves execute sequentially in document order, not breadth-first.

Sequential rather than parallel: at three requests per second, concurrency
buys almost nothing, and a deterministic order makes a failure reproducible
and reportable by block index.

Document order rather than breadth-first: both leave a partial page on
failure, but document order leaves *the first portion of the document,
complete*, which a reader can use. Breadth-first would leave the whole
document present but stripped of its nested detail, which is worse to
discover and harder to repair by hand.

### 5.4 The first wave rides along

`POST /v1/pages` accepts up to 100 children (§2.3), so the first wave is
carried by the creation request rather than following it. This saves a
request and, more importantly, shrinks the window in which a partial page can
exist: page creation and the first batch now succeed or fail together.

## 6. Media

### 6.1 Discovery and resolution

Walk every file object in the tree. A `{"type":"external","external":{"url":U}}`
is a local media reference when `U` has no scheme, or the scheme is `file:`.
`http:`/`https:` URLs pass through untouched. `data:` URIs are decoded to
bytes and uploaded like any other file.

Relative paths resolve against `--base-dir`, defaulting to the process's
working directory — correct whenever pandoc was run from the same place.

Unresolvable references are collected and reported together, never one at a
time, with the remedy named:

```
error: 3 media references could not be resolved relative to /home/j/docs
  media/image1.png, media/image2.png, media/image3.png
  If the source was docx/odt/epub, re-run pandoc with --extract-media=media
```

This runs in pre-flight phase 2, so nothing exists in Notion when it fires.

### 6.2 Upload

Files are deduplicated by content hash before upload: an image used five times
in a document is uploaded once and referenced five times.

Per file: `POST /v1/file_uploads` to obtain an id and `upload_url`, then
`POST /v1/file_uploads/{id}/send` with the bytes in a `file` field. Files over
20 MiB use `multi_part` mode, sending numbered parts and finishing with
`POST /v1/file_uploads/{id}/complete`.

`content_type` is inferred from the file extension, falling back to sniffing
the leading bytes, falling back to `application/octet-stream`.

Uploads are the one place concurrency is worth having, since each file costs
at least two round trips. They run with bounded concurrency under the same
rate limiter as everything else.

On success the node is rewritten in place:

```json
{"type": "file_upload", "file_upload": {"id": "…"}}
```

`caption` and every other sibling key are preserved.

## 7. Limits and degradation

### 7.1 Normalization, which is lossless

Before any splitting, adjacent `rich_text` elements with identical annotations
and no link are merged. Pandoc's AST routinely produces runs that fragment at
word boundaries, and merging them first both reduces element counts below the
100 cap in most real documents and produces cleaner Notion output.

### 7.2 Splitting, which is not

Two cases exceed what a single Notion block can hold:

- a `text.content` longer than 2000 characters, split at the limit — this is
  invisible in the rendered page, since Notion concatenates the runs;
- a block whose `rich_text` array still exceeds 100 elements after merging, or
  whose serialized size exceeds the 500 KB request cap, which cannot be
  represented as one block at all.

Splitting is driven by **both** bounds, not just the element count, because
they do not agree. Notion caps `text.content` at 2000 *characters* but caps a
request at 500 *kilobytes*, so the worst case depends on the encoding:

| content | 100 elements × 2000 chars |
|---|---|
| ASCII | 210 KB — fits |
| CJK (3 bytes/char) | 600 KB — exceeds the request cap alone |

An element-count-only rule would therefore emit a legal-looking block that no
request can carry. Splitting against bytes as well makes the guarantee §5.2
depends on hold unconditionally: **after normalization, every childless block
fits alone in an empty request.**

Either case is split into **consecutive sibling blocks of the same type**,
with a warning naming the block by index:

```
warning: code block at index 41 exceeds 100 rich_text runs
  split into 2 consecutive code blocks
```

This follows the house style established in both companion documents:
degrade deterministically and keep going, rather than refuse a document the
converter understood perfectly well. It is the same decision §8 of the block
JSON design made about lossy input, applied one layer further out.

`equation.expression` over 1000 characters and URLs over 2000 characters
cannot be split without changing meaning. These are pre-flight errors.

## 8. Failure model

The phase ordering in §3 exists to serve one property: **everything that can
fail for a reason the user can fix, fails before anything is created.**
Missing media, unresolvable paths, oversized equations, malformed input, an
unreachable parent — all of it is pre-flight.

After the point of no return the only remaining failures are network and
rate-limit ones. `429` is retried after `Retry-After`; `529` and `5xx` are
retried with exponential backoff and jitter. A request that still fails leaves
the partial page in place and reports it:

```
error: page created but incomplete
  https://notion.so/abc123
  failed appending children of block #204 (depth 3)
  12 of 18 requests succeeded
```

The page is not archived on failure. Rollback can itself fail, and a partial
page is something the user can inspect and finish by hand; a deleted one is
not. Exit code is non-zero and the page URL still goes to stdout, so a
wrapping script can find it.

## 9. Testing

`pytest`, with no pandoc and no network.

### 9.1 A constraint-enforcing fake, not a mock

An in-process fake Notion that rejects exactly what Notion rejects: more than
100 entries in **any** children array at **any** depth, more than 1000
elements, more than 500 KB, more than two levels of nesting, an `id` on an
inbound block.

The "any depth" part is load-bearing rather than thorough-for-its-own-sake. An
earlier fake checked only the request's own children array, and that gap let
the all-or-nothing inlining rule described in §5.1 pass review while emitting
payloads the API would have rejected. It assigns fresh uuids and returns
`results` in creation order. It can be instructed to answer `429` with a
`Retry-After`, which is the only honest way to exercise the backoff path.

A permissive mock would accept plans that Notion refuses. A strict fake turns
every planner bug into a failing test.

### 9.2 The round-trip invariant

Plan a tree, execute the plan against the fake, read the fake's resulting tree
back, and assert it equals the input — in order, at every depth.

That one property covers the entire class of index-misalignment bugs this
recursion is prone to, which are also the worst bugs it could have: a
paragraph silently attached to the wrong parent.

### 9.3 Property-based generation

The invariant above is checked under Hypothesis over generated trees varying
in depth, fan-out, and text size, together with the limit assertions:

```python
@given(block_trees())
def test_plan_roundtrips(tree):
    plan = planner.plan(tree, LIMITS)
    for req in plan:
        assert req.count <= 100
        assert req.elements <= 1000
        assert req.bytes <= 500_000
        assert req.depth <= 2
    assert fake.execute(plan) == tree
```

Hand-written boundary cases are kept alongside for shapes worth naming — a
3-deep spine at exactly 100 children, an empty `children` array, a single
block at exactly 500 KB — but generation is what finds the rest.

### 9.4 Fixtures generated from the existing corpus

`tests/corpus/blocks/*.nfm` already covers callouts, columns, synced blocks,
nested tables and toggle headings — the shapes that actually occur. A
`make fixtures` target runs pandoc over that corpus into checked-in JSON under
`notion-upload/tests/fixtures/`, mirroring the `regenerate_block_goldens.lua`
pattern already in the repo.

Pandoc runs at regeneration time, never at test time. The suite keeps its
zero-dependency posture, and a change to the writer's output shows up as a
reviewable fixture diff rather than as a mysterious failure.

### 9.5 Media

Upload paths are tested against the fake: dedup by hash, the multi-part
threshold, content-type inference, and the unresolvable-reference diagnostic.
No real files leave the machine.

## 10. Decision log

| decision | why | rejected alternative |
|---|---|---|
| Python, not Lua | pandoc's Lua has no POST or multipart (§2.1) | Lua shelling out to `curl`: subprocess per request, hand-rolled multipart |
| Block JSON, not the markdown endpoint | markdown media cannot name a `file_upload` id (§2.8) | the markdown endpoint, which would make nesting the server's problem and would win outright if media were external-only |
| Distinct package, same repo | keeps the spec/plan rhythm and one corpus; neither half imports the other | a separate repo, splitting the design docs and making JSON-contract changes a two-repo dance |
| JSON in, no pandoc subprocess | the uploader depends on nothing but Python, mirroring the Lua half's discipline; useful to any producer of block JSON | invoking pandoc internally, which would re-entangle the halves and put pandoc in the test path |
| Inline the longest leading run of leaf children | every id the recursion needs arrives in a `results` array; no `GET` ever (§5.1) | inline two levels and `GET` to recover ids: equal request count, more code, more failure modes |
| A prefix, not a subset | deferred children are appended, so they land after the inlined ones; a prefix preserves order for free | arbitrary subsets plus the `position` parameter to reorder |
| Cap the inlined run at 100 | the children cap applies to every array at every depth, not just the request's own (§5.1) | all-or-nothing inlining, which emits a 120-child array the API rejects |
| Sequential, document order | reproducible; a partial page is the first *N* sections complete | breadth-first, leaving a whole document stripped of nested detail |
| Split oversized blocks, warn | matches how both companion documents degrade rather than refuse | hard error, which lets one pathological block block a 400-block upload |
| Split against bytes as well as element count | Notion caps content in characters and requests in bytes; multibyte text makes them disagree (§7.2) | element count alone, which emits a legal-looking block no request can carry |
| Leave the partial page | rollback can fail; a partial page can be finished by hand | archiving on failure, destroying recoverable work |
| Title from `--title`, else leading `heading_1` | Notion renders the title as the page H1, so keeping it would duplicate it | requiring `--title` always, repeating what the document states |

## 11. Follow-up work

### 11.1 The operations v1 leaves out

Replace, append-to-existing, and download were all considered and cut. Append
is nearly free once `planner` and `client` exist — it is the same recursion
against an existing parent id. Replace additionally needs the children of the
target deleted first, which is not atomic and deserves its own thinking about
what a mid-flight failure means.

### 11.2 Re-hosting remote media

`POST /v1/file_uploads` supports `mode: "external_url"`, in which Notion
fetches the URL itself. Should re-hosting ever be wanted, that is the
implementation: no bytes pass through this process at all, and it is one
extra mode in `media.py` rather than a download path.

### 11.3 Page properties

Creating a page under a data source parent means writing properties that must
validate against that source's schema — the same problem §12.3 of the block
JSON design deferred. v1 writes `title` only and therefore works cleanly under
a page parent; a data source parent with required properties will be rejected
by the API with a message naming them.

## 12. Success criteria

1. `pandoc -f docx -t notion-block-writer.lua doc.docx | notion-upload --parent ID`
   creates a page whose content matches the source, including images.
2. A document 5 levels deep and 500 blocks long uploads correctly, with the
   resulting tree equal to the input tree at every depth.
3. Every request the planner emits satisfies all four documented per-request
   limits, verified under property-based generation over trees that include
   multibyte text, where the character and byte bounds disagree.
4. Missing media, malformed input, and unreachable parents all fail before
   any page is created.
5. A failure after creation reports the page URL and the failing block index,
   and leaves the page in place.
6. The test suite passes with neither pandoc nor network access available.
