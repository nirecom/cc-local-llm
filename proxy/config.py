"""Environment-driven configuration for the ds4 reverse proxy.

load_config() reads every DS4_PROXY_* variable, applies defaults, expands ``~``
in filesystem paths, and returns a frozen ProxyConfig. DS4_PROXY_AUTH_TOKEN is
mandatory: an unset/empty value aborts the process with a clear message, so the
proxy can never start without an authentication secret.
"""

import os
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ProxyConfig:
    port: int
    upstream: str
    cert: Path
    key: Path
    auth_token: str
    tee: bool
    log_dir: Path


def load_config() -> ProxyConfig:
    """Build a ProxyConfig from the DS4_PROXY_* environment variables."""
    port = int(os.environ.get("DS4_PROXY_PORT", "8443"))
    upstream = os.environ.get("DS4_PROXY_UPSTREAM", "http://127.0.0.1:8000")

    cert = Path(
        os.environ.get("DS4_PROXY_CERT", "~/.config/ds4-proxy/cert.pem")
    ).expanduser()
    key = Path(
        os.environ.get("DS4_PROXY_KEY", "~/.config/ds4-proxy/key.pem")
    ).expanduser()

    auth_token = os.environ.get("DS4_PROXY_AUTH_TOKEN", "")
    if not auth_token:
        sys.exit(
            "[ds4-proxy] DS4_PROXY_AUTH_TOKEN is not set — refusing to start. "
            "Set it in the repo-root .env."
        )

    tee = os.environ.get("DS4_PROXY_TEE", "off") == "on"

    log_dir = Path(
        os.environ.get("DS4_PROXY_LOG_DIR", "~/Library/Caches/ds4-proxy/log")
    ).expanduser()

    return ProxyConfig(
        port=port,
        upstream=upstream,
        cert=cert,
        key=key,
        auth_token=auth_token,
        tee=tee,
        log_dir=log_dir,
    )
