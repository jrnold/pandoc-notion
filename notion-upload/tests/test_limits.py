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
