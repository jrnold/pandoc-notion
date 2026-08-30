"""Notion's documented limits, and the transformations that respect them.

Every value here is quoted from Notion's API documentation; see spec 2.3.
They live in a frozen dataclass rather than as bare module constants so that
tests can vary them - a planner bug is far easier to reproduce at
`Limits(children=3)` than at `Limits(children=100)`.
"""

from dataclasses import dataclass

NOTION_VERSION = "2026-03-11"

# Files above this size must use the multi-part upload mode.
MULTIPART_THRESHOLD_BYTES = 20 * 1024 * 1024


@dataclass(frozen=True)
class Limits:
    # Per request.
    children: int = 100          # top-level entries in a children array
    elements: int = 1000         # total blocks, counting inlined children
    byte_budget: int = 500_000   # serialized payload
    nesting: int = 2             # levels of nesting

    # Per block.
    rich_text: int = 100         # elements in one rich_text array
    text_chars: int = 2000       # characters in one text.content
    equation_chars: int = 1000   # characters in one equation.expression
    url_chars: int = 2000        # characters in any URL


DEFAULT = Limits()
