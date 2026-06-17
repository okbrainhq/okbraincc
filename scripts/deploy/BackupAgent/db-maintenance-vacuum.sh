#!/usr/bin/env bash
set -uo pipefail

REMOTE_HOST="${OKBRAINCC_DB_MAINTENANCE_REMOTE_HOST:-arunoda@prodbox.local}"
RETENTION_DAYS="${OKBRAINCC_DB_MAINTENANCE_RETENTION_DAYS:-10}"

REMOTE_DB="/var/www/brain/brain.db"
REMOTE_SCRIPT="/var/www/brain/scripts/deploy/cleanup-old-execution-history.sh"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "=== DB Maintenance Vacuum ==="
log "Remote host: $REMOTE_HOST"
log "Database: $REMOTE_DB"
log "Retention: $RETENTION_DAYS days"
log "WARNING: This will stop the brain service during vacuum."
log ""

log "Connecting to $REMOTE_HOST..."
set +e
ssh "$REMOTE_HOST" "bash -s" <<REMOTE_CMD
set -uo pipefail

if [ ! -f "$REMOTE_SCRIPT" ]; then
  echo "ERROR: Cleanup script not found at $REMOTE_SCRIPT"
  exit 1
fi
if [ ! -f "$REMOTE_DB" ]; then
  echo "ERROR: Database not found at $REMOTE_DB"
  exit 1
fi

BRAIN_WAS_STOPPED=0
CLEANUP_EXIT=0

start_brain() {
  if [ "\$BRAIN_WAS_STOPPED" -eq 1 ]; then
    echo "Starting brain service..."
    sudo systemctl start brain || echo "WARNING: Failed to start brain service"
    echo "Brain service started."
  fi
}
trap start_brain EXIT

echo "Stopping brain service..."
if ! sudo systemctl stop brain; then
  echo "ERROR: Failed to stop brain service. Aborting vacuum."
  exit 1
fi
BRAIN_WAS_STOPPED=1
echo "Brain service stopped."

echo "Running cleanup with --apply --vacuum..."
bash "$REMOTE_SCRIPT" --db "$REMOTE_DB" --days "$RETENTION_DAYS" --apply --vacuum || CLEANUP_EXIT=\$?

if [ "\$CLEANUP_EXIT" -eq 0 ]; then
  echo "Vacuum completed."
else
  echo "Vacuum failed with exit code \$CLEANUP_EXIT"
fi
exit "\$CLEANUP_EXIT"
REMOTE_CMD
EXIT_CODE=$?
set -e

log ""
if [ "$EXIT_CODE" -eq 0 ]; then
  log "=== Vacuum completed successfully ==="
else
  log "=== Vacuum failed with exit code $EXIT_CODE ==="
fi
exit "$EXIT_CODE"
