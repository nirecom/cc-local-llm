"""Optional body-only request logging for the ccgw reverse proxy.

TeeLogger writes the pre- and post-normalization request bodies to disk when
CCGW_PROXY_TEE=on, so a normalization rule can be debugged by diffing what the
client sent against what was forwarded upstream. Auth headers are never part of
the body, so nothing sensitive is logged and no scrubbing is needed.
"""

import json
import threading
from pathlib import Path


class TeeLogger:
    def __init__(self, enabled: bool, log_dir: Path) -> None:
        self._enabled = enabled
        self._log_dir = log_dir
        self._seq = 0
        self._lock = threading.Lock()
        if enabled:
            log_dir.mkdir(parents=True, exist_ok=True)

    @property
    def enabled(self) -> bool:
        return self._enabled

    def log(
        self, timestamp: str, pre: dict, post: dict, shape: str | None = None
    ) -> None:
        """Write pre/post request bodies as a numbered pair of JSON files.

        No-op when logging is disabled. The per-instance sequence counter is
        incremented under a lock so concurrent connections never collide.

        ``shape`` ("anthropic" | "openai") is folded into the filename stem, so
        a dump says which rule set produced it. It stays out of the JSON: the
        shape is a property of the route, not data the client sent, and a dump
        has to remain replayable against the upstream. Omitted or None keeps
        the original naming.
        """
        if not self._enabled:
            return
        with self._lock:
            seq = self._seq
            self._seq += 1
        stem = f"{timestamp}-{seq:05d}"
        if shape:
            stem = f"{stem}-{shape}"
        self._write(f"{stem}-pre.json", pre)
        self._write(f"{stem}-post.json", post)

    def _write(self, name: str, body: dict) -> None:
        path = self._log_dir / name
        path.write_text(
            json.dumps(body, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
