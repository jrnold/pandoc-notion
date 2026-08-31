from pathlib import Path

import fake_notion
import pytest

from notion_upload import document, errors, limits, planner

FIXTURES = Path(__file__).parent / "fixtures"


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


def test_a_block_with_grandchildren_inlines_both_levels():
    # nesting=2: a block may carry children AND grandchildren in one request.
    tree = [para("a", children=[para("b", children=[para("c")])])]
    plan = planner.plan(tree, limits.DEFAULT)
    assert len(plan) == 1, "two levels of children ride along with `a`"
    b = document.children_of(plan[0].blocks[0])[0]
    assert text_of(b) == "b"
    assert [text_of(k) for k in document.children_of(b)] == ["c"]


def test_a_child_too_deep_to_inline_whole_is_deferred_with_its_subtree():
    # a > b > c > d is one level past what a request can carry, so `b` (and
    # everything below it) becomes a wave of its own. `b` is top-level there,
    # so its id arrives in a results array exactly as before.
    tree = [para("a", children=[para("b", children=[para("c", children=[para("d")])])])]
    plan = planner.plan(tree, limits.DEFAULT)
    assert len(plan) == 2
    assert document.children_of(plan[0].blocks[0]) == [], "a must go childless"
    assert plan[1].parent == planner.Ref(request=0, index=0)
    assert text_of(plan[1].blocks[0]) == "b"
    c = document.children_of(plan[1].blocks[0])[0]
    assert [text_of(k) for k in document.children_of(c)] == ["d"]


def test_the_worked_example_from_the_spec_costs_one_request():
    # A > B1..B50, each Bi holding one leaf Ci. Spec 5.1 works this example at
    # two requests under the one-level rule; inlining two levels sends it in
    # one. The naive strip-everything planner costs 52.
    bs = [para(f"b{i}", children=[para(f"c{i}")]) for i in range(50)]
    plan = planner.plan([para("a", children=bs)], limits.DEFAULT)
    assert len(plan) == 1
    assert plan[0].parent is None
    assert len(document.children_of(plan[0].blocks[0])) == 50


# -- column_list ------------------------------------------------------------

def column(*kids):
    return {"object": "block", "type": "column", "column": {"children": list(kids)}}


def column_list(*columns):
    return {"object": "block", "type": "column_list",
            "column_list": {"children": list(columns)}}


def test_a_column_list_is_sent_with_its_columns_and_their_content():
    """fixtures/columns.json - a real corpus document. Notion creates a
    column_list only with at least two columns, each holding at least one
    block; every column has children by construction, so a planner that stops
    inlining at the first child with children of its own sends the column_list
    empty and Notion rejects the request."""
    blocks = document.parse((FIXTURES / "columns.json").read_bytes())
    normalized, _ = limits.normalize(blocks, limits.DEFAULT)
    plan = planner.plan(normalized, limits.DEFAULT)

    assert len(plan) == 1, "a column_list must be created whole, in one request"
    sent = plan[0].blocks[0]
    assert document.block_type(sent) == "column_list"
    columns = document.children_of(sent)
    assert len(columns) == 2
    assert all(document.children_of(col) for col in columns), (
        "a column with no children is rejected by Notion"
    )


def test_the_column_fixture_round_trips_through_the_strict_fake():
    blocks = document.parse((FIXTURES / "columns.json").read_bytes())
    normalized, _ = limits.normalize(blocks, limits.DEFAULT)
    fake = fake_notion.FakeNotion(limits.DEFAULT)
    fake_notion.execute(planner.plan(normalized, limits.DEFAULT), fake)
    assert fake.tree() == normalized


