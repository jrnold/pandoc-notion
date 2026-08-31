import fake_notion
import pytest
import strategies
from hypothesis import HealthCheck, given, settings

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
