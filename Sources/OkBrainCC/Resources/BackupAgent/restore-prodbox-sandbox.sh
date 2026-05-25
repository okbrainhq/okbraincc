#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="arunoda@prodbox-sandbox.local"
BACKUP_DIR="$HOME/prodbox-sandbox-backups"
REMOTE_APPS="/home/brain-sandbox/apps/"

DATE="latest"
ASSUME_YES="0"

for arg in "$@"; do
  case "$arg" in
    --yes)
      ASSUME_YES="1"
      ;;
    --apps-only)
      ;;
    *)
      DATE="$arg"
      ;;
  esac
done

if [ "$DATE" = "latest" ]; then
  if [ -L "$BACKUP_DIR/apps/latest" ]; then
    DATE="$(readlink "$BACKUP_DIR/apps/latest")"
  else
    echo "Error: No 'latest' symlink found. Specify a date."
    exit 1
  fi
fi

SANDBOX_DIR="$BACKUP_DIR/apps/$DATE"

if [ ! -d "$SANDBOX_DIR" ]; then
  echo "Error: Backup not found: $SANDBOX_DIR"
  exit 1
fi

echo "=== Restore prodbox-sandbox from $DATE ==="
echo "  - apps: $SANDBOX_DIR/ -> $REMOTE_APPS"

if [ "$ASSUME_YES" != "1" ]; then
  echo ""
  echo "WARNING: This will overwrite current data on prodbox-sandbox."
  read -r -p "Continue? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES)
      ;;
    *)
      echo "Aborted."
      exit 0
      ;;
  esac
fi

echo "Restoring brain-sandbox/apps..."
rsync -az --delete --rsync-path="sudo rsync" "$SANDBOX_DIR/" "$REMOTE_HOST:$REMOTE_APPS"
ssh "$REMOTE_HOST" "sudo chown -R brain-sandbox:brain-sandbox /home/brain-sandbox/apps/"
echo "apps restored."

echo ""
echo "=== Restore completed ==="
