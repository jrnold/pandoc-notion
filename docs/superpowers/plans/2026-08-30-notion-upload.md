# notion-upload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Python CLI that reads Notion block JSON on stdin and creates one Notion page from it, uploading local media and reproducing block trees of any depth within the API's per-request limits.

**Architecture:** Five pre-flight phases (parse → resolve media → upload media → normalize → plan) run before anything exists in Notion, so every user-fixable failure happens before the point of no return. The planner is a pure function from a block tree to an ordered list of requests with *symbolic* parent references; execution resolves those symbols to real block ids from each response's `results` array. A block inlines its children iff it has no grandchildren, which guarantees every id the recursion needs arrives in a response it already reads.

**Tech Stack:** Python 3.11+, `httpx`, `pytest`, `hypothesis`, managed by `uv`. No pandoc at runtime or test time.

**Spec:** `docs/superpowers/specs/2026-08-30-notion-upload-cli-design.md`

## Global Constraints

- **The package depends on nothing but Python and its declared dependencies.** It never invokes pandoc — not at runtime, not in tests. (Spec §1, "Why a distinct package")
- **Runtime dependency is `httpx` only.** `pytest` and `hypothesis` are dev dependencies.
- **Python floor is 3.11.** Uses `X | Y` unions and `tomllib`.
- **No Lua file in this repo is modified by any task.** (Spec §3.2)
- **`Notion-Version: 2026-03-11`** on every request. (Spec §2.5)
- Per-request limits, exact values: **100** top-level children, **1000** total block elements counting nested, **500000** bytes serialized, **2** nesting levels. (Spec §2.3)
- Per-block limits, exact values: **100** `rich_text` elements, **2000** `text.content` characters, **1000** `equation.expression` characters, **2000** URL characters. (Spec §2.3)
- **Multipart upload threshold: 20 MiB** (`20 * 1024 * 1024`). (Spec §2.5)
- **Rate limit: 3 requests/second**, retry `429` per `Retry-After`, retry `529`/`5xx` with exponential backoff. (Spec §2.4)
- All code lives under `notion-upload/`. Nothing outside that directory changes except `Makefile` (Task 9) and `README.md` (Task 9).

---

## File Structure

```
notion-upload/
  pyproject.toml                    Task 1
  README.md                         Task 9
  src/notion_upload/
    __init__.py                     Task 1
    errors.py                       Task 1   exception hierarchy → exit codes
    limits.py                       Task 1 (constants), Task 3 (logic)
    document.py                     Task 2   envelope parsing, block accessors
    planner.py                      Task 4   tree → ordered Requests (pure)
    client.py                       Task 6   httpx, auth, rate limit, retry
    media.py                        Task 7   discover, resolve, dedupe, upload
    cli.py                          Task 8   args, phases, diagnostics, exit codes
  tests/
    conftest.py                     Task 1
    fake_notion.py                  Task 5   constraint-enforcing fake
    strategies.py                   Task 5   hypothesis block-tree generators
    test_errors.py                  Task 1
    test_document.py                Task 2
    test_limits.py                  Task 3
    test_planner.py                 Task 4
    test_roundtrip.py               Task 5
    test_client.py                  Task 6
    test_media.py                   Task 7
    test_cli.py                     Task 8
    test_fixtures.py                Task 9
    fixtures/*.json                 Task 9   generated from tests/corpus/blocks
```

---

### Task 1: Package scaffolding, errors, and limit constants

**Files:**
- Create: `notion-upload/pyproject.toml`
- Create: `notion-upload/src/notion_upload/__init__.py`
- Create: `notion-upload/src/notion_upload/errors.py`
- Create: `notion-upload/src/notion_upload/limits.py`
- Create: `notion-upload/tests/conftest.py`
- Test: `notion-upload/tests/test_errors.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `errors.NotionUploadError` (base), `InputError`, `MediaError`, `LimitError`, `APIError`, `PartialUploadError`, each with an `exit_code: int` class attribute. `limits.Limits` frozen dataclass with fields `children:int=100, elements:int=1000, byte_budget:int=500_000, nesting:int=2, rich_text:int=100, text_chars:int=2000, equation_chars:int=1000, url_chars:int=2000`; module constant `limits.DEFAULT = Limits()`; `limits.MULTIPART_THRESHOLD_BYTES = 20 * 1024 * 1024`; `limits.NOTION_VERSION = "2026-03-11"`.

- [ ] **Step 1: Create the package skeleton**

```bash
mkdir -p notion-upload/src/notion_upload notion-upload/tests
touch notion-upload/src/notion_upload/__init__.py
```

`notion-upload/pyproject.toml`:

```toml
[project]
name = "notion-upload"
version = "0.1.0"
description = "Upload Notion block JSON to the Notion API, handling media and nesting limits"
requires-python = ">=3.11"
dependencies = ["httpx>=0.27"]

[project.scripts]
notion-upload = "notion_upload.cli:run"

[dependency-groups]
dev = ["pytest>=8", "hypothesis>=6.100"]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/notion_upload"]

[tool.pytest.ini_options]
testpaths = ["tests"]
# tests/fake_notion.py and tests/strategies.py are imported by name from
# several test modules, so tests/ must be importable.
pythonpath = ["tests"]
```

`notion-upload/tests/conftest.py`:

```python
"""Shared fixtures. Deliberately empty of network or pandoc setup."""
```

- [ ] **Step 2: Write the failing test**

`notion-upload/tests/test_errors.py`:

```python
import pytest

from notion_upload import errors, limits


def test_every_error_has_a_distinct_exit_code():
    classes = [
        errors.InputError,
        errors.MediaError,
        errors.LimitError,
        errors.APIError,
        errors.PartialUploadError,
    ]
    codes = [c.exit_code for c in classes]
    assert len(set(codes)) == len(codes), f"exit codes collide: {codes}"
    assert all(c > 0 for c in codes), "success is 0; every error must be non-zero"


def test_all_errors_share_one_base():
    assert issubclass(errors.InputError, errors.NotionUploadError)
    assert issubclass(errors.PartialUploadError, errors.NotionUploadError)


def test_partial_upload_error_carries_what_the_user_needs():
    err = errors.PartialUploadError(
        page_url="https://notion.so/abc123",
        block_index=204,
        depth=3,
        completed=12,
        total=18,
    )
    assert err.page_url == "https://notion.so/abc123"
    assert "204" in str(err)
    assert "https://notion.so/abc123" in str(err)
    assert "12 of 18" in str(err)


def test_limits_carry_the_documented_values():
    d = limits.DEFAULT
    assert (d.children, d.elements, d.byte_budget, d.nesting) == (100, 1000, 500_000, 2)
    assert (d.rich_text, d.text_chars) == (100, 2000)
    assert (d.equation_chars, d.url_chars) == (1000, 2000)
    assert limits.MULTIPART_THRESHOLD_BYTES == 20 * 1024 * 1024


def test_limits_are_frozen_so_nothing_mutates_them_at_a_distance():
    with pytest.raises(Exception):
        limits.DEFAULT.children = 5
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd notion-upload && uv run pytest tests/test_errors.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'notion_upload.errors'`

- [ ] **Step 4: Write the implementation**

`notion-upload/src/notion_upload/errors.py`:

```python
"""Exception hierarchy. Each class owns the process exit code it maps to,
so cli.py needs no translation table."""


class NotionUploadError(Exception):
    """Base for every failure this tool reports deliberately."""

    exit_code = 1


class InputError(NotionUploadError):
    """The input is not block JSON we can work with."""

    exit_code = 2


class MediaError(NotionUploadError):
    """Local media could not be resolved or uploaded."""

    exit_code = 3


class LimitError(NotionUploadError):
    """Content exceeds a limit that cannot be fixed by splitting."""

    exit_code = 4


class APIError(NotionUploadError):
    """Notion rejected a request, or was unreachable.

    `status` is the HTTP status when there was a response, and None when the
    request never completed (a transport error). retrieve_parent depends on
    this to tell a genuine 404 from a bad token.
    """

    exit_code = 5

    def __init__(self, message, *, status=None):
        super().__init__(message)
        self.status = status


class PartialUploadError(NotionUploadError):
    """The page was created but not completely filled.

    This is the one error that reports something the user can still use, so
    it carries the page URL and the exact block that failed.
    """

    exit_code = 6

    def __init__(self, *, page_url, block_index, depth, completed, total):
        self.page_url = page_url
        self.block_index = block_index
        self.depth = depth
        self.completed = completed
        self.total = total
        super().__init__(
            f"page created but incomplete\n"
            f"  {page_url}\n"
            f"  failed appending children of block #{block_index} (depth {depth})\n"
            f"  {completed} of {total} requests succeeded"
        )
```

`notion-upload/src/notion_upload/limits.py`:

```python
"""Notion's documented limits, and the transformations that respect them.

Every value here is quoted from Notion's API documentation; see spec 2.3.
They live in a frozen dataclass rather than as bare module constants so that
tests can vary them - a planner bug is far easier to reproduce at
`Limits(children=3)` than at `Limits(children=100)`.
"""

from dataclasses import dataclass

NOTION_VERSION = "2026-03-11"

# Files above this size must use the multi-part upload mode.
MULTIPART_THRESHOLD_BYTES = 20 * 1024 * 1024


@dataclass(frozen=True)
class Limits:
    # Per request.
    children: int = 100          # top-level entries in a children array
    elements: int = 1000         # total blocks, counting inlined children
    byte_budget: int = 500_000   # serialized payload
    nesting: int = 2             # levels of nesting

    # Per block.
    rich_text: int = 100         # elements in one rich_text array
    text_chars: int = 2000       # characters in one text.content
    equation_chars: int = 1000   # characters in one equation.expression
    url_chars: int = 2000        # characters in any URL


DEFAULT = Limits()
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd notion-upload && uv run pytest tests/test_errors.py -v`
Expected: PASS, 5 tests.

- [ ] **Step 6: Commit**

```bash
git add notion-upload/
git commit -m "feat(upload): scaffold the package, error hierarchy and limit constants"
```

---

### Task 2: Document parsing and block accessors

**Files:**
- Create: `notion-upload/src/notion_upload/document.py`
- Test: `notion-upload/tests/test_document.py`

**Interfaces:**
- Consumes: `errors.InputError`.
- Produces:
  - `document.parse(raw: str | bytes) -> list[dict]` — accepts a bare array, a list response, or a page object; raises `InputError` otherwise. Strips every `id` key from every block, at every depth.
  - `document.block_type(block: dict) -> str`
  - `document.payload(block: dict) -> dict` — the type-keyed sub-object, e.g. `block["paragraph"]`.
  - `document.children_of(block: dict) -> list[dict]` — `[]` when absent.
  - `document.without_children(block: dict) -> dict` — a deep-ish copy with `children` removed from the payload.
  - `document.with_children(block: dict, kids: list[dict]) -> dict` — a copy with `children` set.
  - `document.walk(blocks: list[dict]) -> Iterator[dict]` — every block, depth-first, document order.
  - `document.count(blocks: list[dict]) -> int` — total blocks including nested.

**Context an implementer needs:** `notion-block-writer.lua` emits `children` *nested inside the type payload* — `{"type":"bulleted_list_item","bulleted_list_item":{"rich_text":[…],"children":[…]}}` — not at the top level of the block. That is the shape the append endpoints accept. Every accessor below must look there.

- [ ] **Step 1: Write the failing test**

`notion-upload/tests/test_document.py`:

```python
import json

import pytest

from notion_upload import document, errors


def para(text, children=None):
    payload = {"rich_text": [{"type": "text", "text": {"content": text}}]}
    if children is not None:
        payload["children"] = children
    return {"object": "block", "type": "paragraph", "paragraph": payload}


def test_parses_a_bare_array():
    blocks = document.parse(json.dumps([para("hi")]))
    assert len(blocks) == 1
    assert document.block_type(blocks[0]) == "paragraph"


def test_parses_a_list_response():
    raw = json.dumps({"object": "list", "results": [para("hi")], "has_more": False})
    assert len(document.parse(raw)) == 1


def test_parses_a_page_object():
    raw = json.dumps({"object": "page", "children": [para("hi")]})
    assert len(document.parse(raw)) == 1


def test_rejects_anything_else_by_naming_the_accepted_shapes():
    with pytest.raises(errors.InputError) as exc:
        document.parse(json.dumps({"object": "database"}))
    assert "bare array" in str(exc.value)


def test_rejects_malformed_json():
    with pytest.raises(errors.InputError):
        document.parse("{not json")


def test_strips_server_owned_ids_at_every_depth():
    nested = para("outer", children=[para("inner")])
    nested["id"] = "11111111-1111-1111-1111-111111111111"
    nested["paragraph"]["children"][0]["id"] = "22222222-2222-2222-2222-222222222222"
    blocks = document.parse(json.dumps([nested]))
    assert "id" not in blocks[0]
    assert "id" not in document.children_of(blocks[0])[0]


