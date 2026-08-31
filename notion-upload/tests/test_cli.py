import io
import json

import pytest

from notion_upload import cli, errors, limits, planner


def para(text, children=None):
    payload = {"rich_text": [{"type": "text", "text": {"content": text}}]}
    if children is not None:
        payload["children"] = children
    return {"object": "block", "type": "paragraph", "paragraph": payload}


def heading(text):
    return {"object": "block", "type": "heading_1",
            "heading_1": {"rich_text": [{"type": "text", "text": {"content": text}}]}}


class StubClient:
    """Enough of NotionClient to drive cli.upload without a network."""

    def __init__(self, fail_on_append=False):
        self.fail_on_append = fail_on_append
        self.appends = []
        self._n = 0

    def retrieve_parent(self, object_id):
        return {"page_id": object_id}

    def create_page(self, parent, title, children):
        self.page = {"parent": parent, "title": title, "children": children}
        return {"id": "page-1", "url": "https://notion.so/page-1"}

    def append_children(self, block_id, children):
        if self.fail_on_append:
            raise errors.APIError("boom")
        self.appends.append((block_id, children))
        self._n += 1
        return [{"id": f"blk-{self._n}-{i}"} for i in range(len(children))]


# -- title ------------------------------------------------------------------

def test_explicit_title_wins_and_the_body_is_untouched():
    blocks = [heading("Doc Heading"), para("body")]
    title, out = cli.extract_title(blocks, "Explicit")
    assert title == "Explicit"
    assert len(out) == 2


def test_a_leading_heading_1_becomes_the_title_and_leaves_the_body():
    blocks = [heading("Quarterly Report"), para("body")]
    title, out = cli.extract_title(blocks, None)
    assert title == "Quarterly Report"
    assert len(out) == 1, "Notion renders the title as the page H1; keeping it duplicates"


def test_a_heading_1_that_is_not_first_is_left_alone():
    blocks = [para("intro"), heading("Section")]
    with pytest.raises(errors.InputError):
        cli.extract_title(blocks, None)


def test_no_title_and_no_leading_heading_is_a_preflight_error():
    with pytest.raises(errors.InputError) as exc:
        cli.extract_title([para("body")], None)
    assert "--title" in str(exc.value)


# -- parent id --------------------------------------------------------------

def test_normalize_parent_accepts_a_bare_id():
    assert cli.normalize_parent_id("24f1b2c3d4e5f6a7b8c9d0e1f2a3b4c5") == (
        "24f1b2c3-d4e5-f6a7-b8c9-d0e1f2a3b4c5"
    )


def test_normalize_parent_accepts_a_dashed_uuid_unchanged():
    dashed = "24f1b2c3-d4e5-f6a7-b8c9-d0e1f2a3b4c5"
    assert cli.normalize_parent_id(dashed) == dashed


def test_normalize_parent_accepts_a_notion_url():
    url = "https://www.notion.so/team/My-Page-24f1b2c3d4e5f6a7b8c9d0e1f2a3b4c5"
    assert cli.normalize_parent_id(url) == "24f1b2c3-d4e5-f6a7-b8c9-d0e1f2a3b4c5"


def test_normalize_parent_rejects_nonsense():
    with pytest.raises(errors.InputError):
        cli.normalize_parent_id("not-an-id")


# -- upload -----------------------------------------------------------------

def test_upload_creates_the_page_empty_and_appends_every_wave():
    client = StubClient()
    out, err = io.StringIO(), io.StringIO()
    url = cli.upload(
        [para("a"), para("b")], client=client, parent={"page_id": "p"},
        title="T", base_dir=None, lim=limits.DEFAULT, out=out, err=err,
    )
    assert url == "https://notion.so/page-1"
    assert client.page["children"] == [], (
        "creation carries no blocks: POST /v1/pages does not return their ids"
    )
    assert len(client.appends) == 1
    assert client.appends[0][0] == "page-1"
    assert len(client.appends[0][1]) == 2


def test_upload_recurses_for_deep_documents_resolving_ids_from_results():
    client = StubClient()
    tree = [para("a", children=[para("b", children=[para("c")])])]
    cli.upload(tree, client=client, parent={"page_id": "p"}, title="T",
               base_dir=None, lim=limits.DEFAULT, out=io.StringIO(),
               err=io.StringIO())
    assert len(client.appends) == 2, "one wave for `a`, one for its children"
    assert client.appends[0][0] == "page-1"
    # The second wave must target the id `a` came back with, not the page.
    assert client.appends[1][0] == "blk-1-0"


