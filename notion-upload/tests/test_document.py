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