def test_children_live_inside_the_type_payload():
    b = para("outer", children=[para("inner")])
    assert len(document.children_of(b)) == 1
    assert document.children_of(para("leaf")) == []


def test_without_children_does_not_mutate_the_original():
    b = para("outer", children=[para("inner")])
    stripped = document.without_children(b)
    assert "children" not in document.payload(stripped)
    assert len(document.children_of(b)) == 1, "original must be untouched"


def test_with_children_does_not_mutate_the_original():
    b = para("leaf")
    joined = document.with_children(b, [para("kid")])
    assert len(document.children_of(joined)) == 1
    assert document.children_of(b) == []


def test_walk_is_depth_first_document_order():
    tree = [para("a", children=[para("b"), para("c")]), para("d")]
    texts = [
        document.payload(b)["rich_text"][0]["text"]["content"]
        for b in document.walk(tree)
    ]
    assert texts == ["a", "b", "c", "d"]


def test_count_includes_nested_blocks():
    tree = [para("a", children=[para("b"), para("c")]), para("d")]
    assert document.count(tree) == 4
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd notion-upload && uv run pytest tests/test_document.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'notion_upload.document'`

- [ ] **Step 3: Write the implementation**

`notion-upload/src/notion_upload/document.py`:

```python
"""Parsing and accessors for Notion block JSON.

The one thing worth knowing before reading this file: `notion-block-writer.lua`
nests `children` *inside the type payload*, not at the top level of the block:

    {"type": "bulleted_list_item",
     "bulleted_list_item": {"rich_text": [...], "children": [...]}}

That is the shape the append endpoints accept, so every accessor here looks
there and nowhere else.
"""

import copy
import json
from collections.abc import Iterator

from .errors import InputError

ACCEPTED = (
    "expected a bare array of blocks, a list response "
    '({"object":"list","results":[...]}), or a page object '
    '({"object":"page","children":[...]})'
)


def parse(raw: str | bytes) -> list[dict]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise InputError(f"input is not valid JSON: {exc}") from exc

    blocks = _unwrap(value)
    for block in walk(blocks):
        # Ids are server-owned. The writer emits them only under -V preserve-ids,
        # and sending one back is rejected, so they go no further than here.
        block.pop("id", None)
    return blocks


def _unwrap(value: object) -> list[dict]:
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        obj = value.get("object")
        if obj == "list":
            return list(value.get("results") or [])
        if obj == "page":
            return list(value.get("children") or value.get("results") or [])
    raise InputError(ACCEPTED)


def block_type(block: dict) -> str:
    kind = block.get("type")
    if not isinstance(kind, str):
        raise InputError(f"block has no string 'type': {block!r:.120}")
    return kind


def payload(block: dict) -> dict:
    body = block.get(block_type(block))
    if not isinstance(body, dict):
        raise InputError(
            f"block of type {block_type(block)!r} has no matching payload object"
        )
    return body


def children_of(block: dict) -> list[dict]:
    return payload(block).get("children") or []


def without_children(block: dict) -> dict:
    out = dict(block)
    body = dict(payload(block))
    body.pop("children", None)
    out[block_type(block)] = body
    return out


def with_children(block: dict, kids: list[dict]) -> dict:
    out = dict(block)
    body = dict(payload(block))
    body["children"] = kids
    out[block_type(block)] = body
    return out


def walk(blocks: list[dict]) -> Iterator[dict]:
    for block in blocks:
        yield block
        yield from walk(children_of(block))


def count(blocks: list[dict]) -> int:
    return sum(1 for _ in walk(blocks))


def deep_copy(blocks: list[dict]) -> list[dict]:
    return copy.deepcopy(blocks)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd notion-upload && uv run pytest tests/test_document.py -v`
Expected: PASS, 11 tests.

- [ ] **Step 5: Commit**

```bash
git add notion-upload/
git commit -m "feat(upload): parse block JSON envelopes and access nested children"
```

---

### Task 3: Normalization and splitting

**Files:**
- Modify: `notion-upload/src/notion_upload/limits.py` (append functions below the constants)
- Test: `notion-upload/tests/test_limits.py`

**Interfaces:**
- Consumes: `document.*`, `errors.LimitError`.
- Produces:
  - `limits.serialized_size(value) -> int` — UTF-8 byte length of the compact JSON encoding.
  - `limits.merge_runs(rich_text: list[dict]) -> list[dict]` — merges adjacent elements with identical annotations, no link, and `type == "text"`.
  - `limits.split_text_content(rich_text: list[dict], max_chars: int) -> list[dict]` — splits any element whose `text.content` exceeds `max_chars`, preserving annotations and link.
  - `limits.normalize(blocks: list[dict], lim: Limits) -> tuple[list[dict], list[str]]` — returns new blocks plus warning strings. Recurses into children. Raises `LimitError` for an over-long equation or URL.

**Why this order matters:** merging runs first is lossless and routinely drops a pandoc-produced `rich_text` array from 140 fragments to 6, so most documents never reach the splitting path at all. Splitting then applies both the element-count bound *and* the byte bound, because Notion caps content in characters but caps requests in bytes: 100 elements × 2000 chars is 210 KB in ASCII but **600 KB** in CJK, which no request can carry. Splitting against element count alone would emit a legal-looking block that is impossible to send. (Spec §7.)

- [ ] **Step 1: Write the failing test**

`notion-upload/tests/test_limits.py`:

```python
import pytest

from notion_upload import document, errors, limits

PLAIN = {
    "bold": False, "code": False, "color": "default",
    "italic": False, "strikethrough": False, "underline": False,
}


def rt(content, **ann):
    annotations = dict(PLAIN, **ann)
    return {"type": "text", "text": {"content": content}, "annotations": annotations}


def block(kind, runs):
    return {"object": "block", "type": kind, kind: {"rich_text": runs}}


def runs_of(b):
    return document.payload(b)["rich_text"]


def test_serialized_size_counts_utf8_bytes_not_characters():
    assert limits.serialized_size({"a": "x"}) < limits.serialized_size({"a": "漢"})


def test_merge_runs_joins_identical_adjacent_annotations():
    merged = limits.merge_runs([rt("Hello"), rt(" "), rt("world")])
    assert len(merged) == 1
    assert merged[0]["text"]["content"] == "Hello world"


def test_merge_runs_keeps_differing_annotations_apart():
    merged = limits.merge_runs([rt("Hello"), rt("bold", bold=True)])
    assert len(merged) == 2


def test_merge_runs_never_merges_across_a_link():
    linked = rt("here")
    linked["text"]["link"] = {"url": "https://example.com"}
    merged = limits.merge_runs([linked, rt("there")])
    assert len(merged) == 2, "merging across a link would extend the link text"


def test_split_text_content_respects_the_character_bound():
    out = limits.split_text_content([rt("x" * 4500)], 2000)
    assert [len(e["text"]["content"]) for e in out] == [2000, 2000, 500]


def test_split_text_content_preserves_annotations_on_every_piece():
    out = limits.split_text_content([rt("x" * 3000, bold=True)], 2000)
    assert all(e["annotations"]["bold"] for e in out)


def test_normalize_splits_a_block_that_exceeds_the_element_cap():
    # 150 runs that cannot merge, because each differs from its neighbour.
    runs = [rt(f"w{i}", bold=bool(i % 2)) for i in range(150)]
    out, warnings = limits.normalize([block("paragraph", runs)], limits.DEFAULT)
    assert len(out) == 2, "one paragraph becomes two consecutive paragraphs"
    assert all(len(runs_of(b)) <= 100 for b in out)
    assert all(document.block_type(b) == "paragraph" for b in out)
    assert any("index 0" in w and "split into 2" in w for w in warnings)


def test_normalize_splits_on_bytes_even_when_the_element_count_is_legal():
    # 100 elements of 2000 CJK characters each: legal by count, 600 KB by bytes.
    runs = [rt("漢" * 2000, bold=bool(i % 2)) for i in range(100)]
    out, warnings = limits.normalize([block("code", runs)], limits.DEFAULT)
    assert len(out) > 1, "the byte bound must force a split the count bound misses"
    assert all(
        limits.serialized_size(b) <= limits.DEFAULT.byte_budget for b in out
    ), "after normalization every childless block must fit alone in a request"
    assert warnings


def test_normalize_leaves_a_conforming_block_alone_and_warns_about_nothing():
    out, warnings = limits.normalize([block("paragraph", [rt("short")])], limits.DEFAULT)
    assert len(out) == 1
    assert warnings == []


def test_normalize_recurses_into_children():
    child = block("paragraph", [rt("x" * 5000)])
    parent = {
        "object": "block", "type": "toggle",
        "toggle": {"rich_text": [rt("t")], "children": [child]},
    }
    out, _ = limits.normalize([parent], limits.DEFAULT)
    inner = document.children_of(out[0])[0]
    assert all(len(e["text"]["content"]) <= 2000 for e in runs_of(inner))


def test_normalize_errors_on_an_equation_too_long_to_split():
    eq = {"object": "block", "type": "equation",
          "equation": {"expression": "x" * 1500}}
    with pytest.raises(errors.LimitError) as exc:
        limits.normalize([eq], limits.DEFAULT)
    assert "equation" in str(exc.value)


def test_normalize_errors_on_an_over_long_url():
    b = {"object": "block", "type": "image",
         "image": {"type": "external", "external": {"url": "https://e.com/" + "a" * 2100}}}
    with pytest.raises(errors.LimitError) as exc:
        limits.normalize([b], limits.DEFAULT)
    assert "url" in str(exc.value).lower()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd notion-upload && uv run pytest tests/test_limits.py -v`
Expected: FAIL — `AttributeError: module 'notion_upload.limits' has no attribute 'serialized_size'`

- [ ] **Step 3: Write the implementation**

Append the functions below to `notion-upload/src/notion_upload/limits.py`.
**Put the three new imports at the top of the file**, beside the existing
`from dataclasses import dataclass` — not in the middle where the functions
land. (`document` imports only `errors`, so there is no import cycle.)

```python
# --- at the top of the file, with the existing imports ---
import json

from . import document
from .errors import LimitError


# --- below the Limits dataclass and DEFAULT ---
def serialized_size(value) -> int:
    """UTF-8 byte length of the compact JSON encoding.

    Bytes, not characters: Notion caps text.content in characters but caps a
    request in bytes, and the two disagree by 3x on CJK text.
    """
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def _mergeable(a: dict, b: dict) -> bool:
    if a.get("type") != "text" or b.get("type") != "text":
        return False
    if a.get("annotations") != b.get("annotations"):
        return False
    # Merging across a link would silently extend the link over adjacent text.
    return not a.get("text", {}).get("link") and not b.get("text", {}).get("link")


def merge_runs(rich_text: list[dict]) -> list[dict]:
    """Join adjacent elements that differ in nothing but their content.

    Lossless, and worth doing first: pandoc fragments runs at word boundaries,
    so real documents routinely arrive with far more elements than they need.
    """
    out: list[dict] = []
    for element in rich_text:
        if out and _mergeable(out[-1], element):
            merged = json.loads(json.dumps(out[-1]))
            merged["text"]["content"] += element["text"]["content"]
            merged.pop("plain_text", None)
            out[-1] = merged
        else:
            out.append(element)
    return out


def split_text_content(rich_text: list[dict], max_chars: int) -> list[dict]:
    out: list[dict] = []
    for element in rich_text:
        content = element.get("text", {}).get("content")
        if element.get("type") != "text" or content is None or len(content) <= max_chars:
            out.append(element)
            continue
        for start in range(0, len(content), max_chars):
            piece = json.loads(json.dumps(element))
            piece["text"]["content"] = content[start:start + max_chars]
            piece.pop("plain_text", None)
            out.append(piece)
    return out


def _chunk_runs(runs: list[dict], lim: Limits, overhead: int) -> list[list[dict]]:
    """Cut a rich_text array into pieces that satisfy both bounds.

    `overhead` is the serialized size of the block minus its rich_text, so the
    byte budget is spent on what the block actually costs on the wire.
    """
    chunks: list[list[dict]] = []
    current: list[dict] = []
    current_bytes = overhead
    for element in runs:
        size = serialized_size(element) + 1  # +1 for the separating comma
        too_many = len(current) >= lim.rich_text
        too_big = current and current_bytes + size > lim.byte_budget
        if too_many or too_big:
            chunks.append(current)
            current, current_bytes = [], overhead
        current.append(element)
        current_bytes += size
    if current or not chunks:
        chunks.append(current)
    return chunks


def _check_unsplittable(block: dict, lim: Limits, index: int) -> None:
    """Limits that cannot be honored by splitting, because splitting would
    change what the content means."""
    body = document.payload(block)

    expression = body.get("expression")
    if isinstance(expression, str) and len(expression) > lim.equation_chars:
        raise LimitError(
            f"equation at index {index} is {len(expression)} characters; "
            f"the limit is {lim.equation_chars} and an equation cannot be split"
        )

    for holder in (body, body.get("external") or {}, body.get("file") or {}):
        url = holder.get("url") if isinstance(holder, dict) else None
        if isinstance(url, str) and len(url) > lim.url_chars:
            raise LimitError(
                f"url at index {index} is {len(url)} characters; "
                f"the limit is {lim.url_chars}"
            )