def test_a_failure_after_creation_reports_the_url_and_the_block():
    client = StubClient(fail_on_append=True)
    tree = [para("a", children=[para("b", children=[para("c")])])]
    with pytest.raises(errors.PartialUploadError) as exc:
        cli.upload(tree, client=client, parent={"page_id": "p"}, title="T",
                   base_dir=None, lim=limits.DEFAULT, out=io.StringIO(),
                   err=io.StringIO())
    assert exc.value.page_url == "https://notion.so/page-1"
    assert exc.value.exit_code == 6


# -- main -------------------------------------------------------------------

def test_main_writes_only_the_url_to_stdout(tmp_path):
    doc = tmp_path / "doc.json"
    doc.write_text(json.dumps([heading("T"), para("body")]))
    out, err = io.StringIO(), io.StringIO()
    code = cli.main(
        [str(doc), "--parent", "24f1b2c3d4e5f6a7b8c9d0e1f2a3b4c5", "--token", "x"],
        client_factory=lambda token: StubClient(), out=out, err=err,
    )
    assert code == 0
    assert out.getvalue().strip() == "https://notion.so/page-1"


def test_media_is_rewritten_in_the_blocks_that_actually_get_uploaded(tmp_path):
    """Regression: normalize() rebuilds blocks, so media must be discovered
    after it. Discovering first leaves MediaRefs pointing at payload dicts
    that are no longer in the tree, and the uploaded page keeps local paths.
    """
    (tmp_path / "img.png").write_bytes(b"\x89PNG")
    # A paragraph long enough to force normalize() to rebuild, plus an image.
    doc = tmp_path / "doc.json"
    doc.write_text(json.dumps([
        heading("T"),
        {"object": "block", "type": "paragraph",
         "paragraph": {"rich_text": [
             {"type": "text", "text": {"content": "x" * 5000}}]}},
        {"object": "block", "type": "image",
         "image": {"type": "external", "external": {"url": "img.png"},
                   "caption": []}},
    ]))

    class MediaClient(StubClient):
        def create_file_upload(self, *, filename, content_type,
                               mode="single_part", number_of_parts=None):
            return {"id": "fu-1", "upload_url": "https://upload"}

        def send_file_upload(self, upload_id, data, filename, content_type,
                             part_number=None):
            return {"id": upload_id, "status": "uploaded"}

    client = MediaClient()
    code = cli.main(
        [str(doc), "--parent", "24f1b2c3d4e5f6a7b8c9d0e1f2a3b4c5", "--token", "x"],
        client_factory=lambda token: client, out=io.StringIO(), err=io.StringIO(),
    )
    assert code == 0
    sent = [b for _, blocks in client.appends for b in blocks]
    images = [b for b in sent if b["type"] == "image"]
    assert images, "the image block must reach Notion"
    assert images[0]["image"]["type"] == "file_upload", (
        "the uploaded block still points at a local path: media was discovered "
        "before normalize() rebuilt the blocks"
    )


def test_main_maps_an_error_to_its_exit_code(tmp_path):
    doc = tmp_path / "doc.json"
    doc.write_text("{not json")
    out, err = io.StringIO(), io.StringIO()
    code = cli.main(
        [str(doc), "--parent", "24f1b2c3d4e5f6a7b8c9d0e1f2a3b4c5", "--token", "x"],
        client_factory=lambda token: StubClient(), out=out, err=err,
    )
    assert code == errors.InputError.exit_code
    assert out.getvalue() == "", "diagnostics never go to stdout"
    assert "JSON" in err.getvalue()


def test_dry_run_creates_nothing_and_prints_the_plan(tmp_path):
    doc = tmp_path / "doc.json"
    doc.write_text(json.dumps([heading("T"), para("body")]))
    client = StubClient()
    out, err = io.StringIO(), io.StringIO()
    code = cli.main(
        [str(doc), "--parent", "24f1b2c3d4e5f6a7b8c9d0e1f2a3b4c5",
         "--token", "x", "--dry-run"],
        client_factory=lambda token: client, out=out, err=err,
    )
    assert code == 0
    assert not hasattr(client, "page"), "dry-run must not create a page"
    assert "plan:" in out.getvalue()


def test_missing_token_is_a_clear_error(tmp_path, monkeypatch):
    monkeypatch.delenv("NOTION_TOKEN", raising=False)
    doc = tmp_path / "doc.json"
    doc.write_text(json.dumps([heading("T")]))
    out, err = io.StringIO(), io.StringIO()
    code = cli.main(
        [str(doc), "--parent", "24f1b2c3d4e5f6a7b8c9d0e1f2a3b4c5"],
        client_factory=lambda token: StubClient(), out=out, err=err,
    )
    assert code == errors.InputError.exit_code
    assert "NOTION_TOKEN" in err.getvalue()
