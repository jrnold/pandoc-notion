import base64
import hashlib

import pytest

from notion_upload import errors, media


def image(url, caption="cap"):
    return {
        "object": "block", "type": "image",
        "image": {
            "type": "external", "external": {"url": url},
            "caption": [{"type": "text", "text": {"content": caption}}],
        },
    }


class RecordingClient:
    def __init__(self):
        self.created, self.sent, self.completed = [], [], []
        self._n = 0

    def create_file_upload(self, *, filename, content_type, mode="single_part",
                           number_of_parts=None):
        self._n += 1
        self.created.append((filename, content_type, mode, number_of_parts))
        return {"id": f"fu-{self._n}", "upload_url": "https://upload"}

    def send_file_upload(self, upload_id, data, filename, content_type,
                         part_number=None):
        self.sent.append((upload_id, len(data), part_number))
        return {"id": upload_id, "status": "uploaded"}

    def complete_file_upload(self, upload_id):
        self.completed.append(upload_id)
        return {"id": upload_id, "status": "uploaded"}


def test_http_urls_are_not_local():
    assert not media.is_local("https://example.com/a.png")
    assert not media.is_local("http://example.com/a.png")


def test_relative_and_absolute_paths_and_file_urls_are_local():
    assert media.is_local("media/img.png")
    assert media.is_local("/abs/img.png")
    assert media.is_local("file:///abs/img.png")


def test_data_uris_are_local_because_we_must_upload_the_bytes():
    assert media.is_local("data:image/png;base64,iVBOR")


def test_discover_finds_media_across_every_block_type():
    blocks = [image("a.png"), {"object": "block", "type": "pdf",
                               "pdf": {"type": "external",
                                       "external": {"url": "b.pdf"}}}]
    assert {r.url for r in media.discover(blocks)} == {"a.png", "b.pdf"}


def test_discover_skips_remote_urls():
    assert media.discover([image("https://example.com/a.png")]) == []


def test_resolve_reports_every_missing_file_at_once(tmp_path):
    refs = media.discover([image("one.png"), image("two.png")])
    with pytest.raises(errors.MediaError) as exc:
        media.resolve(refs, tmp_path)
    message = str(exc.value)
    assert "one.png" in message and "two.png" in message
    assert "--extract-media" in message, "the remedy must be named"


def test_resolve_reads_bytes_relative_to_base_dir(tmp_path):
    (tmp_path / "media").mkdir()
    (tmp_path / "media" / "img.png").write_bytes(b"\x89PNG-data")
    refs = media.discover([image("media/img.png")])
    resolved = media.resolve(refs, tmp_path)
    assert list(resolved.values()) == [b"\x89PNG-data"]


def test_resolve_decodes_data_uris(tmp_path):
    payload = base64.b64encode(b"bytes!").decode()
    refs = media.discover([image(f"data:image/png;base64,{payload}")])
    assert list(media.resolve(refs, tmp_path).values()) == [b"bytes!"]


def test_the_same_image_used_twice_uploads_once(tmp_path):
    (tmp_path / "a.png").write_bytes(b"same")
    (tmp_path / "b.png").write_bytes(b"same")
    refs = media.discover([image("a.png"), image("b.png")])
    resolved = media.resolve(refs, tmp_path)
    client = RecordingClient()
    ids = media.upload_all(resolved, client)
    assert len(client.created) == 1, "identical bytes must upload once"
    assert len(ids) == 1


def test_rewrite_replaces_external_with_file_upload_and_keeps_the_caption(tmp_path):
    (tmp_path / "a.png").write_bytes(b"png")
    blocks = [image("a.png", caption="a caption")]
    refs = media.discover(blocks)
    resolved = media.resolve(refs, tmp_path)
    ids = media.upload_all(resolved, RecordingClient())
    media.rewrite(resolved, ids)
    node = blocks[0]["image"]
    assert node["type"] == "file_upload"
    assert node["file_upload"]["id"].startswith("fu-")
    assert "external" not in node
    assert node["caption"][0]["text"]["content"] == "a caption"


def test_a_large_file_uses_multipart_and_completes(tmp_path, monkeypatch):
    monkeypatch.setattr(media, "MULTIPART_THRESHOLD_BYTES", 10)
    monkeypatch.setattr(media, "PART_SIZE_BYTES", 10)
    (tmp_path / "big.bin").write_bytes(b"x" * 25)
    refs = media.discover([image("big.bin")])
    resolved = media.resolve(refs, tmp_path)
    client = RecordingClient()
    media.upload_all(resolved, client)
    assert client.created[0][2] == "multi_part"
    assert client.created[0][3] == 3, "25 bytes in 10-byte parts is 3 parts"
    assert [p for _, _, p in client.sent] == [1, 2, 3]
    assert client.completed == ["fu-1"]


def test_content_type_is_inferred_from_the_extension(tmp_path):
    (tmp_path / "a.png").write_bytes(b"png")
    refs = media.discover([image("a.png")])
    client = RecordingClient()
    media.upload_all(media.resolve(refs, tmp_path), client)
    assert client.created[0][1] == "image/png"


def test_an_unknown_extension_falls_back_to_octet_stream(tmp_path):
    (tmp_path / "a.weird").write_bytes(b"?")
    refs = media.discover([image("a.weird")])
    client = RecordingClient()
    media.upload_all(media.resolve(refs, tmp_path), client)
    assert client.created[0][1] == "application/octet-stream"
