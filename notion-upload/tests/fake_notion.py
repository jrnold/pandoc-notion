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
        self._ids = (f"blk-{n}" for n in itertools.count())
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
        if not children:
            # Real Notion: "body.children.length should be >= 1".
            self._reject("append with an empty children array")
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
        if not request.blocks:
            continue  # cli.upload skips these too; the fake rejects them
        parent_id = "page" if request.parent is None else created[request.parent]
        results = fake.append(parent_id, request.blocks)
        for index, block in enumerate(results):
            created[planner.Ref(position, index)] = block["id"]
