# Tests: proxy/normalize.py, proxy/http_io.py, proxy/auth.py
# Tags: scope:issue-specific
#
# L3 gap (what this test suite does NOT catch — explicitly deferred):
# - Real asyncio TLS handshake behavior with mkcert certificates
# - Actual SSE streaming under CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1
# - End-to-end chunked transfer between real client and upstream ds4 server
# - Proxy handler integration (server.py not yet written; auth→normalize→
#     forward→sanitize pipeline tested post-/write-code as L2 integration tests)
# - Launcher scripts (ds4-server.sh, code-ds4.cmd, ds4-proxy.sh not yet
#     written; bind address, HTTPS URL, NODE_EXTRA_CA_CERTS, KV-cache flags
#     deferred to post-/write-code)
# - .env.example / docs consistency (files not yet written; env var, host/port
#     SSOT, TLS setup validation deferred to post-/write-code)
# - tee-log security (tee.py not yet written; logging toggle, pre/post-norm
#     body files, no auth-token leakage in logs deferred to post-/write-code)
# - Malformed JSON shape at handler level (server.py not yet written; non-list
#     messages, non-dict entries, non-list tools → controlled 4xx coverage
#     deferred to post-/write-code as L2 handler integration tests)
# - Security idempotency (repeated starts, duplicate CA/env entries: deferred
#     to post-/write-code environment-level tests)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: pwsh-required
"""Dispatcher: all tests live in tests/feature-13-ds4-proxy/.

pytest discovers the subdirectory automatically — no test functions here.
"""
