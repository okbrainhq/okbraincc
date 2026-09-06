#!/usr/bin/env bash
set -euo pipefail
# Manual only: offline history compaction with writer restoration. Images are preview-only.
# Normal Apply is online and never enters this service-control path.
exec python3 -u "$(dirname "${BASH_SOURCE[0]}")/db-maintenance.py" --local vacuum
