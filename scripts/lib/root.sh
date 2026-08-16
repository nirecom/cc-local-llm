#!/bin/sh
# SSOT for the ops repository root and the dotenv file location.
# Sourced first by every entrypoint under scripts/, before load-dotenv.sh.
# Requires: CCGW_SCRIPT_DIR — absolute path of scripts/, set by the caller
# (each entrypoint must locate its own directory before it can source anything).
# Note: CCGW_OPS_ROOT can be overridden from .env (load-dotenv.sh runs after this
# file, and _dotenv_is_set treats an unexported shell variable as unset).
: "${CCGW_SCRIPT_DIR:?lib/root.sh requires CCGW_SCRIPT_DIR}"
CCGW_OPS_ROOT="${CCGW_OPS_ROOT:-$(CDPATH= cd -- "$CCGW_SCRIPT_DIR/.." && pwd)}"
DOTENV_FILE="${DOTENV_FILE:-$CCGW_OPS_ROOT/.env}"