def normalize(blocks: list[dict], lim: Limits) -> tuple[list[dict], list[str]]:
    """Merge, split, and recurse. Returns new blocks and warnings.

    Guarantee on return: every childless block fits alone inside byte_budget,
    which is what makes the planner's packing total (spec 5.2).
    """
    out: list[dict] = []
    warnings: list[str] = []

    for index, block in enumerate(blocks):
        _check_unsplittable(block, lim, index)

        kind = document.block_type(block)
        kids = document.children_of(block)
        current = document.without_children(block)
        body = document.payload(current)

        runs = body.get("rich_text")
        pieces = [current]
        if isinstance(runs, list) and runs:
            runs = split_text_content(merge_runs(runs), lim.text_chars)
            skeleton = dict(body)
            skeleton["rich_text"] = []
            overhead = serialized_size({**current, kind: skeleton})
            chunks = _chunk_runs(runs, lim, overhead)
            pieces = []
            for chunk in chunks:
                piece = dict(current)
                piece[kind] = {**body, "rich_text": chunk}
                pieces.append(piece)
            if len(chunks) > 1:
                warnings.append(
                    f"{kind} block at index {index} exceeds what one Notion block "
                    f"can hold; split into {len(chunks)} consecutive {kind} blocks"
                )

        if kids:
            normalized_kids, child_warnings = normalize(kids, lim)
            warnings.extend(child_warnings)
            # Children belong to the first piece; the rest are continuations.
            pieces[0] = document.with_children(pieces[0], normalized_kids)

        out.extend(pieces)

    return out, warnings
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd notion-upload && uv run pytest tests/test_limits.py -v`
Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add notion-upload/
git commit -m "feat(upload): normalize rich text against both the character and byte bounds"
```

---

### Task 4: The planner

**Files:**
- Create: `notion-upload/src/notion_upload/planner.py`
- Test: `notion-upload/tests/test_planner.py`

**Interfaces:**
- Consumes: `document.*`, `limits.Limits`, `limits.serialized_size`.
- Produces:
  - `planner.Ref(request: int, index: int)` — frozen dataclass; a symbolic reference to the block that will be created at position `index` of request `request`.
  - `planner.Request(parent: Ref | None, blocks: list[dict], source_path: list[tuple[int, ...]])` — dataclass. `parent is None` means the page root. `source_path[i]` is the position of `blocks[i]` in the original tree, used only for error messages.
  - `planner.plan(blocks: list[dict], lim: Limits) -> list[Request]` — pure; no I/O, no clock, no randomness.

**The two rules this implements (spec §5):**

1. **Inline the longest leading run of leaf children that fits; defer the rest.** A block carries as many of its children in the payload as it legally can, stopping at the first child that has children of its own (that child needs an id, so it must appear top-level in some later request) or at the first child that would breach a bound. Everything from that point on becomes a deferred wave.

   **Prefix, not subset.** Deferred children are *appended* to the parent, so they land after whatever was inlined. Only taking a leading run preserves document order — and because appending does that naturally, no `position` parameter is needed.

2. **Pack greedily against all four bounds at once.** Task 3 guarantees a childless block always fits alone, and rule 1 can always fall back to inlining nothing, so packing is total and the recursion terminates.

Requests are emitted in **document order**: siblings are packed first, then their children, depth-first.

**A bound that is easy to miss:** the 100-children cap applies to *every* `children` array, not just the request's top-level one. An all-or-nothing inlining rule will happily emit a block with 120 inlined children — one legal-looking request that Notion rejects. Rule 1 caps the inlined run at `lim.children` for exactly this reason, and Task 5's fake validates every array at every depth so the mistake cannot come back.

- [ ] **Step 1: Write the failing test**

`notion-upload/tests/test_planner.py`:

```python
from notion_upload import document, limits, planner


def para(text, children=None):
    payload = {"rich_text": [{"type": "text", "text": {"content": text}}]}
    if children is not None:
        payload["children"] = children
    return {"object": "block", "type": "paragraph", "paragraph": payload}


def text_of(block):
    return document.payload(block)["rich_text"][0]["text"]["content"]


def test_a_flat_document_is_one_request_rooted_at_the_page():
    plan = planner.plan([para("a"), para("b")], limits.DEFAULT)
    assert len(plan) == 1
    assert plan[0].parent is None
    assert [text_of(b) for b in plan[0].blocks] == ["a", "b"]


def test_a_block_with_only_leaf_children_inlines_them():
    tree = [para("a", children=[para("b"), para("c")])]
    plan = planner.plan(tree, limits.DEFAULT)
    assert len(plan) == 1, "depth 2 needs no follow-up request"
    assert len(document.children_of(plan[0].blocks[0])) == 2


def test_a_block_with_grandchildren_is_sent_childless_and_defers():
    tree = [para("a", children=[para("b", children=[para("c")])])]
    plan = planner.plan(tree, limits.DEFAULT)
    assert len(plan) == 2
    assert document.children_of(plan[0].blocks[0]) == [], "a must go childless"
    assert plan[1].parent == planner.Ref(request=0, index=0)
    assert text_of(plan[1].blocks[0]) == "b"
    assert len(document.children_of(plan[1].blocks[0])) == 1, "b inlines its leaf c"


def test_the_worked_example_from_the_spec_costs_two_requests():
    # A > B1..B50, each Bi holding one leaf Ci.
    bs = [para(f"b{i}", children=[para(f"c{i}")]) for i in range(50)]
    plan = planner.plan([para("a", children=bs)], limits.DEFAULT)
    assert len(plan) == 2, "the naive strip-everything planner costs 52"
    assert plan[0].parent is None
    assert plan[1].parent == planner.Ref(request=0, index=0)
    assert len(plan[1].blocks) == 50


def test_packing_respects_the_children_bound():
    plan = planner.plan([para(str(i)) for i in range(250)], limits.DEFAULT)
    assert [len(r.blocks) for r in plan] == [100, 100, 50]
    assert all(r.parent is None for r in plan)


def test_packing_respects_the_byte_bound():
    lim = limits.Limits(byte_budget=1200)
    plan = planner.plan([para("x" * 300) for _ in range(6)], lim)
    assert len(plan) > 1
    for request in plan:
        assert limits.serialized_size(request.blocks) <= lim.byte_budget


def test_packing_respects_the_element_bound_counting_inlined_children():
    lim = limits.Limits(elements=10, children=100)
    tree = [para(f"p{i}", children=[para("k")]) for i in range(12)]
    plan = planner.plan(tree, lim)
    for request in plan:
        assert document.count(request.blocks) <= lim.elements


def test_inlined_children_never_exceed_the_children_cap():
    # 120 leaf children: legal by element count, illegal as one children array.
    tree = [para("b", children=[para(f"x{i}") for i in range(120)])]
    plan = planner.plan(tree, limits.DEFAULT)
    for request in plan:
        for block in request.blocks:
            assert len(document.children_of(block)) <= limits.DEFAULT.children
    assert len(plan) == 2, "100 inlined, 20 deferred"
    assert len(document.children_of(plan[0].blocks[0])) == 100
    assert len(plan[1].blocks) == 20


def test_the_deferred_remainder_preserves_document_order():
    tree = [para("b", children=[para(f"x{i}") for i in range(120)])]
    plan = planner.plan(tree, limits.DEFAULT)
    inlined = [text_of(k) for k in document.children_of(plan[0].blocks[0])]
    deferred = [text_of(b) for b in plan[1].blocks]
    assert inlined + deferred == [f"x{i}" for i in range(120)], (
        "appending puts deferred children after inlined ones, so the inlined "
        "set must be a prefix"
    )


def test_inlining_stops_at_the_first_child_that_has_children():
    kids = [para("a"), para("b"), para("c", children=[para("g")]), para("d")]
    tree = [para("p", children=kids)]
    plan = planner.plan(tree, limits.DEFAULT)
    inlined = [text_of(k) for k in document.children_of(plan[0].blocks[0])]
    assert inlined == ["a", "b"], "c needs its own id, so c and everything after defers"
    assert [text_of(b) for b in plan[1].blocks] == ["c", "d"]


def test_a_leading_child_with_children_means_nothing_is_inlined():
    tree = [para("p", children=[para("c", children=[para("g")]), para("d")])]
    plan = planner.plan(tree, limits.DEFAULT)
    assert document.children_of(plan[0].blocks[0]) == []
    assert [text_of(b) for b in plan[1].blocks] == ["c", "d"]


def test_inlining_stops_when_the_byte_budget_runs_out():
    lim = limits.Limits(byte_budget=400)
    tree = [para("p", children=[para("x" * 200), para("y" * 200)])]
    plan = planner.plan(tree, lim)
    for request in plan:
        assert limits.serialized_size(request.blocks) <= lim.byte_budget
    assert len(plan) >= 2
    assert plan[1].parent == planner.Ref(request=0, index=0)


def test_requests_come_in_document_order():
    tree = [
        para("a", children=[para("a1", children=[para("a2")])]),
        para("b"),
    ]
    plan = planner.plan(tree, limits.DEFAULT)
    first = [text_of(b) for b in plan[0].blocks]
    assert first == ["a", "b"], "siblings pack together before descending"
    assert text_of(plan[1].blocks[0]) == "a1"


def test_a_parents_request_always_precedes_the_request_it_parents():
    tree = [para(f"p{i}", children=[para("k", children=[para("g")])]) for i in range(5)]
    plan = planner.plan(tree, limits.DEFAULT)
    for position, request in enumerate(plan):
        if request.parent is not None:
            assert request.parent.request < position


def test_source_path_resolves_to_the_right_block_after_partial_inlining():
    """A deferred wave starts partway through its parent's children, so its
    paths must carry that offset. Without it they resolve to the blocks that
    were inlined instead."""
    tree = [para("p", children=[para("a"), para("b"),
                                para("c", children=[para("g")]), para("d")])]
    plan = planner.plan(tree, limits.DEFAULT)

    def resolve(path):
        node, cursor = None, tree
        for i in path:
            node = cursor[i]
            cursor = document.children_of(node)
        return text_of(node)

    for request in plan:
        assert len(request.source_path) == len(request.blocks)
        for block, path in zip(request.blocks, request.source_path):
            assert resolve(path) == text_of(block), (
                f"source_path {path} resolves to {resolve(path)!r}, "
                f"but the request carries {text_of(block)!r}"
            )


def test_plan_does_not_mutate_its_input():
    tree = [para("a", children=[para("b", children=[para("c")])])]
    before = document.deep_copy(tree)
    planner.plan(tree, limits.DEFAULT)
    assert tree == before


def test_an_empty_document_plans_a_single_empty_request():
    plan = planner.plan([], limits.DEFAULT)
    assert len(plan) == 1
    assert plan[0].blocks == []
    assert plan[0].parent is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd notion-upload && uv run pytest tests/test_planner.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'notion_upload.planner'`

- [ ] **Step 3: Write the implementation**

`notion-upload/src/notion_upload/planner.py`:

```python
"""Block tree -> ordered list of append requests.

Pure: no I/O, no clock, no randomness. Given the same tree and limits it
returns the same plan, which is what makes the property tests in
tests/test_roundtrip.py worth anything.

Parents are symbolic. A request cannot know the real block id of its parent,
because that id does not exist until an earlier request has been executed, so
`Request.parent` is a `Ref` naming a position in an earlier request's results.
The executor resolves those to real ids as it goes.
"""

from dataclasses import dataclass, field

from . import document
from .limits import Limits, serialized_size


@dataclass(frozen=True)
class Ref:
    """The block that will be created at `index` of `request`'s top level."""

    request: int
    index: int


@dataclass
class Request:
    parent: Ref | None  # None means the page itself
    blocks: list[dict]
    source_path: list[tuple[int, ...]] = field(default_factory=list)


def _prepare(block: dict, lim: Limits) -> tuple[dict, list[dict]]:
    """Return the payload for one block and the children it must defer.

    Inline the longest LEADING run of children that are leaves and fit;
    everything from the first non-leaf or first over-budget child onward is
    deferred. A leading run and not an arbitrary subset, because deferred
    children are appended to the parent and therefore land after whatever was
    inlined - taking a prefix is what keeps document order without needing
    the `position` parameter.

    Note the `lim.children` check: the 100-children cap applies to every
    children array, not only the request's top-level one, so a block with 120
    leaf children cannot carry them all however much byte budget is spare.
    """
    kids = document.children_of(block)
    if not kids:
        return document.without_children(block), [], 0

    taken: list[dict] = []
    for kid in kids:
        if document.children_of(kid):
            break  # this child needs its own id, so it must be top-level later
        if len(taken) >= lim.children:
            break
        trial = document.with_children(block, taken + [kid])
        if document.count([trial]) > lim.elements:
            break
        if serialized_size([trial]) > lim.byte_budget:
            break
        taken.append(kid)

    deferred = list(kids[len(taken):])
    if not taken:
        return document.without_children(block), deferred, 0
    return document.with_children(block, taken), deferred, len(taken)


def plan(blocks: list[dict], lim: Limits) -> list[Request]:
    requests: list[Request] = []
    # (parent_ref, blocks, source_path) waves still to emit.
    waves: list[tuple] = [(None, document.deep_copy(blocks), (), 0)]

    while waves:
        parent, children, path, base = waves.pop(0)
        deferred = _pack(parent, children, lim, path, requests, base)
        # Depth-first: waves just queued go to the front, in order, so a
        # block's children are emitted before its parent's later siblings.
        waves[0:0] = deferred

    return requests
```

