#!/bin/sh
# SSOT for the ops repository root and the dotenv file location.
# Sourced first by every entrypoint under scripts/, before load-dotenv.sh.
# Requires: DS4_SCRIPT_DIR — absolute path of scripts/, set by the caller
# (each entrypoint must locate its own directory before it can source anything).
# Note: DS4_OPS_ROOT can be overridden from .env (load-dotenv.sh runs after this
# file, and _dotenv_is_set treats an unexported shell variable as unset).
: "${DS4_SCRIPT_DIR:?lib/root.sh requires DS4_SCRIPT_DIR}"
DS4_OPS_ROOT="${DS4_OPS_ROOT:-$(CDPATH= cd -- "$DS4_SCRIPT_DIR/.." && pwd)}"
DOTENV_FILE="${DOTENV_FILE:-$DS4_OPS_ROOT/.env}"
