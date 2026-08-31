"""Argument parsing, the five pre-flight phases, and exit codes.

Stream discipline: the created page URL is the only thing that goes to
stdout. Warnings, progress and errors all go to stderr, so the tool composes
in a pipeline.
"""

import argparse
import os
import re
import sys
import urllib.parse
from pathlib import Path

from . import document, limits, media, planner
from .client import NotionClient
from .errors import APIError, InputError, NotionUploadError, PartialUploadError

UUID_RE = re.compile(r"([0-9a-fA-F]{32})|([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})")


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="notion-upload",
        description="Create a Notion page from Notion block JSON.",
        epilog="Reads stdin when INPUT is omitted. Pipe it from "
               "`pandoc -t notion-block-writer.lua`.",
    )
    parser.add_argument("input", nargs="?", metavar="INPUT",
                        help="block JSON file (default: stdin)")
    parser.add_argument("--parent", required=True,
                        help="parent page/database/data-source id, or a Notion URL")
    parser.add_argument("--title", help="page title (default: the leading heading_1)")
    parser.add_argument("--base-dir", type=Path,
                        help="resolve relative media paths against this (default: cwd)")
    parser.add_argument("--token", help="Notion token (default: $NOTION_TOKEN)")
    parser.add_argument("--dry-run", action="store_true",
                        help="run pre-flight and print the plan; create nothing")
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("-q", "--quiet", action="store_true")
    return parser.parse_args(argv)


def normalize_parent_id(value: str) -> str:
    # Scan the PATH only. A database URL carries its view id in ?v=... and
    # that sits later in the string, so scanning the whole argument would
    # return the view and address the wrong object. urlsplit leaves a bare
    # id or dashed uuid entirely in `path`, so those still work.
    path = urllib.parse.urlsplit(value).path or value
    match = None
    for match in UUID_RE.finditer(path):
        pass  # the id is the last uuid-shaped run in the path
    if match is None:
        raise InputError(
            f"could not find a Notion id in {value!r}; pass a 32-character id, "
            f"a dashed uuid, or the page URL"
        )
    raw = (match.group(1) or match.group(2)).replace("-", "").lower()
    return f"{raw[:8]}-{raw[8:12]}-{raw[12:16]}-{raw[16:20]}-{raw[20:]}"


def _plain_text(block) -> str:
    return "".join(
        run.get("text", {}).get("content", "")
        for run in document.payload(block).get("rich_text", [])
    )


def extract_title(blocks, explicit):
    if explicit:
        return explicit, blocks
    if (
        blocks
        and document.block_type(blocks[0]) == "heading_1"
        and not document.children_of(blocks[0])
    ):
        # Notion renders the page title as the page's own H1, so leaving this
        # heading in the body would show it twice.
        return _plain_text(blocks[0]), blocks[1:]
    # A leading heading_1 WITH children is a toggle heading: the writer nests
    # the whole section body inside it, so promoting it would discard every
    # block in that section. Fall through and make the user name the title.
    raise InputError(
        "no title: pass --title, or start the document with a heading_1 that "
        "has no children"
    )


def upload(blocks, *, client, parent, title, base_dir, lim, out, err):
    """Create the page, then append every wave through one code path.

    The page is created EMPTY even though POST /v1/pages accepts up to 100
    children, because that response returns the page object and not its
    children's ids - so blocks created that way would be unaddressable, and
    any document deeper than two levels could not be finished. Paying one
    extra request buys a single uniform path in which every id arrives in a
    `results` array. See spec 5.4.
    """
    plan = planner.plan(blocks, lim)
    page = client.create_page(parent, title, [])
    page_id = page["id"]
    page_url = page.get("url") or f"https://notion.so/{page_id.replace('-', '')}"

    created: dict[planner.Ref, str] = {}

    for position, request in enumerate(plan):
        parent_id = page_id if request.parent is None else created[request.parent]
        try:
            results = client.append_children(parent_id, request.blocks)
        except APIError as exc:
            path = request.source_path[0] if request.source_path else (0,)
            raise PartialUploadError(
                page_url=page_url, block_index=path[0], depth=len(path),
                completed=position, total=len(plan),
            ) from exc
        for index, block in enumerate(results):
            created[planner.Ref(position, index)] = block["id"]

    return page_url


def main(argv=None, *, client_factory=None, out=None, err=None):
    out = out if out is not None else sys.stdout
    err = err if err is not None else sys.stderr
    args = parse_args(sys.argv[1:] if argv is None else argv)

    try:
        token = args.token or os.environ.get("NOTION_TOKEN")
        if not token:
            raise InputError("no token: set NOTION_TOKEN or pass --token")

        if args.input:
            try:
                raw = Path(args.input).read_bytes()
            except OSError as exc:
                raise InputError(f"cannot read {args.input}: {exc.strerror}") from exc
        else:
            raw = sys.stdin.buffer.read()
        blocks = document.parse(raw)
        title, blocks = extract_title(blocks, args.title)

        base_dir = args.base_dir or (
            Path(args.input).parent if args.input else Path.cwd()
        )
        factory = client_factory or (lambda t: NotionClient(t))
        client = factory(token)

        # Parent first: it is one cheap request, and discovering the parent is
        # unreachable after uploading 40 MB of images would be infuriating.
        parent = client.retrieve_parent(normalize_parent_id(args.parent))

        # Normalize BEFORE discovering media. normalize() rebuilds every block
        # it touches, so MediaRefs taken beforehand would point at payload
        # dicts that are no longer in the tree, and media.rewrite() would
        # mutate orphans while the real blocks kept their local paths.
        blocks, warnings = limits.normalize(blocks, limits.DEFAULT)
        for warning in warnings:
            if not args.quiet:
                print(f"warning: {warning}", file=err)

        refs = media.discover(blocks)
        resolved = media.resolve(refs, base_dir)

        if args.dry_run:
            plan = planner.plan(blocks, limits.DEFAULT)
            print(
                f"plan: {document.count(blocks)} blocks, "
                f"{len({r.hash for r in resolved})} media uploads, "
                f"{len(plan)} requests",
                file=out,
            )
            for index, request in enumerate(plan):
                target = "POST   /v1/pages" if request.parent is None else (
                    f"PATCH  <request {request.parent.request}"
                    f"#{request.parent.index}>/children"
                )
                print(
                    f"  {target:<40} {len(request.blocks):>4} blocks "
                    f"{limits.serialized_size(request.blocks) // 1024:>5} KB",
                    file=out,
                )
            return 0

        ids = media.upload_all(resolved, client)
        media.rewrite(resolved, ids)

        url = upload(
            blocks, client=client, parent=parent, title=title,
            base_dir=base_dir, lim=limits.DEFAULT, out=out, err=err,
        )
        print(url, file=out)
        return 0

    except PartialUploadError as exc:
        print(f"error: {exc}", file=err)
        print(exc.page_url, file=out)
        return exc.exit_code
    except NotionUploadError as exc:
        print(f"error: {exc}", file=err)
        return exc.exit_code


def run():
    sys.exit(main())
