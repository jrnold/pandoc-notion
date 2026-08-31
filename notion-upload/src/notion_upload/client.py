"""The Notion HTTP surface this tool needs, and nothing else.

`transport` and `sleep` are injected so the whole class is testable with
httpx.MockTransport and without ever actually waiting for a Retry-After.
"""

import random
import time

import httpx

from .errors import APIError
from .limits import NOTION_VERSION

RETRYABLE_STATUS = {429, 500, 502, 503, 504, 529}


class NotionClient:
    def __init__(
        self,
        token: str,
        *,
        transport=None,
        base_url: str = "https://api.notion.com",
        sleep=time.sleep,
        rate: float = 3.0,
        max_retries: int = 5,
    ):
        self._sleep = sleep
        self._max_retries = max_retries
        self._min_interval = 1.0 / rate if rate else 0.0
        self._last_call = 0.0
        self._http = httpx.Client(
            base_url=base_url,
            transport=transport,
            timeout=60.0,
            headers={
                "Authorization": f"Bearer {token}",
                "Notion-Version": NOTION_VERSION,
            },
        )

    # -- plumbing -----------------------------------------------------------

    def _throttle(self):
        if not self._min_interval:
            return
        elapsed = time.monotonic() - self._last_call
        if elapsed < self._min_interval:
            self._sleep(self._min_interval - elapsed)
        self._last_call = time.monotonic()

    def _request(self, method, url, **kwargs) -> httpx.Response:
        for attempt in range(self._max_retries + 1):
            self._throttle()
            try:
                response = self._http.request(method, url, **kwargs)
            except httpx.RequestError as exc:
                # Never reached the server: retryable, and it must not
                # escape as a bare httpx exception - cli.main only handles
                # NotionUploadError.
                if attempt == self._max_retries:
                    raise APIError(f"could not reach Notion: {exc}") from exc
                self._sleep(min(2**attempt, 30) + random.random())
                continue
            if response.status_code < 400:
                return response
            if response.status_code not in RETRYABLE_STATUS or attempt == self._max_retries:
                raise APIError(self._describe(response), status=response.status_code)
            self._sleep(self._retry_delay(response, attempt))
        raise AssertionError("unreachable")

    @staticmethod
    def _retry_delay(response, attempt) -> float:
        header = response.headers.get("Retry-After")
        if header:
            try:
                return int(header)
            except ValueError:
                pass
        return min(2**attempt, 30) + random.random()

    @staticmethod
    def _describe(response) -> str:
        try:
            body = response.json()
            detail = body.get("message") or body.get("code") or response.text
        except ValueError:
            detail = response.text
        return f"{response.status_code} from {response.request.url.path}: {detail}"

    # -- pages and blocks ---------------------------------------------------

    def create_page(self, parent: dict, title: str, children: list[dict]) -> dict:
        body = {
            "parent": parent,
            "properties": {
                "title": {"title": [{"type": "text", "text": {"content": title}}]}
            },
        }
        # Omitted rather than sent as []: Notion validates children as a
        # non-empty array when the key is present, and the page is created
        # empty on purpose (see cli.upload).
        if children:
            body["children"] = children
        return self._request("POST", "/v1/pages", json=body).json()

    def append_children(self, block_id: str, children: list[dict]) -> list[dict]:
        response = self._request(
            "PATCH", f"/v1/blocks/{block_id}/children", json={"children": children}
        )
        return response.json().get("results", [])

    def retrieve_parent(self, object_id: str) -> dict:
        """Work out what kind of thing the user pointed us at.

        A bare UUID does not say whether it is a page, a data source or a
        database, and guessing wrong produces a confusing 400 from Notion, so
        probe in pre-flight instead.
        """
        probes = [
            (f"/v1/pages/{object_id}", "page_id"),
            (f"/v1/data_sources/{object_id}", "data_source_id"),
            (f"/v1/databases/{object_id}", "database_id"),
        ]
        for path, key in probes:
            try:
                self._request("GET", path)
            except APIError as exc:
                if exc.status == 404:
                    continue      # genuinely not this kind of object; try the next
                raise             # 401, 403, 400, transport failure: a real error
            return {key: object_id}
        raise APIError(
            f"parent {object_id} is not a page, data source or database "
            f"this integration can see. Check the id, and check the page is "
            f"shared with your integration."
        )

    # -- file uploads -------------------------------------------------------

    def create_file_upload(
        self, *, filename: str, content_type: str,
        mode: str = "single_part", number_of_parts: int | None = None,
    ) -> dict:
        body = {"mode": mode, "filename": filename, "content_type": content_type}
        if number_of_parts is not None:
            body["number_of_parts"] = number_of_parts
        return self._request("POST", "/v1/file_uploads", json=body).json()

    def send_file_upload(
        self, upload_id: str, data: bytes, filename: str,
        content_type: str, part_number: int | None = None,
    ) -> dict:
        files = {"file": (filename, data, content_type)}
        payload = {"part_number": str(part_number)} if part_number else None
        return self._request(
            "POST", f"/v1/file_uploads/{upload_id}/send", files=files, data=payload
        ).json()

    def complete_file_upload(self, upload_id: str) -> dict:
        return self._request("POST", f"/v1/file_uploads/{upload_id}/complete").json()

    def close(self):
        self._http.close()
