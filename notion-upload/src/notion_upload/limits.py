"""Notion's documented limits, and the transformations that respect them.

Every value here is quoted from Notion's API documentation; see spec 2.3.
They live in a frozen dataclass rather than as bare module constants so that
tests can vary them - a planner bug is far easier to reproduce at
`Limits(children=3)` than at `Limits(children=100)`.
"""

import json
from dataclasses import dataclass

from . import document
from .errors import LimitError

NOTION_VERSION = "2026-03-11"

# Files above this size must use the multi-part upload mode.
MULTIPART_THRESHOLD_BYTES = 20 * 1024 * 1024


@dataclass(frozen=True)
class Limits:
    # Per request.
    children: int = 100          # top-level entries in a children array
    elements: int = 1000         # total blocks, counting inlined children
    byte_budget: int = 500_000   # serialized payload
    # Levels of `children` BELOW a request's top level. 2 means a top-level
    # block may carry children and grandchildren in the same request, which is
    # what makes `column_list > column > content` sendable at all. The planner
    # reads this to decide how far to inline; see planner._prepare.
    nesting: int = 2

    # Per block.
    rich_text: int = 100         # elements in one rich_text array
    text_chars: int = 2000       # characters in one text.content
    equation_chars: int = 1000   # characters in one equation.expression
    url_chars: int = 2000        # characters in any URL


DEFAULT = Limits()


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


def _check_fits_alone(block: dict, lim: Limits, kind: str, index: int) -> None:
    """The guarantee normalize() makes, checked rather than assumed.

    Splitting `rich_text` into sibling blocks brings almost everything inside
    the budget. What it cannot reach is a block whose bulk is somewhere else -
    a wide table_row, a block with an enormous caption - and §5.2's totality
    argument rests on there being no such block in the planner's input. If one
    survives, saying so here beats a 500 KB request Notion rejects after the
    page exists.
    """
    size = serialized_size(block)
    if size > lim.byte_budget:
        raise LimitError(
            f"{kind} at index {index} serializes to {size} bytes on its own; "
            f"the request limit is {lim.byte_budget} and this block cannot be "
            f"split any further without changing what it means"
        )


def _fit_runs(runs: list[dict], lim: Limits, kind: str, index: int, field: str) -> list[dict]:
    """Merge and split a rich_text array that cannot become sibling blocks.

    `rich_text` overflow is handled by cutting the block into consecutive
    siblings (§7.2). A caption or a table cell has no such escape: a second
    copy of the block would be a second image, a second row would be a
    different table. So merge, split the text at the character bound, and if
    the element bound is still breached say so in pre-flight.
    """
    runs = split_text_content(merge_runs(runs), lim.text_chars)
    if len(runs) > lim.rich_text:
        raise LimitError(
            f"{kind} at index {index}: {field} still holds {len(runs)} rich_text "
            f"elements after merging; the limit is {lim.rich_text}, and splitting "
            f"a {kind} into siblings to carry the overflow would change what the "
            f"document means"
        )
    return runs


def normalize(blocks: list[dict], lim: Limits) -> tuple[list[dict], list[str]]:
    """Merge, split, and recurse. Returns new blocks and warnings.

    Deep-copies once at entry so the result shares no mutable state with
    the caller's tree - callers rewrite media file objects in the returned
    blocks, and that must never reach back into the input.

    Guarantee on return: every childless block in the result fits alone
    inside byte_budget, which is what makes the planner's packing total.
    Blocks that cannot be brought inside it - because the text that overflows
    is a caption or a table row, neither of which can be split into siblings -
    do not come back at all: they raise LimitError in pre-flight.
    """
    return _normalize(document.deep_copy(blocks), lim)


def _normalize(blocks: list[dict], lim: Limits) -> tuple[list[dict], list[str]]:
    """Recursive worker behind normalize; see its docstring for the contract."""
    out: list[dict] = []
    warnings: list[str] = []

    for index, block in enumerate(blocks):
        _check_unsplittable(block, lim, index)

        kind = document.block_type(block)
        kids = document.children_of(block)
        current = document.without_children(block)
        body = document.payload(current)

        # `rich_text` is not the only rich-text-bearing field. A caption and a
        # table_row's cells carry the same objects and are bound by the same
        # character, element and byte limits; treating them as opaque left a
        # 5000-character cell and a 646 KB row to be discovered by Notion.
        caption = body.get("caption")
        if isinstance(caption, list) and caption:
            body["caption"] = _fit_runs(caption, lim, kind, index, "caption")

        cells = body.get("cells")
        if isinstance(cells, list):
            body["cells"] = [
                _fit_runs(cell, lim, kind, index, f"cell {column}")
                if isinstance(cell, list) and cell else cell
                for column, cell in enumerate(cells)
            ]

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

        for piece in pieces:
            _check_fits_alone(piece, lim, kind, index)

        if kids:
            normalized_kids, child_warnings = _normalize(kids, lim)
            warnings.extend(child_warnings)
            # Children belong to the first piece; the rest are continuations.
            pieces[0] = document.with_children(pieces[0], normalized_kids)

        out.extend(pieces)

    return out, warnings
