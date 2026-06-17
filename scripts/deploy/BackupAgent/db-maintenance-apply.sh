#!/usr/bin/env bash
set -uo pipefail

REMOTE_HOST="${OKBRAINCC_DB_MAINTENANCE_REMOTE_HOST:-arunoda@prodbox.local}"
RETENTION_DAYS="${OKBRAINCC_DB_MAINTENANCE_RETENTION_DAYS:-10}"

REMOTE_DB="/var/www/brain/brain.db"
REMOTE_SCRIPT="/var/www/brain/scripts/deploy/cleanup-old-execution-history.sh"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "=== DB Maintenance Apply ==="
log "Remote host: $REMOTE_HOST"
log "Database: $REMOTE_DB"
log "Retention: $RETENTION_DAYS days"
log ""

log "Connecting to $REMOTE_HOST..."
set +e
ssh "$REMOTE_HOST" "bash -s" <<REMOTE_CMD
set -euo pipefail
if [ ! -f "$REMOTE_SCRIPT" ]; then
  echo "ERROR: Cleanup script not found at $REMOTE_SCRIPT"
  exit 1
fi
if [ ! -f "$REMOTE_DB" ]; then
  echo "ERROR: Database not found at $REMOTE_DB"
  exit 1
fi
echo "Running cleanup with --apply..."
bash "$REMOTE_SCRIPT" --db "$REMOTE_DB" --days "$RETENTION_DAYS" --apply
REMOTE_CMD
EXIT_CODE=$?
set -e

log ""
if [ "$EXIT_CODE" -eq 0 ]; then
  log "=== Apply completed successfully ==="
else
  log "=== Apply failed with exit code $EXIT_CODE ==="
fi
exit "$EXIT_CODE"
