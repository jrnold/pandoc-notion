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
from .errors import LimitError
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


# Blocks Notion refuses to create childless. The generic "strip the children
# and defer them to a wave of their own" escape hatch is exactly what these
# forbid: a `column_list` must arrive with at least two `column` children, and
# each `column` with at least one child of its own. When one of these cannot
# be sent whole there is no legal request to fall back to, so the planner
# refuses before anything has been created.
MANDATORY_CHILDREN = frozenset({"column_list", "column"})


def _subtree_depth(block: dict) -> int:
    """Levels of children below `block`: 0 for a leaf, 1 when every child is
    a leaf, 2 for a block with grandchildren."""
    kids = document.children_of(block)
    if not kids:
        return 0
    return 1 + max(_subtree_depth(kid) for kid in kids)


def _arrays_within(block: dict, cap: int) -> bool:
    """True when every children array in `block`'s subtree is within `cap`."""
    kids = document.children_of(block)
    return len(kids) <= cap and all(_arrays_within(kid, cap) for kid in kids)


def _prepare(block: dict, lim: Limits, path: tuple[int, ...] = ()) -> tuple[dict, list[dict], int]:
    """Return the payload for one block, the children it must defer, and how
    many children were inlined.

    Inline the longest LEADING run of children that fit, up to `lim.nesting`
    levels deep - with `nesting=2` a block carries its children and their
    children in one request, which is what a `column_list` requires and what
    Notion's nesting bound allows. Everything from the first child that cannot
    be inlined onward is deferred.

    A leading run and not an arbitrary subset, because deferred children are
    appended to the parent and therefore land after whatever was inlined -
    taking a prefix is what keeps document order without needing the
    `position` parameter.

    All-or-nothing below the first level. A LEAF child may be taken on its
    own, but a child that has children of its own is inlined only if its
    ENTIRE subtree comes with it. Inlining a prefix of grandchildren would
    require that child's id to append the remainder, and that child is not
    top-level in any request, so no id ever arrives for it - which is exactly
    the guarantee (§5.1) that no GET is ever required.

    The inlined count lets the caller offset the deferred wave's source
    paths, since that wave starts partway through the original children.

    Note the `lim.children` check: the 100-children cap applies to every
    children array, not only the request's top-level one, so a block with 120
    leaf children cannot carry them all however much byte budget is spare -
    and an inlined grandchild array is bound by it too.
    """
    kids = document.children_of(block)
    if not kids:
        _require_children(block, kids, [], lim, path)
        return document.without_children(block), [], 0

    # One of the request's `lim.nesting` levels goes to the child itself.
    depth_left = lim.nesting - 1

    taken: list[dict] = []
    for kid in kids:
        if len(taken) >= lim.children:
            break
        if document.children_of(kid) and (
            depth_left < 1
            or _subtree_depth(kid) > depth_left
            or not _arrays_within(kid, lim.children)
        ):
            break  # cannot come whole, and a prefix of it would be unaddressable
        trial = document.with_children(block, taken + [kid])
        if document.count([trial]) > lim.elements:
            break
        if serialized_size([trial]) > lim.byte_budget:
            break
        taken.append(kid)

    deferred = list(kids[len(taken):])
    _require_children(block, kids, taken, lim, path)
    if not taken:
        return document.without_children(block), deferred, 0
    return document.with_children(block, taken), deferred, len(taken)


def _require_children(block, kids, taken, lim, path) -> None:
    """Refuse, before anything is created, to emit a request Notion rejects."""
    kind = document.block_type(block)
    if kind not in MANDATORY_CHILDREN or len(taken) == len(kids):
        return
    where = ("block " + ".".join(str(step) for step in path)) if path else "the document root"
    if not kids:
        raise LimitError(
            f"{kind} at {where} has no children; Notion creates a {kind} only "
            f"with its children, so there is nothing legal to send"
        )
    too_deep = any(
        _subtree_depth(kid) > lim.nesting - 1 for kid in kids[len(taken):]
    )
    levels = f"{lim.nesting} level" + ("" if lim.nesting == 1 else "s")
    reason = (
        f"its content nests deeper than the {levels} one request allows "
        f"(a column's own children may not have children)"
        if too_deep else
        "its content exceeds the per-request element, children or byte budget"
    )
    raise LimitError(
        f"{kind} at {where} cannot be sent in one request: {reason}. "
        f"A {kind} must be created with all of its children, so it cannot be "
        f"split across requests"
    )


def plan(blocks: list[dict], lim: Limits) -> list[Request]:
    requests: list[Request] = []
    # (parent_ref, blocks, source_path, base) waves still to emit.
    waves: list[tuple] = [(None, document.deep_copy(blocks), (), 0)]

    while waves:
        parent, children, path, base = waves.pop(0)
        deferred = _pack(parent, children, lim, path, requests, base)
        # Depth-first: waves just queued go to the front, in order, so a
        # block's children are emitted before its parent's later siblings.
        waves[0:0] = deferred

    return requests


def _pack(parent, blocks, lim, path, requests, base=0) -> list[tuple]:
    """Emit requests appending `blocks` to `parent`; return deferred waves."""
    deferred_waves: list[tuple] = []
    current: list[dict] = []
    current_paths: list[tuple[int, ...]] = []
    deferrals: list[tuple[int, list[dict], tuple[int, ...], int]] = []

    def flush():
        index = len(requests)
        requests.append(Request(parent, list(current), list(current_paths)))
        for position, kids, kid_path, inlined in deferrals:
            deferred_waves.append((Ref(index, position), kids, kid_path, inlined))
        deferrals.clear()

    for offset, block in enumerate(blocks):
        block_path = path + (base + offset,)
        payload, deferred, inlined = _prepare(block, lim, block_path)

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
