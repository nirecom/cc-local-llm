"""Environment-driven configuration for the ccgw reverse proxy.

load_config() reads every CCGW_PROXY_* variable, applies defaults, expands ``~``
in filesystem paths, and returns a frozen ProxyConfig. CCGW_PROXY_AUTH_TOKEN is
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
    host: str
    tls: bool
    upstream: str
    cert: Path
    key: Path
    auth_token: str
    tee: bool
    log_dir: Path


def load_config() -> ProxyConfig:
    """Build a ProxyConfig from the CCGW_PROXY_* environment variables."""
    port = int(os.environ.get("CCGW_PROXY_PORT", "8443"))
    host = os.environ.get("CCGW_PROXY_HOST", "0.0.0.0")
    # Only the literal "off" (any case) disables TLS: a typo must fail towards
    # an encrypted listener, never towards plaintext on a LAN-visible bind.
    tls = os.environ.get("CCGW_PROXY_TLS", "on").strip().lower() != "off"
    upstream = os.environ.get("CCGW_PROXY_UPSTREAM", "http://127.0.0.1:18080")

    cert = Path(
        os.environ.get("CCGW_PROXY_CERT", "~/.config/ccgw-proxy/cert.pem")
    ).expanduser()
    key = Path(
        os.environ.get("CCGW_PROXY_KEY", "~/.config/ccgw-proxy/key.pem")
    ).expanduser()

    auth_token = os.environ.get("CCGW_PROXY_AUTH_TOKEN", "")
    if not auth_token:
        sys.exit(
            "[ccgw-proxy] CCGW_PROXY_AUTH_TOKEN is not set — refusing to start. "
            "Set it in the repo-root .env."
        )

    tee = os.environ.get("CCGW_PROXY_TEE", "off") == "on"

    log_dir = Path(
        os.environ.get("CCGW_PROXY_LOG_DIR", "~/Library/Caches/ccgw-proxy/log")
    ).expanduser()

    return ProxyConfig(
        port=port,
        host=host,
        tls=tls,
        upstream=upstream,
        cert=cert,
        key=key,
        auth_token=auth_token,
        tee=tee,
        log_dir=log_dir,
    )
