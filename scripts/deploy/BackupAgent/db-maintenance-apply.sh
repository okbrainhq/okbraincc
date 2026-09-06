#!/usr/bin/env bash
set -euo pipefail
exec python3 -u "$(dirname "${BASH_SOURCE[0]}")/db-maintenance.py" --local apply
