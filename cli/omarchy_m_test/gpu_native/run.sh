#!/usr/bin/env bash
# Reviewed bundled host operation; no package installation or privilege changes.
set -euo pipefail
exec python3 "$(dirname -- "$0")/launcher.py" "$@"
