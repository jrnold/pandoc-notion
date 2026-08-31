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


def test_source_path_resolves_to_the_right_block_after_partial_inlining():
    """A deferred wave starts partway through its parent's children, so
    its paths must carry that offset. Without it they resolve to the
    blocks that were inlined instead."""
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
