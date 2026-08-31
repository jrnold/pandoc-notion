"""Parsing and accessors for Notion block JSON.

The one thing worth knowing before reading this file: `notion-block-writer.lua`
nests `children` *inside the type payload*, not at the top level of the block:

    {"type": "bulleted_list_item",
     "bulleted_list_item": {"rich_text": [...], "children": [...]}}

That is the shape the append endpoints accept, so every accessor here looks
there and nowhere else.
"""

import copy
import json
from collections.abc import Iterator

from .errors import InputError

ACCEPTED = (
    "expected a bare array of blocks, a list response "
    '({"object":"list","results":[...]}), or a page object '
    '({"object":"page","children":[...]})'
)


def parse(raw: str | bytes) -> list[dict]:
    try:
        value = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise InputError(f"input is not valid JSON: {exc}") from exc

    blocks = _unwrap(value)
    for block in walk(blocks):
        # Ids are server-owned. The writer emits them only under -V preserve-ids,
        # and sending one back is rejected, so they go no further than here.
        block.pop("id", None)
    return blocks


def _unwrap(value: object) -> list[dict]:
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        obj = value.get("object")
        if obj == "list":
            return list(value.get("results") or [])
        if obj == "page":
            return list(value.get("children") or value.get("results") or [])
    raise InputError(ACCEPTED)


def block_type(block: dict) -> str:
    kind = block.get("type")
    if not isinstance(kind, str):
        raise InputError(f"block has no string 'type': {block!r:.120}")
    return kind


def payload(block: dict) -> dict:
    body = block.get(block_type(block))
    if not isinstance(body, dict):
        raise InputError(
            f"block of type {block_type(block)!r} has no matching payload object"
        )
    return body


def children_of(block: dict) -> list[dict]:
    return payload(block).get("children") or []


def without_children(block: dict) -> dict:
    out = dict(block)
    body = dict(payload(block))
    body.pop("children", None)
    out[block_type(block)] = body
    return out


def with_children(block: dict, kids: list[dict]) -> dict:
    out = dict(block)
    body = dict(payload(block))
    body["children"] = kids
    out[block_type(block)] = body
    return out


def walk(blocks: list[dict]) -> Iterator[dict]:
    for block in blocks:
        yield block
        yield from walk(children_of(block))


def count(blocks: list[dict]) -> int:
    return sum(1 for _ in walk(blocks))


def deep_copy(blocks: list[dict]) -> list[dict]:
    return copy.deepcopy(blocks)