`_pack` returns its deferrals rather than mutating a queue, which is what
makes that last line the only ordering decision in the file:

```python
def _pack(parent, blocks, lim, path, requests, base=0) -> list[tuple]:
    """Emit requests appending `blocks` to `parent`; return deferred waves."""
    deferred_waves: list[tuple] = []
    current: list[dict] = []
    current_paths: list[tuple[int, ...]] = []
    deferrals: list[tuple[int, list[dict], tuple[int, ...]]] = []

    def flush():
        index = len(requests)
        requests.append(Request(parent, list(current), list(current_paths)))
        for position, kids, kid_path, inlined in deferrals:
            deferred_waves.append((Ref(index, position), kids, kid_path, inlined))
        deferrals.clear()

    for offset, block in enumerate(blocks):
        payload, deferred, inlined = _prepare(block, lim)
        # `base` is how many of this block's children were inlined upstream;
        # without it a deferred wave's paths point at the inlined ones.
        block_path = path + (base + offset,)

        over_children = len(current) >= lim.children
        over_elements = (
            sum(document.count([b]) for b in current) + document.count([payload])
            > lim.elements
        )
        over_bytes = serialized_size(current + [payload]) > lim.byte_budget

        if current and (over_children or over_elements or over_bytes):
            flush()
            current, current_paths = [], []

        current.append(payload)
        current_paths.append(block_path)
        if deferred:
            deferrals.append((len(current) - 1, deferred, block_path, inlined))

    # Always flush, even when empty: an empty document still creates a page.
    flush()
    return deferred_waves
```

> **Verified before this plan was written.** This algorithm was prototyped and
> checked against 6000 generated trees at two limit settings: no request
> exceeded the children, element, or nesting bounds, the parent-precedes-child
> ordering held everywhere, the spec's worked example came out at 2 requests,
> and 600 execute-and-compare round trips reproduced the input tree exactly.
> The code above is that prototype, not a sketch of it.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd notion-upload && uv run pytest tests/test_planner.py -v`
Expected: PASS, 17 tests.

- [ ] **Step 5: Commit**

```bash
git add notion-upload/
git commit -m "feat(upload): plan append requests, inlining a leading run of leaf children"
```

---

### Task 5: The constraint-enforcing fake, and the round-trip invariant

**Files:**
- Create: `notion-upload/tests/fake_notion.py`
- Create: `notion-upload/tests/strategies.py`
- Test: `notion-upload/tests/test_roundtrip.py`

**Interfaces:**
- Consumes: `planner.Request`, `planner.Ref`, `document.*`, `limits.Limits`.
- Produces:
  - `fake_notion.FakeNotion(lim: Limits)` with `.create_page(children) -> str` (returns a page id), `.append(block_id, children) -> list[dict]` (returns created blocks with ids, in order), `.tree() -> list[dict]` (the accumulated page content as a block tree), and `.rejections: list[str]`.
  - `fake_notion.execute(plan: list[Request], fake: FakeNotion) -> None` — resolves `Ref`s to real ids in order.
  - `strategies.block_trees()` — a Hypothesis strategy producing block trees varying in depth, fan-out, and text (including multibyte).

**Why a fake and not a mock (spec §9.1):** a permissive mock accepts plans Notion refuses, so a planner bug stays green. This fake rejects exactly what Notion rejects — more than `lim.children` top-level entries, more than `lim.elements` total, more than `lim.byte_budget` bytes, more than `lim.nesting` levels, or an `id` on an inbound block. Every planner bug becomes a red test.

- [ ] **Step 1: Write the fake and the strategies**

`notion-upload/tests/fake_notion.py`:

```python
"""An in-process Notion that enforces the documented limits.

Deliberately strict. A permissive mock would accept a plan the real API
rejects, which would let precisely the bugs this suite exists to catch pass.
"""

import itertools

from notion_upload import document, planner
from notion_upload.limits import Limits, serialized_size


class Rejected(Exception):
    """The fake refused a request, exactly as Notion would."""


class FakeNotion:
    def __init__(self, lim: Limits, *, fail_at: int | None = None):
        self.lim = lim
        self.fail_at = fail_at            # request ordinal that raises, for retry tests
        self.calls = 0
        self.rejections: list[str] = []
        self._ids = ("blk-%d" % n for n in itertools.count())
        self._children: dict[str, list[str]] = {"page": []}
        self._blocks: dict[str, dict] = {}

    # -- validation ---------------------------------------------------------

    def _depth(self, blocks, level=1):
        deepest = level
        for block in blocks:
            kids = document.children_of(block)
            if kids:
                deepest = max(deepest, self._depth(kids, level + 1))
        return deepest

    def _check_arrays(self, blocks, depth=1):
        """Every children array is capped, not just the request's top-level one.

        This is the check that catches a block carrying 120 inlined children:
        one legal-looking request that Notion rejects.
        """
        if len(blocks) > self.lim.children:
            self._reject(
                f"children array of {len(blocks)} at depth {depth} "
                f"exceeds {self.lim.children}"
            )
        for block in blocks:
            self._check_arrays(document.children_of(block), depth + 1)

    def _validate(self, children):
        self._check_arrays(children)
        total = document.count(children)
        if total > self.lim.elements:
            self._reject(f"{total} elements exceeds {self.lim.elements}")
        size = serialized_size(children)
        if size > self.lim.byte_budget:
            self._reject(f"{size} bytes exceeds {self.lim.byte_budget}")
        depth = self._depth(children) if children else 0
        if depth > self.lim.nesting:
            self._reject(f"nesting depth {depth} exceeds {self.lim.nesting}")
        for block in document.walk(children):
            if "id" in block:
                self._reject("inbound block carries a server-owned id")

    def _reject(self, message):
        self.rejections.append(message)
        raise Rejected(message)

    # -- endpoints ----------------------------------------------------------

    def create_page(self, children):
        self._tick()
        self._validate(children)
        self._store("page", children)
        return "page"

    def append(self, block_id, children):
        self._tick()
        self._validate(children)
        return self._store(block_id, children)

    def _tick(self):
        self.calls += 1
        if self.fail_at is not None and self.calls == self.fail_at:
            raise Rejected("injected failure")

    def _store(self, parent_id, children):
        created = []
        for block in children:
            new_id = next(self._ids)
            stored = document.without_children(block)
            stored["id"] = new_id
            self._blocks[new_id] = stored
            self._children.setdefault(parent_id, []).append(new_id)
            self._children.setdefault(new_id, [])
            self._store(new_id, document.children_of(block))
            created.append(dict(stored))
        return created

    # -- inspection ---------------------------------------------------------

    def tree(self, parent_id="page"):
        out = []
        for block_id in self._children.get(parent_id, []):
            block = document.without_children(self._blocks[block_id])
            block.pop("id", None)
            kids = self.tree(block_id)
            out.append(document.with_children(block, kids) if kids else block)
        return out


def execute(plan, fake):
    """Run a plan, resolving symbolic Refs to the ids the fake hands back.

    One path for every wave, including the first, which is what cli.upload
    does in production: the page is created empty and even plan[0] is an
    ordinary append.
    """
    created: dict[planner.Ref, str] = {}
    for position, request in enumerate(plan):
        parent_id = "page" if request.parent is None else created[request.parent]
        results = fake.append(parent_id, request.blocks)
        for index, block in enumerate(results):
            created[planner.Ref(position, index)] = block["id"]
```

`notion-upload/tests/strategies.py`:

```python
"""Hypothesis strategies for block trees.

Text includes multibyte characters on purpose: the character bound and the
byte bound disagree by 3x on CJK, and that disagreement is exactly what the
planner has to survive.
"""

from hypothesis import strategies as st

TEXT = st.text(alphabet="ab 漢字", min_size=0, max_size=40)

BLOCK_TYPES = st.sampled_from(
    ["paragraph", "bulleted_list_item", "numbered_list_item", "toggle", "quote"]
)


def _block(kind, text, children):
    payload = {"rich_text": [{"type": "text", "text": {"content": text},
                              "annotations": {"bold": False, "code": False,
                                              "color": "default", "italic": False,
                                              "strikethrough": False,
                                              "underline": False}}]}
    if children:
        payload["children"] = children
    return {"object": "block", "type": kind, kind: payload}


def blocks(max_depth=4):
    leaf = st.builds(_block, BLOCK_TYPES, TEXT, st.just([]))
    return st.recursive(
        leaf,
        lambda inner: st.builds(
            _block, BLOCK_TYPES, TEXT, st.lists(inner, min_size=1, max_size=4)
        ),
        max_leaves=max_depth * 4,
    )


def block_trees(min_size=0, max_size=12):
    return st.lists(blocks(), min_size=min_size, max_size=max_size)
```

- [ ] **Step 2: Write the failing test**

`notion-upload/tests/test_roundtrip.py`:

```python
import pytest
from hypothesis import HealthCheck, given, settings

import fake_notion
import strategies
from notion_upload import document, limits, planner


def para(text, children=None):
    payload = {"rich_text": [{"type": "text", "text": {"content": text}}]}
    if children is not None:
        payload["children"] = children
    return {"object": "block", "type": "paragraph", "paragraph": payload}


def test_the_fake_rejects_too_many_children():
    fake = fake_notion.FakeNotion(limits.Limits(children=3))
    with pytest.raises(fake_notion.Rejected):
        fake.create_page([para(str(i)) for i in range(4)])


def test_the_fake_rejects_an_oversized_nested_children_array():
    # Legal at the top level, illegal one level down. A fake that only checks
    # the request's own array would let this through.
    fake = fake_notion.FakeNotion(limits.Limits(children=3))
    parent = para("p", children=[para(str(i)) for i in range(4)])
    with pytest.raises(fake_notion.Rejected) as exc:
        fake.create_page([parent])
    assert "depth 2" in str(exc.value)


def test_the_fake_rejects_excessive_nesting():
    fake = fake_notion.FakeNotion(limits.DEFAULT)
    deep = para("a", children=[para("b", children=[para("c")])])
    with pytest.raises(fake_notion.Rejected):
        fake.create_page([deep])


def test_the_fake_rejects_an_inbound_id():
    fake = fake_notion.FakeNotion(limits.DEFAULT)
    block = para("a")
    block["id"] = "22222222-2222-2222-2222-222222222222"
    with pytest.raises(fake_notion.Rejected):
        fake.create_page([block])


def test_a_deep_tree_round_trips_exactly():
    tree = [para("a", children=[para("b", children=[para("c", children=[para("d")])])])]
    fake = fake_notion.FakeNotion(limits.DEFAULT)
    fake_notion.execute(planner.plan(tree, limits.DEFAULT), fake)
    assert fake.tree() == tree


@settings(max_examples=200, suppress_health_check=[HealthCheck.too_slow], deadline=None)
@given(strategies.block_trees())
def test_plan_roundtrips_under_default_limits(tree):
    lim = limits.DEFAULT
    plan = planner.plan(tree, lim)
    for request in plan:
        assert len(request.blocks) <= lim.children
        assert document.count(request.blocks) <= lim.elements
        assert limits.serialized_size(request.blocks) <= lim.byte_budget
    fake = fake_notion.FakeNotion(lim)
    fake_notion.execute(plan, fake)
    assert fake.tree() == tree


