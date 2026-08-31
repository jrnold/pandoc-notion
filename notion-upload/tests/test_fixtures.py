"""Run the whole pipeline over block JSON generated from the Lua corpus.

Pandoc produced these files at `make fixtures` time; it is not invoked here.
"""

from pathlib import Path

import fake_notion
import pytest

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