def test_a_column_list_too_deep_to_send_whole_is_a_preflight_error():
    """A column whose own child has children needs three levels of nesting.
    There is no legal way to split that: the column_list cannot be sent
    childless, and inlining a prefix of a column's children would need the
    column's id, which never arrives. Say so before creating the page."""
    tree = [column_list(
        column(para("left", children=[para("deeper")])),
        column(para("right")),
    )]
    with pytest.raises(errors.LimitError) as exc:
        planner.plan(tree, limits.DEFAULT)
    assert "column_list" in str(exc.value)
    assert "block 0" in str(exc.value)


def test_a_column_list_too_large_to_send_whole_is_a_preflight_error():
    tree = [column_list(column(para("left")), column(para("right")))]
    with pytest.raises(errors.LimitError) as exc:
        planner.plan(tree, limits.Limits(elements=3))
    assert "column_list" in str(exc.value)


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


def test_inlining_stops_at_the_first_child_that_cannot_come_whole():
    deep = para("c", children=[para("g", children=[para("h")])])
    kids = [para("a"), para("b"), deep, para("d")]
    tree = [para("p", children=kids)]
    plan = planner.plan(tree, limits.DEFAULT)
    inlined = [text_of(k) for k in document.children_of(plan[0].blocks[0])]
    assert inlined == ["a", "b"], "c needs its own id, so c and everything after defers"
    assert [text_of(b) for b in plan[1].blocks] == ["c", "d"]


def test_a_child_is_never_inlined_with_only_a_prefix_of_its_own_children():
    """Taking some of c's children and deferring the rest would need c's id to
    append the remainder - and c is not top-level in any request, so no id ever
    arrives for it. c must come whole or not at all."""
    lim = limits.Limits(elements=4)
    c = para("c", children=[para("g1"), para("g2"), para("g3")])
    plan = planner.plan([para("p", children=[c])], lim)
    assert document.children_of(plan[0].blocks[0]) == [], "p goes childless"
    assert text_of(plan[1].blocks[0]) == "c"
    assert len(document.children_of(plan[1].blocks[0])) == 3, "c keeps all three"


def test_a_leading_child_that_cannot_come_whole_means_nothing_is_inlined():
    deep = para("c", children=[para("g", children=[para("h")])])
    tree = [para("p", children=[deep, para("d")])]
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
        para("a", children=[para("a1", children=[para("a2", children=[para("a3")])])]),
        para("b"),
    ]
    plan = planner.plan(tree, limits.DEFAULT)
    first = [text_of(b) for b in plan[0].blocks]
    assert first == ["a", "b"], "siblings pack together before descending"
    assert text_of(plan[1].blocks[0]) == "a1"


def test_a_parents_request_always_precedes_the_request_it_parents():
    tree = [
        para(f"p{i}", children=[para("k", children=[para("g", children=[para("h")])])])
        for i in range(5)
    ]
    plan = planner.plan(tree, limits.DEFAULT)
    assert any(r.parent is not None for r in plan), "the tree must need follow-ups"
    for position, request in enumerate(plan):
        if request.parent is not None:
            assert request.parent.request < position


def test_plan_does_not_mutate_its_input():
    tree = [para("a", children=[para("b", children=[para("c")])])]
    before = document.deep_copy(tree)
    planner.plan(tree, limits.DEFAULT)
    assert tree == before


def test_an_empty_document_plans_a_request_that_must_not_be_sent():
    """The planner still emits the page-level wave for an empty document -
    packing an empty list yields an empty request - but `children: []` is
    rejected by Notion, so the executor drops any blockless request. See
    test_cli.test_an_empty_body_creates_the_page_and_appends_nothing."""
    plan = planner.plan([], limits.DEFAULT)
    assert len(plan) == 1
    assert plan[0].blocks == []
    assert plan[0].parent is None


def test_source_path_resolves_to_the_right_block_after_partial_inlining():
    """A deferred wave starts partway through its parent's children, so
    its paths must carry that offset. Without it they resolve to the
    blocks that were inlined instead."""
    deep = para("c", children=[para("g", children=[para("h")])])
    tree = [para("p", children=[para("a"), para("b"), deep, para("d")])]
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