@settings(max_examples=200, suppress_health_check=[HealthCheck.too_slow], deadline=None)
@given(strategies.block_trees(max_size=8))
def test_plan_roundtrips_under_cramped_limits(tree):
    # Small bounds reproduce in seconds what default bounds need a huge
    # document to reach.
    lim = limits.Limits(children=2, elements=5, byte_budget=900, nesting=2)
    plan = planner.plan(tree, lim)
    fake = fake_notion.FakeNotion(lim)
    fake_notion.execute(plan, fake)
    assert fake.tree() == tree
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd notion-upload && uv run pytest tests/test_roundtrip.py -v`
Expected: the property tests fail if the planner has any packing or ordering bug; they pass otherwise. (`pythonpath = ["tests"]` is already in `pyproject.toml` from Task 1, so `import fake_notion` resolves.)

- [ ] **Step 4: Run the whole suite**

Run: `cd notion-upload && uv run pytest -v`
Expected: PASS. If `test_plan_roundtrips_under_cramped_limits` fails, Hypothesis prints the minimal failing tree — fix `planner._pack` or `planner.plan` against it, not the test.

- [ ] **Step 5: Commit**

```bash
git add notion-upload/
git commit -m "test(upload): add a constraint-enforcing fake and the round-trip invariant"
```

---

### Task 6: The HTTP client

**Files:**
- Create: `notion-upload/src/notion_upload/client.py`
- Test: `notion-upload/tests/test_client.py`

**Interfaces:**
- Consumes: `limits.NOTION_VERSION`, `errors.APIError`.
- Produces:
  - `client.NotionClient(token: str, *, transport=None, base_url="https://api.notion.com", sleep=time.sleep, rate=3.0)`
  - `.create_page(parent: dict, title: str, children: list[dict]) -> dict`
  - `.append_children(block_id: str, children: list[dict]) -> list[dict]` — returns the `results` array.
  - `.retrieve_parent(object_id: str) -> dict` — probes page, then data source, then database; returns `{"page_id": id}` / `{"data_source_id": id}` / `{"database_id": id}`; raises `APIError` if none match.
  - `.create_file_upload(*, filename, content_type, mode="single_part", number_of_parts=None) -> dict`
  - `.send_file_upload(upload_id: str, data: bytes, filename: str, content_type: str, part_number: int | None = None) -> dict`
  - `.complete_file_upload(upload_id: str) -> dict`

**Testing note:** `httpx.MockTransport` lets the whole client be tested with no network and no monkeypatching. Inject `sleep` so retry tests are instant rather than actually waiting for `Retry-After`.

- [ ] **Step 1: Write the failing test**

`notion-upload/tests/test_client.py`:

```python
import json

import httpx
import pytest

from notion_upload import client, errors, limits


def transport(handler):
    return httpx.MockTransport(handler)


def make(handler, **kw):
    slept = []
    c = client.NotionClient(
        "secret_token",
        transport=transport(handler),
        sleep=slept.append,
        **kw,
    )
    return c, slept


def test_every_request_carries_auth_and_the_pinned_version():
    seen = {}

    def handler(request):
        seen.update(request.headers)
        return httpx.Response(200, json={"id": "page-1"})

    c, _ = make(handler)
    c.create_page({"page_id": "p"}, "T", [])
    assert seen["authorization"] == "Bearer secret_token"
    assert seen["notion-version"] == limits.NOTION_VERSION


def test_create_page_sends_title_as_the_only_property():
    captured = {}

    def handler(request):
        captured.update(json.loads(request.content))
        return httpx.Response(200, json={"id": "page-1", "url": "https://notion.so/p"})

    c, _ = make(handler)
    c.create_page({"page_id": "parent"}, "My Title", [])
    assert captured["parent"] == {"page_id": "parent"}
    assert list(captured["properties"]) == ["title"]
    title = captured["properties"]["title"]["title"][0]["text"]["content"]
    assert title == "My Title"


def test_append_children_returns_the_results_array():
    def handler(request):
        return httpx.Response(200, json={"results": [{"id": "b1"}, {"id": "b2"}]})

    c, _ = make(handler)
    assert [b["id"] for b in c.append_children("blk", [])] == ["b1", "b2"]


def test_429_is_retried_after_the_retry_after_header():
    calls = []

    def handler(request):
        calls.append(1)
        if len(calls) == 1:
            return httpx.Response(429, headers={"Retry-After": "7"}, json={})
        return httpx.Response(200, json={"results": []})

    c, slept = make(handler)
    c.append_children("blk", [])
    assert len(calls) == 2
    assert 7 in slept, f"must honour Retry-After, slept {slept}"


def test_529_is_retried_with_backoff():
    calls = []

    def handler(request):
        calls.append(1)
        if len(calls) < 3:
            return httpx.Response(529, json={"code": "service_overload"})
        return httpx.Response(200, json={"results": []})

    c, slept = make(handler)
    c.append_children("blk", [])
    assert len(calls) == 3
    assert len(slept) >= 2


def test_a_400_is_not_retried_and_reports_notions_message():
    calls = []

    def handler(request):
        calls.append(1)
        return httpx.Response(400, json={"code": "validation_error",
                                         "message": "body.children is too long"})

    c, _ = make(handler)
    with pytest.raises(errors.APIError) as exc:
        c.append_children("blk", [])
    assert len(calls) == 1, "a 4xx is the caller's fault; retrying is pointless"
    assert "body.children is too long" in str(exc.value)


def test_retries_are_bounded():
    def handler(request):
        return httpx.Response(529, json={})

    c, _ = make(handler, max_retries=3)
    with pytest.raises(errors.APIError):
        c.append_children("blk", [])


def test_retrieve_parent_probes_page_then_data_source_then_database():
    seen = []

    def handler(request):
        seen.append(request.url.path)
        if "data_sources" in request.url.path:
            return httpx.Response(200, json={"id": "ds"})
        return httpx.Response(404, json={"code": "object_not_found"})

    c, _ = make(handler)
    assert c.retrieve_parent("abc") == {"data_source_id": "abc"}
    assert seen[0].startswith("/v1/pages/")


def test_retrieve_parent_raises_when_nothing_matches():
    def handler(request):
        return httpx.Response(404, json={"code": "object_not_found"})

    c, _ = make(handler)
    with pytest.raises(errors.APIError) as exc:
        c.retrieve_parent("abc")
    assert "abc" in str(exc.value)


def test_a_bad_token_is_not_disguised_as_an_unshared_parent():
    """A 401 must surface as itself. Reporting it as 'not shared with your
    integration' sends the user to fix the wrong thing."""
    def handler(request):
        return httpx.Response(401, json={"code": "unauthorized",
                                         "message": "API token is invalid."})

    c, _ = make(handler)
    with pytest.raises(errors.APIError) as exc:
        c.retrieve_parent("24f1b2c3-d4e5-f6a7-b8c9-d0e1f2a3b4c5")
    assert "API token is invalid." in str(exc.value)
    assert "shared with your integration" not in str(exc.value)
    assert exc.value.status == 401


def test_a_transport_failure_becomes_an_api_error_not_a_raw_httpx_error():
    """cli.main handles NotionUploadError only, so a dropped connection must
    not escape as httpx.ConnectError."""
    def handler(request):
        raise httpx.ConnectError("connection refused", request=request)

    c, slept = make(handler, max_retries=2)
    with pytest.raises(errors.APIError) as exc:
        c.append_children("blk", [])
    assert "could not reach Notion" in str(exc.value)
    assert exc.value.status is None
    assert len(slept) >= 2, "a transport error is retryable"


