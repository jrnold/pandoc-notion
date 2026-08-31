"""Hypothesis strategies for block trees.

Text includes multibyte characters on purpose: the character bound and the
byte bound disagree by 3x on CJK, and that disagreement is exactly what the
planner has to survive.
"""

from hypothesis import strategies as st

TEXT = st.text(alphabet="ab 漢字", min_size=0, max_size=40)

BLOCK_TYPES = st.sampled_from(
    ["paragraph", "bulleted_list_item", "numbered_list_item", "toggle", "quote"]
)


def _block(kind, text, children):
    payload = {"rich_text": [{"type": "text", "text": {"content": text},
                              "annotations": {"bold": False, "code": False,
                                              "color": "default", "italic": False,
                                              "strikethrough": False,
                                              "underline": False}}]}
    if children:
        payload["children"] = children
    return {"object": "block", "type": kind, kind: payload}


def blocks(max_depth=4):
    leaf = st.builds(_block, BLOCK_TYPES, TEXT, st.just([]))
    return st.recursive(
        leaf,
        lambda inner: st.builds(
            _block, BLOCK_TYPES, TEXT, st.lists(inner, min_size=1, max_size=4)
        ),
        max_leaves=max_depth * 4,
    )


def block_trees(min_size=0, max_size=12):
    return st.lists(blocks(), min_size=min_size, max_size=max_size)
