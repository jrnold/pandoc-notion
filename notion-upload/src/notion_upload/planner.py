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
        return document.without_children(block), []

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
        return document.without_children(block), deferred
    return document.with_children(block, taken), deferred


def plan(blocks: list[dict], lim: Limits) -> list[Request]:
    requests: list[Request] = []
    # (parent_ref, blocks, source_path) waves still to emit.
    waves: list[tuple] = [(None, document.deep_copy(blocks), ())]

    while waves:
        parent, children, path = waves.pop(0)
        deferred = _pack(parent, children, lim, path, requests)
        # Depth-first: waves just queued go to the front, in order, so a
        # block's children are emitted before its parent's later siblings.
        waves[0:0] = deferred

    return requests


def _pack(parent, blocks, lim, path, requests) -> list[tuple]:
    """Emit requests appending `blocks` to `parent`; return deferred waves."""
    deferred_waves: list[tuple] = []
    current: list[dict] = []
    current_paths: list[tuple[int, ...]] = []
    deferrals: list[tuple[int, list[dict], tuple[int, ...]]] = []

    def flush():
        index = len(requests)
        requests.append(Request(parent, list(current), list(current_paths)))
        for position, kids, kid_path in deferrals:
            deferred_waves.append((Ref(index, position), kids, kid_path))
        deferrals.clear()

    for offset, block in enumerate(blocks):
        payload, deferred = _prepare(block, lim)
        block_path = path + (offset,)

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
            deferrals.append((len(current) - 1, deferred, block_path))

    # Always flush, even when empty: an empty document still creates a page.
    flush()
    return deferred_waves
