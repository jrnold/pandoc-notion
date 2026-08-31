"""Find local media in a block tree, upload it, and point the tree at it.

Everything here runs in pre-flight, before any page exists, so a missing file
costs the user nothing but a re-run.
"""

import base64
import hashlib
import mimetypes
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

from . import document
from .errors import MediaError
from .limits import MULTIPART_THRESHOLD_BYTES

PART_SIZE_BYTES = 10 * 1024 * 1024

MEDIA_TYPES = {"image", "video", "audio", "pdf", "file"}


@dataclass(eq=False)
class MediaRef:
    """A file object in the tree, mutated in place when rewritten."""

    node: dict
    url: str
    hash: str = field(default="", compare=False)


def is_local(url: str) -> bool:
    if url.startswith("data:"):
        return True
    scheme = urllib.parse.urlparse(url).scheme
    return scheme in ("", "file")


def discover(blocks: list[dict]) -> list[MediaRef]:
    refs = []
    for block in document.walk(blocks):
        if document.block_type(block) not in MEDIA_TYPES:
            continue
        node = document.payload(block)
        if node.get("type") != "external":
            continue
        url = (node.get("external") or {}).get("url") or ""
        if url and is_local(url):
            refs.append(MediaRef(node=node, url=url))
    return refs


def _read(ref: MediaRef, base_dir: Path) -> bytes:
    if ref.url.startswith("data:"):
        header, _, encoded = ref.url.partition(",")
        if ";base64" in header:
            return base64.b64decode(encoded)
        return urllib.parse.unquote_to_bytes(encoded)

    path = ref.url
    if path.startswith("file:"):
        path = urllib.request.url2pathname(urllib.parse.urlparse(path).path)
    resolved = Path(path)
    if not resolved.is_absolute():
        resolved = base_dir / resolved
    return resolved.read_bytes()


def resolve(refs: list[MediaRef], base_dir: Path) -> dict:
    """Read every referenced file. Reports all failures together, not the
    first one, because fixing them one re-run at a time is miserable."""
    resolved, missing = {}, []
    for ref in refs:
        try:
            data = _read(ref, base_dir)
        except (OSError, ValueError):
            missing.append(ref.url)
            continue
        ref.hash = hashlib.sha256(data).hexdigest()
        resolved[ref] = data

    if missing:
        listed = ", ".join(sorted(set(missing)))
        raise MediaError(
            f"{len(missing)} media reference(s) could not be resolved "
            f"relative to {base_dir}\n  {listed}\n"
            f"  If the source was docx/odt/epub, re-run pandoc with "
            f"--extract-media=media"
        )
    return resolved


def _filename(ref: MediaRef) -> str:
    if ref.url.startswith("data:"):
        header = ref.url[5:].split(";", 1)[0] or "application/octet-stream"
        suffix = mimetypes.guess_extension(header) or ".bin"
        return f"{ref.hash[:12]}{suffix}"
    return Path(urllib.parse.urlparse(ref.url).path or ref.url).name or "file.bin"


def _content_type(filename: str) -> str:
    return mimetypes.guess_type(filename)[0] or "application/octet-stream"


def upload_all(resolved: dict, client) -> dict[str, str]:
    """Upload each distinct blob once. Returns content hash -> file_upload id."""
    ids: dict[str, str] = {}
    for ref, data in resolved.items():
        if ref.hash in ids:
            continue
        filename = _filename(ref)
        content_type = _content_type(filename)

        if len(data) > MULTIPART_THRESHOLD_BYTES:
            parts = [
                data[i:i + PART_SIZE_BYTES]
                for i in range(0, len(data), PART_SIZE_BYTES)
            ]
            upload = client.create_file_upload(
                filename=filename, content_type=content_type,
                mode="multi_part", number_of_parts=len(parts),
            )
            for number, part in enumerate(parts, start=1):
                client.send_file_upload(
                    upload["id"], part, filename, content_type, part_number=number
                )
            client.complete_file_upload(upload["id"])
        else:
            upload = client.create_file_upload(
                filename=filename, content_type=content_type
            )
            client.send_file_upload(upload["id"], data, filename, content_type)

        ids[ref.hash] = upload["id"]
    return ids


def rewrite(resolved: dict, ids_by_hash: dict[str, str]) -> None:
    """Point every resolved node at its uploaded file, in place.

    Sibling keys - caption above all - are preserved; only the file object
    discriminator and its payload change.
    """
    for ref in resolved:
        node = ref.node
        node.pop("external", None)
        node["type"] = "file_upload"
        node["file_upload"] = {"id": ids_by_hash[ref.hash]}
