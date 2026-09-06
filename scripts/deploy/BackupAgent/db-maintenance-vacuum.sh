#!/usr/bin/env bash
set -euo pipefail
# Manual only. Same preflight/offline/restoration path as opted-in image Apply.
exec python3 -u "$(dirname "${BASH_SOURCE[0]}")/db-maintenance.py" --local vacuum
