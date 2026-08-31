import dataclasses

import pytest

from notion_upload import errors, limits


def test_every_error_has_a_distinct_exit_code():
    classes = [
        errors.InputError,
        errors.MediaError,
        errors.LimitError,
        errors.APIError,
        errors.PartialUploadError,
    ]
    codes = [c.exit_code for c in classes]
    assert len(set(codes)) == len(codes), f"exit codes collide: {codes}"
    assert all(c > 0 for c in codes), "success is 0; every error must be non-zero"


def test_all_errors_share_one_base():
    assert issubclass(errors.InputError, errors.NotionUploadError)
    assert issubclass(errors.PartialUploadError, errors.NotionUploadError)


def test_partial_upload_error_carries_what_the_user_needs():
    err = errors.PartialUploadError(
        page_url="https://notion.so/abc123",
        block_index=204,
        depth=3,
        completed=12,
        total=18,
    )
    assert err.page_url == "https://notion.so/abc123"
    assert "204" in str(err)
    assert "https://notion.so/abc123" in str(err)
    assert "12 of 18" in str(err)


def test_limits_carry_the_documented_values():
    d = limits.DEFAULT
    assert (d.children, d.elements, d.byte_budget, d.nesting) == (100, 1000, 500_000, 2)
    assert (d.rich_text, d.text_chars) == (100, 2000)
    assert (d.equation_chars, d.url_chars) == (1000, 2000)
    assert limits.MULTIPART_THRESHOLD_BYTES == 20 * 1024 * 1024


def test_limits_are_frozen_so_nothing_mutates_them_at_a_distance():
    with pytest.raises(dataclasses.FrozenInstanceError):
        limits.DEFAULT.children = 5