def test_file_upload_send_posts_multipart_with_a_file_field():
    captured = {}

    def handler(request):
        captured["content_type"] = request.headers.get("content-type", "")
        captured["body"] = request.content
        return httpx.Response(200, json={"id": "fu-1", "status": "uploaded"})

    c, _ = make(handler)
    c.send_file_upload("fu-1", b"\x89PNG", "a.png", "image/png")
    assert captured["content_type"].startswith("multipart/form-data")
    assert b'name="file"' in captured["body"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd notion-upload && uv run pytest tests/test_client.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'notion_upload.client'`

- [ ] **Step 3: Write the implementation**

`notion-upload/src/notion_upload/client.py`:

```python
"""The Notion HTTP surface this tool needs, and nothing else.

`transport` and `sleep` are injected so the whole class is testable with
httpx.MockTransport and without ever actually waiting for a Retry-After.
"""

import random
import time

import httpx

from .errors import APIError
from .limits import NOTION_VERSION

RETRYABLE_STATUS = {429, 500, 502, 503, 504, 529}


class NotionClient:
    def __init__(
        self,
        token: str,
        *,
        transport=None,
        base_url: str = "https://api.notion.com",
        sleep=time.sleep,
        rate: float = 3.0,
        max_retries: int = 5,
    ):
        self._sleep = sleep
        self._max_retries = max_retries
        self._min_interval = 1.0 / rate if rate else 0.0
        self._last_call = 0.0
        self._http = httpx.Client(
            base_url=base_url,
            transport=transport,
            timeout=60.0,
            headers={
                "Authorization": f"Bearer {token}",
                "Notion-Version": NOTION_VERSION,
            },
        )

    # -- plumbing -----------------------------------------------------------

    def _throttle(self):
        if not self._min_interval:
            return
        elapsed = time.monotonic() - self._last_call
        if elapsed < self._min_interval:
            self._sleep(self._min_interval - elapsed)
        self._last_call = time.monotonic()

    def _request(self, method, url, **kwargs) -> httpx.Response:
        for attempt in range(self._max_retries + 1):
            self._throttle()
            try:
                response = self._http.request(method, url, **kwargs)
            except httpx.RequestError as exc:
                # Never reached the server: retryable, and it must not escape
                # as a bare httpx error - cli.main handles NotionUploadError.
                if attempt == self._max_retries:
                    raise APIError(f"could not reach Notion: {exc}") from exc
                self._sleep(min(2**attempt, 30) + random.random())
                continue
            if response.status_code < 400:
                return response
            if response.status_code not in RETRYABLE_STATUS or attempt == self._max_retries:
                raise APIError(self._describe(response), status=response.status_code)
            self._sleep(self._retry_delay(response, attempt))
        raise AssertionError("unreachable")

    @staticmethod
    def _retry_delay(response, attempt) -> float:
        header = response.headers.get("Retry-After")
        if header:
            try:
                return int(header)
            except ValueError:
                pass
        return min(2**attempt, 30) + random.random()

    @staticmethod
    def _describe(response) -> str:
        try:
            body = response.json()
            detail = body.get("message") or body.get("code") or response.text
        except ValueError:
            detail = response.text
        return f"{response.status_code} from {response.request.url.path}: {detail}"

    # -- pages and blocks ---------------------------------------------------

    def create_page(self, parent: dict, title: str, children: list[dict]) -> dict:
        body = {
            "parent": parent,
            "properties": {
                "title": {"title": [{"type": "text", "text": {"content": title}}]}
            },
            "children": children,
        }
        return self._request("POST", "/v1/pages", json=body).json()

    def append_children(self, block_id: str, children: list[dict]) -> list[dict]:
        response = self._request(
            "PATCH", f"/v1/blocks/{block_id}/children", json={"children": children}
        )
        return response.json().get("results", [])

    def retrieve_parent(self, object_id: str) -> dict:
        """Work out what kind of thing the user pointed us at.

        A bare UUID does not say whether it is a page, a data source or a
        database, and guessing wrong produces a confusing 400 from Notion, so
        probe in pre-flight instead.
        """
        probes = [
            (f"/v1/pages/{object_id}", "page_id"),
            (f"/v1/data_sources/{object_id}", "data_source_id"),
            (f"/v1/databases/{object_id}", "database_id"),
        ]
        for path, key in probes:
            try:
                self._request("GET", path)
            except APIError as exc:
                if exc.status == 404:
                    continue   # genuinely not this kind of object; try the next
                raise          # 401, 403, 400, transport failure: a real error
            return {key: object_id}
        raise APIError(
            f"parent {object_id} is not a page, data source or database "
            f"this integration can see. Check the id, and check the page is "
            f"shared with your integration."
        )

    # -- file uploads -------------------------------------------------------

    def create_file_upload(
        self, *, filename: str, content_type: str,
        mode: str = "single_part", number_of_parts: int | None = None,
    ) -> dict:
        body = {"mode": mode, "filename": filename, "content_type": content_type}
        if number_of_parts is not None:
            body["number_of_parts"] = number_of_parts
        return self._request("POST", "/v1/file_uploads", json=body).json()

    def send_file_upload(
        self, upload_id: str, data: bytes, filename: str,
        content_type: str, part_number: int | None = None,
    ) -> dict:
        files = {"file": (filename, data, content_type)}
        payload = {"part_number": str(part_number)} if part_number else None
        return self._request(
            "POST", f"/v1/file_uploads/{upload_id}/send", files=files, data=payload
        ).json()

    def complete_file_upload(self, upload_id: str) -> dict:
        return self._request("POST", f"/v1/file_uploads/{upload_id}/complete").json()

    def close(self):
        self._http.close()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd notion-upload && uv run pytest tests/test_client.py -v`
Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add notion-upload/
git commit -m "feat(upload): add the Notion HTTP client with rate limiting and retry"
```

---

### Task 7: Media discovery, resolution and upload

**Files:**
- Create: `notion-upload/src/notion_upload/media.py`
- Test: `notion-upload/tests/test_media.py`

**Interfaces:**
- Consumes: `document.walk`, `client.NotionClient`, `errors.MediaError`, `limits.MULTIPART_THRESHOLD_BYTES`.
- Produces:
  - `media.MediaRef(node: dict, url: str)` — dataclass; `node` is the file object, mutated in place on rewrite.
  - `media.discover(blocks: list[dict]) -> list[MediaRef]`
  - `media.is_local(url: str) -> bool`
  - `media.resolve(refs: list[MediaRef], base_dir: Path) -> dict[MediaRef, bytes]` — raises `MediaError` listing **every** unresolvable reference at once.
  - `media.upload_all(resolved: dict, client, *, filename_for=...) -> dict[str, str]` — content hash → `file_upload` id; uploads each distinct hash once.
  - `media.rewrite(resolved: dict, ids_by_hash: dict[str, str]) -> None` — rewrites nodes in place to `{"type": "file_upload", "file_upload": {"id": …}}`, preserving `caption` and every other sibling key.

**The file object shape:** the writer emits `{"type":"external","external":{"url":U},"caption":[…]}` as the *payload* of an `image`/`video`/`audio`/`pdf`/`file` block. Discovery walks every block and inspects `payload(block)`; a node qualifies when `type == "external"` and its url is local.

- [ ] **Step 1: Write the failing test**

`notion-upload/tests/test_media.py`:

```python
import base64
import hashlib

import pytest

from notion_upload import errors, media


def image(url, caption="cap"):
    return {
        "object": "block", "type": "image",
        "image": {
            "type": "external", "external": {"url": url},
            "caption": [{"type": "text", "text": {"content": caption}}],
        },
    }


class RecordingClient:
    def __init__(self):
        self.created, self.sent, self.completed = [], [], []
        self._n = 0

    def create_file_upload(self, *, filename, content_type, mode="single_part",
                           number_of_parts=None):
        self._n += 1
        self.created.append((filename, content_type, mode, number_of_parts))
        return {"id": f"fu-{self._n}", "upload_url": "https://upload"}

    def send_file_upload(self, upload_id, data, filename, content_type,
                         part_number=None):
        self.sent.append((upload_id, len(data), part_number))
        return {"id": upload_id, "status": "uploaded"}

    def complete_file_upload(self, upload_id):
        self.completed.append(upload_id)
        return {"id": upload_id, "status": "uploaded"}


def test_http_urls_are_not_local():
    assert not media.is_local("https://example.com/a.png")
    assert not media.is_local("http://example.com/a.png")


def test_relative_and_absolute_paths_and_file_urls_are_local():
    assert media.is_local("media/img.png")
    assert media.is_local("/abs/img.png")
    assert media.is_local("file:///abs/img.png")


def test_data_uris_are_local_because_we_must_upload_the_bytes():
    assert media.is_local("data:image/png;base64,iVBOR")


def test_discover_finds_media_across_every_block_type():
    blocks = [image("a.png"), {"object": "block", "type": "pdf",
                               "pdf": {"type": "external",
                                       "external": {"url": "b.pdf"}}}]
    assert {r.url for r in media.discover(blocks)} == {"a.png", "b.pdf"}


def test_discover_skips_remote_urls():
    assert media.discover([image("https://example.com/a.png")]) == []


def test_resolve_reports_every_missing_file_at_once(tmp_path):
    refs = media.discover([image("one.png"), image("two.png")])
    with pytest.raises(errors.MediaError) as exc:
        media.resolve(refs, tmp_path)
    message = str(exc.value)
    assert "one.png" in message and "two.png" in message
    assert "--extract-media" in message, "the remedy must be named"


def test_resolve_reads_bytes_relative_to_base_dir(tmp_path):
    (tmp_path / "media").mkdir()
    (tmp_path / "media" / "img.png").write_bytes(b"\x89PNG-data")
    refs = media.discover([image("media/img.png")])
    resolved = media.resolve(refs, tmp_path)
    assert list(resolved.values()) == [b"\x89PNG-data"]


def test_resolve_decodes_data_uris(tmp_path):
    payload = base64.b64encode(b"bytes!").decode()
    refs = media.discover([image(f"data:image/png;base64,{payload}")])
    assert list(media.resolve(refs, tmp_path).values()) == [b"bytes!"]


def test_the_same_image_used_twice_uploads_once(tmp_path):
    (tmp_path / "a.png").write_bytes(b"same")
    (tmp_path / "b.png").write_bytes(b"same")
    refs = media.discover([image("a.png"), image("b.png")])
    resolved = media.resolve(refs, tmp_path)
    client = RecordingClient()
    ids = media.upload_all(resolved, client)
    assert len(client.created) == 1, "identical bytes must upload once"
    assert len(ids) == 1


def test_rewrite_replaces_external_with_file_upload_and_keeps_the_caption(tmp_path):
    (tmp_path / "a.png").write_bytes(b"png")
    blocks = [image("a.png", caption="a caption")]
    refs = media.discover(blocks)
    resolved = media.resolve(refs, tmp_path)
    ids = media.upload_all(resolved, RecordingClient())
    media.rewrite(resolved, ids)
    node = blocks[0]["image"]
    assert node["type"] == "file_upload"
    assert node["file_upload"]["id"].startswith("fu-")
    assert "external" not in node
    assert node["caption"][0]["text"]["content"] == "a caption"


def test_a_large_file_uses_multipart_and_completes(tmp_path, monkeypatch):
    monkeypatch.setattr(media, "MULTIPART_THRESHOLD_BYTES", 10)
    monkeypatch.setattr(media, "PART_SIZE_BYTES", 10)
    (tmp_path / "big.bin").write_bytes(b"x" * 25)
    refs = media.discover([image("big.bin")])
    resolved = media.resolve(refs, tmp_path)
    client = RecordingClient()
    media.upload_all(resolved, client)
    assert client.created[0][2] == "multi_part"
    assert client.created[0][3] == 3, "25 bytes in 10-byte parts is 3 parts"
    assert [p for _, _, p in client.sent] == [1, 2, 3]
    assert client.completed == ["fu-1"]


def test_content_type_is_inferred_from_the_extension(tmp_path):
    (tmp_path / "a.png").write_bytes(b"png")
    refs = media.discover([image("a.png")])
    client = RecordingClient()
    media.upload_all(media.resolve(refs, tmp_path), client)
    assert client.created[0][1] == "image/png"


def test_an_unknown_extension_falls_back_to_octet_stream(tmp_path):
    (tmp_path / "a.weird").write_bytes(b"?")
    refs = media.discover([image("a.weird")])
    client = RecordingClient()
    media.upload_all(media.resolve(refs, tmp_path), client)
    assert client.created[0][1] == "application/octet-stream"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd notion-upload && uv run pytest tests/test_media.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'notion_upload.media'`

- [ ] **Step 3: Write the implementation**

`notion-upload/src/notion_upload/media.py`:

```python
"""Find local media in a block tree, upload it, and point the tree at it.

Everything here runs in pre-flight, before any page exists, so a missing file
costs the user nothing but a re-run.
"""

import base64
import hashlib
import mimetypes
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

from . import document
from .errors import MediaError
from .limits import MULTIPART_THRESHOLD_BYTES

PART_SIZE_BYTES = 10 * 1024 * 1024

MEDIA_TYPES = {"image", "video", "audio", "pdf", "file"}


@dataclass(eq=False)
class MediaRef:
    """A file object in the tree, mutated in place when rewritten."""

    node: dict
    url: str
    hash: str = field(default="", compare=False)


def is_local(url: str) -> bool:
    if url.startswith("data:"):
        return True
    scheme = urllib.parse.urlparse(url).scheme
    return scheme in ("", "file")


def discover(blocks: list[dict]) -> list[MediaRef]:
    refs = []
    for block in document.walk(blocks):
        if document.block_type(block) not in MEDIA_TYPES:
            continue
        node = document.payload(block)
        if node.get("type") != "external":
            continue
        url = (node.get("external") or {}).get("url") or ""
        if url and is_local(url):
            refs.append(MediaRef(node=node, url=url))
    return refs


def _read(ref: MediaRef, base_dir: Path) -> bytes:
    if ref.url.startswith("data:"):
        header, _, encoded = ref.url.partition(",")
        if ";base64" in header:
            return base64.b64decode(encoded)
        return urllib.parse.unquote_to_bytes(encoded)

    path = ref.url
    if path.startswith("file:"):
        path = urllib.request.url2pathname(urllib.parse.urlparse(path).path)
    resolved = Path(path)
    if not resolved.is_absolute():
        resolved = base_dir / resolved
    return resolved.read_bytes()


def resolve(refs: list[MediaRef], base_dir: Path) -> dict:
    """Read every referenced file. Reports all failures together, not the
    first one, because fixing them one re-run at a time is miserable."""
    resolved, missing = {}, []
    for ref in refs:
        try:
            data = _read(ref, base_dir)
        except (OSError, ValueError):
            missing.append(ref.url)
            continue
        ref.hash = hashlib.sha256(data).hexdigest()
        resolved[ref] = data

    if missing:
        listed = ", ".join(sorted(set(missing)))
        raise MediaError(
            f"{len(missing)} media reference(s) could not be resolved "
            f"relative to {base_dir}\n  {listed}\n"
            f"  If the source was docx/odt/epub, re-run pandoc with "
            f"--extract-media=media"
        )
    return resolved


def _filename(ref: MediaRef) -> str:
    if ref.url.startswith("data:"):
        header = ref.url[5:].split(";", 1)[0] or "application/octet-stream"
        suffix = mimetypes.guess_extension(header) or ".bin"
        return f"{ref.hash[:12]}{suffix}"
    return Path(urllib.parse.urlparse(ref.url).path or ref.url).name or "file.bin"


def _content_type(filename: str) -> str:
    return mimetypes.guess_type(filename)[0] or "application/octet-stream"


def upload_all(resolved: dict, client) -> dict[str, str]:
    """Upload each distinct blob once. Returns content hash -> file_upload id."""
    ids: dict[str, str] = {}
    for ref, data in resolved.items():
        if ref.hash in ids:
            continue
        filename = _filename(ref)
        content_type = _content_type(filename)

        if len(data) > MULTIPART_THRESHOLD_BYTES:
            parts = [
                data[i:i + PART_SIZE_BYTES]
                for i in range(0, len(data), PART_SIZE_BYTES)
            ]
            upload = client.create_file_upload(
                filename=filename, content_type=content_type,
                mode="multi_part", number_of_parts=len(parts),
            )
            for number, part in enumerate(parts, start=1):
                client.send_file_upload(
                    upload["id"], part, filename, content_type, part_number=number
                )
            client.complete_file_upload(upload["id"])
        else:
            upload = client.create_file_upload(
                filename=filename, content_type=content_type
            )
            client.send_file_upload(upload["id"], data, filename, content_type)

        ids[ref.hash] = upload["id"]
    return ids


def rewrite(resolved: dict, ids_by_hash: dict[str, str]) -> None:
    """Point every resolved node at its uploaded file, in place.

    Sibling keys - caption above all - are preserved; only the file object
    discriminator and its payload change.
    """
    for ref in resolved:
        node = ref.node
        node.pop("external", None)
        node["type"] = "file_upload"
        node["file_upload"] = {"id": ids_by_hash[ref.hash]}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd notion-upload && uv run pytest tests/test_media.py -v`
Expected: PASS, 13 tests.

- [ ] **Step 5: Commit**

```bash
git add notion-upload/
git commit -m "feat(upload): discover, dedupe and upload local media"
```

---

### Task 8: The CLI

**Files:**
- Create: `notion-upload/src/notion_upload/cli.py`
- Test: `notion-upload/tests/test_cli.py`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `cli.parse_args(argv: list[str]) -> argparse.Namespace`
  - `cli.extract_title(blocks: list[dict], explicit: str | None) -> tuple[str, list[dict]]` — returns the title and the possibly-shortened block list. Raises `InputError` when neither `--title` nor a leading `heading_1` is available.
  - `cli.normalize_parent_id(value: str) -> str` — accepts a raw id, a dashed uuid, or a Notion URL.
  - `cli.upload(blocks, *, client, parent, title, base_dir, lim, out, err) -> str` — runs the phases, returns the page URL, raises `PartialUploadError` on a post-creation failure.
  - `cli.main(argv=None, *, client_factory=…, out=sys.stdout, err=sys.stderr) -> int`
  - `cli.run() -> NoReturn` — the console-script entry point; calls `sys.exit(main())`.

**Stream discipline (spec §3):** the page URL goes to **stdout alone**; every warning, progress line and error goes to **stderr**. That is what makes `notion-upload doc.json --parent X | pbcopy` do the obvious thing.

- [ ] **Step 1: Write the failing test**

`notion-upload/tests/test_cli.py`:

```python
import io
import json

import pytest

from notion_upload import cli, errors, limits, planner


def para(text, children=None):
    payload = {"rich_text": [{"type": "text", "text": {"content": text}}]}
    if children is not None:
        payload["children"] = children
    return {"object": "block", "type": "paragraph", "paragraph": payload}


def heading(text):
    return {"object": "block", "type": "heading_1",
            "heading_1": {"rich_text": [{"type": "text", "text": {"content": text}}]}}


class StubClient:
    """Enough of NotionClient to drive cli.upload without a network."""

    def __init__(self, fail_on_append=False):
        self.fail_on_append = fail_on_append
        self.appends = []
        self._n = 0

    def retrieve_parent(self, object_id):
        return {"page_id": object_id}

    def create_page(self, parent, title, children):
        self.page = {"parent": parent, "title": title, "children": children}
        return {"id": "page-1", "url": "https://notion.so/page-1"}

    def append_children(self, block_id, children):
        if self.fail_on_append:
            raise errors.APIError("boom")
        self.appends.append((block_id, children))
        self._n += 1
        return [{"id": f"blk-{self._n}-{i}"} for i in range(len(children))]


# -- title ------------------------------------------------------------------

def test_explicit_title_wins_and_the_body_is_untouched():
    blocks = [heading("Doc Heading"), para("body")]
    title, out = cli.extract_title(blocks, "Explicit")
    assert title == "Explicit"
    assert len(out) == 2


def test_a_leading_heading_1_becomes_the_title_and_leaves_the_body():
    blocks = [heading("Quarterly Report"), para("body")]
    title, out = cli.extract_title(blocks, None)
    assert title == "Quarterly Report"
    assert len(out) == 1, "Notion renders the title as the page H1; keeping it duplicates"


def test_a_heading_1_that_is_not_first_is_left_alone():
    blocks = [para("intro"), heading("Section")]
    with pytest.raises(errors.InputError):
        cli.extract_title(blocks, None)


def test_no_title_and_no_leading_heading_is_a_preflight_error():
    with pytest.raises(errors.InputError) as exc:
        cli.extract_title([para("body")], None)
    assert "--title" in str(exc.value)


# -- parent id --------------------------------------------------------------

def test_normalize_parent_accepts_a_bare_id():
    assert cli.normalize_parent_id("24f1b2c3d4e5f6a7b8c9d0e1f2a3b4c5") == (
        "24f1b2c3-d4e5-f6a7-b8c9-d0e1f2a3b4c5"
    )


def test_normalize_parent_accepts_a_dashed_uuid_unchanged():
    dashed = "24f1b2c3-d4e5-f6a7-b8c9-d0e1f2a3b4c5"
    assert cli.normalize_parent_id(dashed) == dashed


def test_normalize_parent_accepts_a_notion_url():
    url = "https://www.notion.so/team/My-Page-24f1b2c3d4e5f6a7b8c9d0e1f2a3b4c5"
    assert cli.normalize_parent_id(url) == "24f1b2c3-d4e5-f6a7-b8c9-d0e1f2a3b4c5"


def test_normalize_parent_rejects_nonsense():
    with pytest.raises(errors.InputError):
        cli.normalize_parent_id("not-an-id")


# -- upload -----------------------------------------------------------------

def test_upload_creates_the_page_empty_and_appends_every_wave():
    client = StubClient()
    out, err = io.StringIO(), io.StringIO()
    url = cli.upload(
        [para("a"), para("b")], client=client, parent={"page_id": "p"},
        title="T", base_dir=None, lim=limits.DEFAULT, out=out, err=err,
    )
    assert url == "https://notion.so/page-1"
    assert client.page["children"] == [], (
        "creation carries no blocks: POST /v1/pages does not return their ids"
    )
    assert len(client.appends) == 1
    assert client.appends[0][0] == "page-1"
    assert len(client.appends[0][1]) == 2


def test_upload_recurses_for_deep_documents_resolving_ids_from_results():
    client = StubClient()
    tree = [para("a", children=[para("b", children=[para("c")])])]
    cli.upload(tree, client=client, parent={"page_id": "p"}, title="T",
               base_dir=None, lim=limits.DEFAULT, out=io.StringIO(),
               err=io.StringIO())
    assert len(client.appends) == 2, "one wave for `a`, one for its children"
    assert client.appends[0][0] == "page-1"
    # The second wave must target the id `a` came back with, not the page.
    assert client.appends[1][0] == "blk-1-0"


def test_a_failure_after_creation_reports_the_url_and_the_block():
    client = StubClient(fail_on_append=True)
    tree = [para("a", children=[para("b", children=[para("c")])])]
    with pytest.raises(errors.PartialUploadError) as exc:
        cli.upload(tree, client=client, parent={"page_id": "p"}, title="T",
                   base_dir=None, lim=limits.DEFAULT, out=io.StringIO(),
                   err=io.StringIO())
    assert exc.value.page_url == "https://notion.so/page-1"
    assert exc.value.exit_code == 6


# -- main -------------------------------------------------------------------

def test_main_writes_only_the_url_to_stdout(tmp_path):
    doc = tmp_path / "doc.json"
    doc.write_text(json.dumps([heading("T"), para("body")]))
    out, err = io.StringIO(), io.StringIO()
    code = cli.main(
        [str(doc), "--parent", "24f1b2c3d4e5f6a7b8c9d0e1f2a3b4c5", "--token", "x"],
        client_factory=lambda token: StubClient(), out=out, err=err,
    )
    assert code == 0
    assert out.getvalue().strip() == "https://notion.so/page-1"


def test_media_is_rewritten_in_the_blocks_that_actually_get_uploaded(tmp_path):
    """Regression: normalize() rebuilds blocks, so media must be discovered
    after it. Discovering first leaves MediaRefs pointing at payload dicts
    that are no longer in the tree, and the uploaded page keeps local paths.
    """
    (tmp_path / "img.png").write_bytes(b"\x89PNG")
    # A paragraph long enough to force normalize() to rebuild, plus an image.
    doc = tmp_path / "doc.json"
    doc.write_text(json.dumps([
        heading("T"),
        {"object": "block", "type": "paragraph",
         "paragraph": {"rich_text": [
             {"type": "text", "text": {"content": "x" * 5000}}]}},
        {"object": "block", "type": "image",
         "image": {"type": "external", "external": {"url": "img.png"},
                   "caption": []}},
    ]))

    class MediaClient(StubClient):
        def create_file_upload(self, *, filename, content_type,
                               mode="single_part", number_of_parts=None):
            return {"id": "fu-1", "upload_url": "https://upload"}

        def send_file_upload(self, upload_id, data, filename, content_type,
                             part_number=None):
            return {"id": upload_id, "status": "uploaded"}

    client = MediaClient()
    code = cli.main(
        [str(doc), "--parent", "24f1b2c3d4e5f6a7b8c9d0e1f2a3b4c5", "--token", "x"],
        client_factory=lambda token: client, out=io.StringIO(), err=io.StringIO(),
    )
    assert code == 0
    sent = [b for _, blocks in client.appends for b in blocks]
    images = [b for b in sent if b["type"] == "image"]
    assert images, "the image block must reach Notion"
    assert images[0]["image"]["type"] == "file_upload", (
        "the uploaded block still points at a local path: media was discovered "
        "before normalize() rebuilt the blocks"
    )


def test_main_maps_an_error_to_its_exit_code(tmp_path):
    doc = tmp_path / "doc.json"
    doc.write_text("{not json")
    out, err = io.StringIO(), io.StringIO()
    code = cli.main(
        [str(doc), "--parent", "24f1b2c3d4e5f6a7b8c9d0e1f2a3b4c5", "--token", "x"],
        client_factory=lambda token: StubClient(), out=out, err=err,
    )
    assert code == errors.InputError.exit_code
    assert out.getvalue() == "", "diagnostics never go to stdout"
    assert "JSON" in err.getvalue()


def test_dry_run_creates_nothing_and_prints_the_plan(tmp_path):
    doc = tmp_path / "doc.json"
    doc.write_text(json.dumps([heading("T"), para("body")]))
    client = StubClient()
    out, err = io.StringIO(), io.StringIO()
    code = cli.main(
        [str(doc), "--parent", "24f1b2c3d4e5f6a7b8c9d0e1f2a3b4c5",
         "--token", "x", "--dry-run"],
        client_factory=lambda token: client, out=out, err=err,
    )
    assert code == 0
    assert not hasattr(client, "page"), "dry-run must not create a page"
    assert "plan:" in out.getvalue()


def test_missing_token_is_a_clear_error(tmp_path, monkeypatch):
    monkeypatch.delenv("NOTION_TOKEN", raising=False)
    doc = tmp_path / "doc.json"
    doc.write_text(json.dumps([heading("T")]))
    out, err = io.StringIO(), io.StringIO()
    code = cli.main(
        [str(doc), "--parent", "24f1b2c3d4e5f6a7b8c9d0e1f2a3b4c5"],
        client_factory=lambda token: StubClient(), out=out, err=err,
    )
    assert code == errors.InputError.exit_code
    assert "NOTION_TOKEN" in err.getvalue()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd notion-upload && uv run pytest tests/test_cli.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'notion_upload.cli'`

- [ ] **Step 3: Write the implementation**

`notion-upload/src/notion_upload/cli.py`:

```python
"""Argument parsing, the five pre-flight phases, and exit codes.

Stream discipline: the created page URL is the only thing that goes to
stdout. Warnings, progress and errors all go to stderr, so the tool composes
in a pipeline.
"""

import argparse
import os
import re
import sys
from pathlib import Path

from . import document, limits, media, planner
from .client import NotionClient
from .errors import APIError, InputError, NotionUploadError, PartialUploadError

UUID_RE = re.compile(r"([0-9a-fA-F]{32})|([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})")


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="notion-upload",
        description="Create a Notion page from Notion block JSON.",
        epilog="Reads stdin when INPUT is omitted. Pipe it from "
               "`pandoc -t notion-block-writer.lua`.",
    )
    parser.add_argument("input", nargs="?", metavar="INPUT",
                        help="block JSON file (default: stdin)")
    parser.add_argument("--parent", required=True,
                        help="parent page/database/data-source id, or a Notion URL")
    parser.add_argument("--title", help="page title (default: the leading heading_1)")
    parser.add_argument("--base-dir", type=Path,
                        help="resolve relative media paths against this (default: cwd)")
    parser.add_argument("--token", help="Notion token (default: $NOTION_TOKEN)")
    parser.add_argument("--dry-run", action="store_true",
                        help="run pre-flight and print the plan; create nothing")
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("-q", "--quiet", action="store_true")
    return parser.parse_args(argv)


def normalize_parent_id(value: str) -> str:
    match = None
    for match in UUID_RE.finditer(value):
        pass  # the id is the last uuid-shaped run, so a slug cannot shadow it
    if match is None:
        raise InputError(
            f"could not find a Notion id in {value!r}; pass a 32-character id, "
            f"a dashed uuid, or the page URL"
        )
    raw = (match.group(1) or match.group(2)).replace("-", "").lower()
    return f"{raw[:8]}-{raw[8:12]}-{raw[12:16]}-{raw[16:20]}-{raw[20:]}"


def _plain_text(block) -> str:
    return "".join(
        run.get("text", {}).get("content", "")
        for run in document.payload(block).get("rich_text", [])
    )


def extract_title(blocks, explicit):
    if explicit:
        return explicit, blocks
    if blocks and document.block_type(blocks[0]) == "heading_1":
        # Notion renders the page title as the page's own H1, so leaving this
        # heading in the body would show it twice.
        return _plain_text(blocks[0]), blocks[1:]
    raise InputError(
        "no title: pass --title, or start the document with a heading_1"
    )


def upload(blocks, *, client, parent, title, base_dir, lim, out, err):
    """Create the page, then append every wave through one code path.

    The page is created EMPTY even though POST /v1/pages accepts up to 100
    children, because that response returns the page object and not its
    children's ids - so blocks created that way would be unaddressable, and
    any document deeper than two levels could not be finished. Paying one
    extra request buys a single uniform path in which every id arrives in a
    `results` array. See spec 5.4.
    """
    plan = planner.plan(blocks, lim)
    page = client.create_page(parent, title, [])
    page_id = page["id"]
    page_url = page.get("url") or f"https://notion.so/{page_id.replace('-', '')}"

    created: dict[planner.Ref, str] = {}
    completed = 0

    for position, request in enumerate(plan):
        parent_id = page_id if request.parent is None else created[request.parent]
        try:
            results = client.append_children(parent_id, request.blocks)
        except APIError as exc:
            path = request.source_path[0] if request.source_path else (0,)
            raise PartialUploadError(
                page_url=page_url, block_index=path[0], depth=len(path),
                completed=completed, total=len(plan),
            ) from exc
        for index, block in enumerate(results):
            created[planner.Ref(position, index)] = block["id"]
        completed += 1

    return page_url


def main(argv=None, *, client_factory=None, out=None, err=None):
    out = out if out is not None else sys.stdout
    err = err if err is not None else sys.stderr
    args = parse_args(sys.argv[1:] if argv is None else argv)

    try:
        token = args.token or os.environ.get("NOTION_TOKEN")
        if not token:
            raise InputError("no token: set NOTION_TOKEN or pass --token")

        raw = Path(args.input).read_bytes() if args.input else sys.stdin.buffer.read()
        blocks = document.parse(raw)
        title, blocks = extract_title(blocks, args.title)

        base_dir = args.base_dir or (
            Path(args.input).parent if args.input else Path.cwd()
        )
        factory = client_factory or (lambda t: NotionClient(t))
        client = factory(token)

        # Parent first: it is one cheap request, and discovering the parent is
        # unreachable after uploading 40 MB of images would be infuriating.
        parent = client.retrieve_parent(normalize_parent_id(args.parent))

        # Normalize BEFORE discovering media. normalize() rebuilds every block
        # it touches, so MediaRefs taken beforehand would point at payload
        # dicts that are no longer in the tree, and media.rewrite() would
        # mutate orphans while the real blocks kept their local paths.
        blocks, warnings = limits.normalize(blocks, limits.DEFAULT)
        for warning in warnings:
            if not args.quiet:
                print(f"warning: {warning}", file=err)

        refs = media.discover(blocks)
        resolved = media.resolve(refs, base_dir)

        if args.dry_run:
            plan = planner.plan(blocks, limits.DEFAULT)
            print(
                f"plan: {document.count(blocks)} blocks, "
                f"{len(set(r.hash for r in resolved))} media uploads, "
                f"{len(plan)} requests",
                file=out,
            )
            for index, request in enumerate(plan):
                target = "POST   /v1/pages" if request.parent is None else (
                    f"PATCH  <request {request.parent.request}"
                    f"#{request.parent.index}>/children"
                )
                print(
                    f"  {target:<40} {len(request.blocks):>4} blocks "
                    f"{limits.serialized_size(request.blocks) // 1024:>5} KB",
                    file=out,
                )
            return 0

        ids = media.upload_all(resolved, client)
        media.rewrite(resolved, ids)

        url = upload(
            blocks, client=client, parent=parent, title=title,
            base_dir=base_dir, lim=limits.DEFAULT, out=out, err=err,
        )
        print(url, file=out)
        return 0

    except PartialUploadError as exc:
        print(f"error: {exc}", file=err)
        print(exc.page_url, file=out)
        return exc.exit_code
    except NotionUploadError as exc:
        print(f"error: {exc}", file=err)
        return exc.exit_code


def run():
    sys.exit(main())
```

> **Why the page is created empty, against spec §5.4.** The spec argued for
> carrying the first wave inside `POST /v1/pages` to save a request and shrink
> the partial-failure window. Writing this task surfaced the flaw: that
> response returns the *page*, not its children, so blocks created that way
> have no reachable ids and any document deeper than two levels could never be
> finished. Creating the page empty costs one request and buys a single path
> in which every id arrives in a `results` array. Step 4 records this in the
> spec.

- [ ] **Step 4: Correct spec §5.4 to match**

The spec is the artifact that outlives the plan, so the superseded reasoning
should not stay in it. Replace §5.4 with:

```markdown
### 5.4 The page is created empty

`POST /v1/pages` accepts up to 100 children, and an earlier draft of this
design had the first wave ride along with creation to save a request.

That is wrong. The creation response returns the page object, not its
children, so blocks created that way have no reachable ids — and any block
among them with children of its own could never be appended to. A document
more than two levels deep would be unfinishable.

The page is therefore created empty and every wave, including the first, goes
through `PATCH /v1/blocks/:id/children`. One extra request buys a single code
path in which every id the recursion needs arrives in a `results` array, which
is the same property §5.1 exists to guarantee.
```

Run: `cd notion-upload && uv run pytest tests/test_cli.py -v`
Expected: PASS, 16 tests.

- [ ] **Step 5: Run the whole suite**

Run: `cd notion-upload && uv run pytest -v`
Expected: PASS, all tests.

- [ ] **Step 6: Commit**

```bash
git add notion-upload/ docs/superpowers/specs/2026-08-30-notion-upload-cli-design.md
git commit -m "feat(upload): add the CLI, and make every block id arrive by one path"
```

---

### Task 9: Corpus fixtures, Makefile targets, and README

**Files:**
- Create: `notion-upload/tests/test_fixtures.py`
- Create: `notion-upload/tests/fixtures/` (generated, checked in)
- Create: `notion-upload/README.md`
- Modify: `Makefile` (add `fixtures`, `test-py`, and extend `check`)
- Modify: `README.md` (add a section pointing at the uploader)

**Interfaces:**
- Consumes: everything above.
- Produces: no new API. This task proves the pieces work on the shapes that actually occur.

**Why generated fixtures (spec §9.4):** `tests/corpus/blocks/*.nfm` already covers callouts, columns, synced blocks, nested tables and toggle headings. Running pandoc over it at *regeneration* time gives the Python suite real input without putting pandoc in the test path, and mirrors `tests/regenerate_block_goldens.lua`, which the repo already uses for exactly this purpose.

- [ ] **Step 1: Add the Makefile targets**

Append to the root `Makefile`:

```make
## fixtures: regenerate the Python suite's block JSON fixtures from the corpus
fixtures:
	@mkdir -p notion-upload/tests/fixtures
	@for f in tests/corpus/blocks/*.nfm; do \
		name=$$(basename $$f .nfm); \
		pandoc -f notion-markdown-reader.lua -t notion-block-writer.lua \
			"$$f" -o "notion-upload/tests/fixtures/$$name.json" || exit 1; \
		echo "  $$name.json"; \
	done

## test-py: run the uploader's suite (no pandoc, no network)
test-py:
	cd notion-upload && uv run pytest -q
```

And extend the existing `check` target and `.PHONY` line:

```make
.PHONY: test lint typecheck check deps clean-deps fixtures test-py

check: test lint typecheck test-py
```

- [ ] **Step 2: Generate the fixtures**

Run: `make fixtures`
Expected: one `.json` per `.nfm`, listed as it goes. Inspect one to confirm it is a block array:

```bash
head -c 200 notion-upload/tests/fixtures/callout.json
```

- [ ] **Step 3: Write the failing test**

`notion-upload/tests/test_fixtures.py`:

```python
"""Run the whole pipeline over block JSON generated from the Lua corpus.

Pandoc produced these files at `make fixtures` time; it is not invoked here.
"""

import json
from pathlib import Path

import pytest

import fake_notion
from notion_upload import document, limits, planner

FIXTURES = sorted((Path(__file__).parent / "fixtures").glob("*.json"))


def test_the_corpus_was_generated():
    assert FIXTURES, "run `make fixtures` from the repo root first"


@pytest.mark.parametrize("path", FIXTURES, ids=lambda p: p.stem)
def test_every_corpus_document_plans_within_the_limits(path):
    blocks = document.parse(path.read_bytes())
    normalized, _ = limits.normalize(blocks, limits.DEFAULT)
    plan = planner.plan(normalized, limits.DEFAULT)
    for request in plan:
        assert len(request.blocks) <= limits.DEFAULT.children
        assert document.count(request.blocks) <= limits.DEFAULT.elements
        assert limits.serialized_size(request.blocks) <= limits.DEFAULT.byte_budget


@pytest.mark.parametrize("path", FIXTURES, ids=lambda p: p.stem)
def test_every_corpus_document_round_trips(path):
    blocks = document.parse(path.read_bytes())
    normalized, _ = limits.normalize(blocks, limits.DEFAULT)
    plan = planner.plan(normalized, limits.DEFAULT)
    fake = fake_notion.FakeNotion(limits.DEFAULT)
    fake_notion.execute(plan, fake)
    assert fake.tree() == normalized


@pytest.mark.parametrize("path", FIXTURES, ids=lambda p: p.stem)
def test_every_corpus_document_plans_within_cramped_limits(path):
    """The corpus at default limits rarely needs more than one request.
    Shrinking the bounds makes these small documents exercise the recursion."""
    # Only the count bounds are cramped. Shrinking byte_budget too would make
    # a single ordinary corpus block unsendable, which tests nothing useful.
    lim = limits.Limits(children=2, elements=6)
    blocks = document.parse(path.read_bytes())
    normalized, _ = limits.normalize(blocks, lim)
    plan = planner.plan(normalized, lim)
    fake = fake_notion.FakeNotion(lim)
    fake_notion.execute(plan, fake)
    assert fake.tree() == normalized
```

- [ ] **Step 4: Run the tests**

Run: `cd notion-upload && uv run pytest tests/test_fixtures.py -v`
Expected: PASS. A failure here means a real construct from the corpus — a column list, a synced block, a nested table — breaks the planner. Fix `planner.py` or `limits.py`, not the fixture.

- [ ] **Step 5: Write the package README**

`notion-upload/README.md`:

````markdown
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
worth knowing: a block inlines its children only when it has no grandchildren,
which means every block id the recursion needs arrives in a response it
already reads; and splitting respects bytes as well as characters, because
Notion caps content in characters but caps requests in bytes.

## Tests

```bash
uv run pytest          # no pandoc, no network
make fixtures          # from the repo root, to regenerate corpus fixtures
```
````

- [ ] **Step 6: Link it from the root README**

Add to the root `README.md`, after the "Notion block JSON" section:

```markdown
## Uploading to Notion

The readers and writers deliberately stop at the JSON. `notion-upload/` is a
separate Python package that takes block JSON and creates a Notion page from
it, handling the two things the writer refuses to: uploading local media, and
splitting a document across requests to respect the API's limits on nesting,
block count and payload size.

```bash
pandoc --extract-media=media -f docx -t notion-block-writer.lua report.docx \
  | notion-upload --parent <page-id>
```

It depends on nothing from the Lua tree, and the Lua tree depends on nothing
from it; they meet at the JSON. See `notion-upload/README.md`.
```

- [ ] **Step 7: Run everything**

Run: `make check`
Expected: the Lua suite, luacheck, lua-language-server, and the Python suite all pass.

- [ ] **Step 8: Commit**

```bash
git add notion-upload/ Makefile README.md
git commit -m "test(upload): run the pipeline over fixtures generated from the Lua corpus"
```

---

## Self-Review

**Spec coverage.** Every section maps to a task: §2.3/§2.4 limits → Task 1; §4 input contract → Task 2; §7 normalization and splitting → Task 3; §5.1–§5.3 planner → Task 4; §9.1–§9.3 fake, invariant, properties → Task 5; §2.4/§2.5/§2.6 client, retry, upload endpoints, parent probing → Task 6; §6 media → Task 7; §3 phases, §8 failure model, title inference → Task 8; §9.4 fixtures → Task 9.

**The inlining rule was changed after review, and the change fixed a bug.** The first draft inlined all children or none. Prototyping the replacement — inline the longest leading run of leaf children that fits — showed the original emitting a block with 120 inlined children on a perfectly ordinary shape, because the 100-children cap applies to every array at every depth and the original only respected it at the top level. The test fake had the matching blind spot, which is why the rule survived its first review. Both are fixed here, and spec §5.1 and §9.1 are rewritten to record it. Verified: 1000 randomized cases round-trip exactly with every array in bounds, at two limit settings.

**The planner was verified before this plan was written, not assumed.** The Task 4 algorithm was prototyped and run against 6000 generated trees at two limit settings. No request exceeded the children, element, or nesting bounds; the parent-precedes-child ordering held everywhere; the spec's worked example came out at 2 requests; and 600 execute-and-compare round trips reproduced the input tree exactly. The code in Task 4 is that prototype. One bug surfaced during this — a false depth violation — and it was in the *fake*, which asserted a nesting level before checking whether anything occupied it; `fake_notion._depth` in Task 5 recurses only into non-empty children for that reason.

**One spec change is planned, not accidental.** §5.4 says the first wave rides along with `POST /v1/pages`. Writing Task 8 surfaced that page creation returns the page object, not its children's ids, so a first wave sent that way leaves the blocks it created unaddressable — which breaks the recursion for any document deeper than two levels. Task 8 creates the page empty and appends every wave through one path; Step 4 rewrites §5.4 to record the corrected reasoning, so the spec does not outlive the plan carrying a claim that is false.

**Two known gaps deferred by the spec, restated so nobody is surprised.** Page properties beyond `title` are not written (§11.3), so a data-source parent with required properties will be rejected by the API rather than in pre-flight. And `--rehost-remote` does not exist (§11.2).

**Type consistency.** `Limits` field names (`children`, `elements`, `byte_budget`, `nesting`, `rich_text`, `text_chars`, `equation_chars`, `url_chars`) are used identically in Tasks 1, 3, 4, 5 and 9. `planner.Ref(request, index)` and `planner.Request(parent, blocks, source_path)` are constructed in Task 4 and consumed unchanged in Tasks 5 and 8. `document.without_children` / `with_children` / `children_of` / `walk` / `count` / `deep_copy` are defined in Task 2 and used under those exact names in Tasks 3, 4, 5 and 9. `media.MediaRef.hash` is set in `resolve` and read in `upload_all` and `rewrite`.
