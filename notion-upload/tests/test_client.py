import json

import httpx
import pytest

from notion_upload import client, errors, limits


def transport(handler):
    return httpx.MockTransport(handler)


def make(handler, **kw):
    slept = []
    c = client.NotionClient(
        "secret_token",
        transport=transport(handler),
        sleep=slept.append,
        **kw,
    )
    return c, slept


def test_every_request_carries_auth_and_the_pinned_version():
    seen = {}

    def handler(request):
        seen.update(request.headers)
        return httpx.Response(200, json={"id": "page-1"})

    c, _ = make(handler)
    c.create_page({"page_id": "p"}, "T", [])
    assert seen["authorization"] == "Bearer secret_token"
    assert seen["notion-version"] == limits.NOTION_VERSION


def test_create_page_sends_title_as_the_only_property():
    captured = {}

    def handler(request):
        captured.update(json.loads(request.content))
        return httpx.Response(200, json={"id": "page-1", "url": "https://notion.so/p"})

    c, _ = make(handler)
    c.create_page({"page_id": "parent"}, "My Title", [])
    assert captured["parent"] == {"page_id": "parent"}
    assert list(captured["properties"]) == ["title"]
    title = captured["properties"]["title"]["title"][0]["text"]["content"]
    assert title == "My Title"


def test_append_children_returns_the_results_array():
    def handler(request):
        return httpx.Response(200, json={"results": [{"id": "b1"}, {"id": "b2"}]})

    c, _ = make(handler)
    assert [b["id"] for b in c.append_children("blk", [])] == ["b1", "b2"]


def test_429_is_retried_after_the_retry_after_header():
    calls = []

    def handler(request):
        calls.append(1)
        if len(calls) == 1:
            return httpx.Response(429, headers={"Retry-After": "7"}, json={})
        return httpx.Response(200, json={"results": []})

    c, slept = make(handler)
    c.append_children("blk", [])
    assert len(calls) == 2
    assert 7 in slept, f"must honour Retry-After, slept {slept}"


def test_529_is_retried_with_backoff():
    calls = []

    def handler(request):
        calls.append(1)
        if len(calls) < 3:
            return httpx.Response(529, json={"code": "service_overload"})
        return httpx.Response(200, json={"results": []})

    c, slept = make(handler)
    c.append_children("blk", [])
    assert len(calls) == 3
    assert len(slept) >= 2


def test_a_400_is_not_retried_and_reports_notions_message():
    calls = []

    def handler(request):
        calls.append(1)
        return httpx.Response(400, json={"code": "validation_error",
                                         "message": "body.children is too long"})

    c, _ = make(handler)
    with pytest.raises(errors.APIError) as exc:
        c.append_children("blk", [])
    assert len(calls) == 1, "a 4xx is the caller's fault; retrying is pointless"
    assert "body.children is too long" in str(exc.value)


def test_retries_are_bounded():
    def handler(request):
        return httpx.Response(529, json={})

    c, _ = make(handler, max_retries=3)
    with pytest.raises(errors.APIError):
        c.append_children("blk", [])


def test_retrieve_parent_probes_page_then_data_source_then_database():
    seen = []

    def handler(request):
        seen.append(request.url.path)
        if "data_sources" in request.url.path:
            return httpx.Response(200, json={"id": "ds"})
        return httpx.Response(404, json={"code": "object_not_found"})

    c, _ = make(handler)
    assert c.retrieve_parent("abc") == {"data_source_id": "abc"}
    assert seen[0].startswith("/v1/pages/")


def test_retrieve_parent_raises_when_nothing_matches():
    def handler(request):
        return httpx.Response(404, json={"code": "object_not_found"})

    c, _ = make(handler)
    with pytest.raises(errors.APIError) as exc:
        c.retrieve_parent("abc")
    assert "abc" in str(exc.value)


def test_file_upload_send_posts_multipart_with_a_file_field():
    captured = {}

    def handler(request):
        captured["content_type"] = request.headers.get("content-type", "")
        captured["body"] = request.content
        return httpx.Response(200, json={"id": "fu-1", "status": "uploaded"})

    c, _ = make(handler)
    c.send_file_upload("fu-1", b"\x89PNG", "a.png", "image/png")
    assert captured["content_type"].startswith("multipart/form-data")
    assert b'name="file"' in captured["body"]
