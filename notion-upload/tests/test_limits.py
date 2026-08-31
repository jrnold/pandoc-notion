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


def test_normalize_output_shares_no_mutable_state_with_its_input():
    """The output must be safe to mutate. Callers rewrite media file
    objects in the returned blocks; if those aliased the input, the
    caller's tree would be corrupted behind its back."""
    src = [block("paragraph", [rt("short")])]
    out, _ = limits.normalize(src, limits.DEFAULT)
    assert runs_of(out[0])[0] is not runs_of(src[0])[0]
    assert document.payload(out[0]) is not document.payload(src[0])
    # Mutating the result must leave the input untouched.
    runs_of(out[0])[0]["text"]["content"] = "CHANGED"
    assert runs_of(src[0])[0]["text"]["content"] == "short"


# -- rich text outside `rich_text` -------------------------------------------

def table_row(*cells):
    return {"object": "block", "type": "table_row",
            "table_row": {"cells": [list(cell) for cell in cells]}}


def image(caption):
    return {"object": "block", "type": "image",
            "image": {"type": "external", "external": {"url": "https://e.com/a.png"},
                      "caption": caption}}


def cells_of(b):
    return document.payload(b)["cells"]


def test_normalize_splits_text_inside_a_table_cell():
    """`table_row.cells` is a list of lists of rich_text. Reading only
    `payload['rich_text']` left a 5000-character cell to sail past the
    2000-character cap untouched."""
    out, _ = limits.normalize([table_row([rt("x" * 5000)])], limits.DEFAULT)
    lengths = [len(e["text"]["content"]) for e in cells_of(out[0])[0]]
    assert lengths == [2000, 2000, 1000]


def test_normalize_merges_runs_inside_a_table_cell():
    out, _ = limits.normalize([table_row([rt("Hello"), rt(" "), rt("world")])],
                              limits.DEFAULT)
    cell = cells_of(out[0])[0]
    assert len(cell) == 1
    assert cell[0]["text"]["content"] == "Hello world"


def test_normalize_errors_on_a_table_row_too_wide_for_one_request():
    """A row cannot become two rows without changing the table, so a row that
    still exceeds the byte budget is a pre-flight error. Without this,
    normalize returned a 600 KB block and claimed every childless block fit."""
    wide = table_row(*([rt("y" * 1900)] for _ in range(400)))
    assert limits.serialized_size(wide) > limits.DEFAULT.byte_budget
    with pytest.raises(errors.LimitError) as exc:
        limits.normalize([wide], limits.DEFAULT)
    assert "table_row" in str(exc.value)


def test_normalize_errors_on_a_table_cell_with_too_many_runs():
    unmergeable = [rt(f"w{i}", bold=bool(i % 2)) for i in range(150)]
    with pytest.raises(errors.LimitError) as exc:
        limits.normalize([table_row(unmergeable)], limits.DEFAULT)
    assert "cell 0" in str(exc.value)


def test_normalize_splits_text_inside_a_caption():
    out, _ = limits.normalize([image([rt("z" * 5000)])], limits.DEFAULT)
    caption = document.payload(out[0])["caption"]
    assert [len(e["text"]["content"]) for e in caption] == [2000, 2000, 1000]


def test_normalize_errors_on_a_caption_with_too_many_runs():
    unmergeable = [rt(f"w{i}", bold=bool(i % 2)) for i in range(150)]
    with pytest.raises(errors.LimitError) as exc:
        limits.normalize([image(unmergeable)], limits.DEFAULT)
    assert "caption" in str(exc.value)


def test_every_block_normalize_returns_fits_alone_in_a_request():
    """The docstring guarantee 5.2's totality argument cites, asserted over
    every rich-text-bearing field at once.

    The row is pandoc-shaped: fragmented at word boundaries, so it costs
    630 KB as it arrives and 270 KB once its cells are merged. Leaving cells
    alone left the planner an unsendable block and a guarantee that was false.
    """
    fragmented = table_row(*([rt("x" * 100) for _ in range(500)] for _ in range(5)))
    assert limits.serialized_size(fragmented) > limits.DEFAULT.byte_budget
    blocks = [
        fragmented,
        image([rt("z" * 9000)]),
        block("paragraph", [rt("漢" * 2000, bold=bool(i % 2)) for i in range(100)]),
    ]
    out, _ = limits.normalize(blocks, limits.DEFAULT)
    assert len(out) > len(blocks), "the paragraph must have been split"
    for b in out:
        assert limits.serialized_size(b) <= limits.DEFAULT.byte_budget


def test_normalize_errors_on_an_over_long_url():
    b = {"object": "block", "type": "image",
         "image": {"type": "external", "external": {"url": "https://e.com/" + "a" * 2100}}}
    with pytest.raises(errors.LimitError) as exc:
        limits.normalize([b], limits.DEFAULT)
    assert "url" in str(exc.value).lower()
