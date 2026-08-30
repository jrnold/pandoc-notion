"""Exception hierarchy. Each class owns the process exit code it maps to,
so cli.py needs no translation table."""


class NotionUploadError(Exception):
    """Base for every failure this tool reports deliberately."""

    exit_code = 1


class InputError(NotionUploadError):
    """The input is not block JSON we can work with."""

    exit_code = 2


class MediaError(NotionUploadError):
    """Local media could not be resolved or uploaded."""

    exit_code = 3


class LimitError(NotionUploadError):
    """Content exceeds a limit that cannot be fixed by splitting."""

    exit_code = 4


class APIError(NotionUploadError):
    """Notion rejected a request, or was unreachable."""

    exit_code = 5


class PartialUploadError(NotionUploadError):
    """The page was created but not completely filled.

    This is the one error that reports something the user can still use, so
    it carries the page URL and the exact block that failed.
    """

    exit_code = 6

    def __init__(self, *, page_url, block_index, depth, completed, total):
        self.page_url = page_url
        self.block_index = block_index
        self.depth = depth
        self.completed = completed
        self.total = total
        super().__init__(
            f"page created but incomplete\n"
            f"  {page_url}\n"
            f"  failed appending children of block #{block_index} (depth {depth})\n"
            f"  {completed} of {total} requests succeeded"
        )
