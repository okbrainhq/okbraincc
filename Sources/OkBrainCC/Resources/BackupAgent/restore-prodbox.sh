#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="arunoda@prodbox.local"
BACKUP_DIR="$HOME/prodbox-backups"
REMOTE_DB="/var/www/brain/brain.db"
REMOTE_DATA="/var/www/brain-data/"
REMOTE_UPLOADS="/var/www/brain-data/uploads/"
REMOTE_SANDBOX="/home/brain-sandbox/apps/"
APP_NAME="brain"

DATE="latest"
FILTER=""
ASSUME_YES="0"

for arg in "$@"; do
  case "$arg" in
    --yes)
      ASSUME_YES="1"
      ;;
    --db-only|--data-only|--uploads-only|--sandbox-only)
      FILTER="$arg"
      ;;
    *)
      DATE="$arg"
      ;;
  esac
done

if [ "$DATE" = "latest" ]; then
  if [ -L "$BACKUP_DIR/brain-data/latest" ]; then
    DATE="$(readlink "$BACKUP_DIR/brain-data/latest")"
  else
    echo "Error: No 'latest' symlink found. Specify a date."
    exit 1
  fi
fi

DB_FILE="$BACKUP_DIR/db/brain-$DATE.db"
DATA_DIR="$BACKUP_DIR/brain-data/$DATE"
UPLOADS_DIR="$BACKUP_DIR/brain-uploads/$DATE"
SANDBOX_DIR="$BACKUP_DIR/brain-sandbox/$DATE"

MISSING=()
[ ! -f "$DB_FILE" ] && MISSING+=("db: $DB_FILE")
[ ! -d "$DATA_DIR" ] && MISSING+=("brain-data: $DATA_DIR")
[ ! -d "$UPLOADS_DIR" ] && MISSING+=("brain-uploads: $UPLOADS_DIR")
[ ! -d "$SANDBOX_DIR" ] && MISSING+=("brain-sandbox: $SANDBOX_DIR")

if [ "${#MISSING[@]}" -gt 0 ] && [ -z "$FILTER" ]; then
  echo "Error: Missing backup components for $DATE:"
  for item in "${MISSING[@]}"; do
    echo "  - $item"
  done
  echo ""
  echo "Available database backups:"
  ls "$BACKUP_DIR/db/" 2>/dev/null | sed 's/brain-//;s/.db//' | sort || true
  exit 1
fi

echo "=== Restore from $DATE ==="
echo "This will restore to $REMOTE_HOST:"
if [ -z "$FILTER" ] || [ "$FILTER" = "--db-only" ]; then echo "  - Database: $DB_FILE -> $REMOTE_DB"; fi
if [ -z "$FILTER" ] || [ "$FILTER" = "--data-only" ]; then echo "  - brain-data: $DATA_DIR/ -> $REMOTE_DATA"; fi
if [ -z "$FILTER" ] || [ "$FILTER" = "--uploads-only" ]; then echo "  - brain-uploads: $UPLOADS_DIR/ -> $REMOTE_UPLOADS"; fi
if [ -z "$FILTER" ] || [ "$FILTER" = "--sandbox-only" ]; then echo "  - brain-sandbox/apps: $SANDBOX_DIR/ -> $REMOTE_SANDBOX"; fi

if [ "$ASSUME_YES" != "1" ]; then
  echo ""
  echo "WARNING: This will overwrite current data on the VM."
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

echo ""
echo "Stopping brain app on remote..."
ssh "$REMOTE_HOST" "sudo systemctl stop $APP_NAME"

if [ -z "$FILTER" ] || [ "$FILTER" = "--db-only" ]; then
  if [ ! -f "$DB_FILE" ]; then
    echo "Skipping DB restore: $DB_FILE not found"
  else
    echo "Uploading database ($(du -h "$DB_FILE" | cut -f1))..."
    ssh "$REMOTE_HOST" "rm -f '${REMOTE_DB}-wal' '${REMOTE_DB}-shm'"
    scp "$DB_FILE" "$REMOTE_HOST:$REMOTE_DB"
    echo "Database restored."
  fi
fi

if [ -z "$FILTER" ] || [ "$FILTER" = "--data-only" ]; then
  if [ ! -d "$DATA_DIR" ]; then
    echo "Skipping brain-data restore: $DATA_DIR not found"
  else
    echo "Restoring brain-data..."
    rsync -az --delete "$DATA_DIR/" "$REMOTE_HOST:$REMOTE_DATA"
    echo "brain-data restored."
  fi
fi

if [ -z "$FILTER" ] || [ "$FILTER" = "--uploads-only" ]; then
  if [ ! -d "$UPLOADS_DIR" ]; then
    echo "Skipping brain-uploads restore: $UPLOADS_DIR not found"
  else
    echo "Restoring brain-uploads..."
    rsync -az --delete "$UPLOADS_DIR/" "$REMOTE_HOST:$REMOTE_UPLOADS"
    echo "brain-uploads restored."
  fi
fi

if [ -z "$FILTER" ] || [ "$FILTER" = "--sandbox-only" ]; then
  if [ ! -d "$SANDBOX_DIR" ]; then
    echo "Skipping brain-sandbox restore: $SANDBOX_DIR not found"
  elif ! ssh "$REMOTE_HOST" "test -d /home/brain-sandbox" 2>/dev/null; then
    echo "Skipping brain-sandbox restore: /home/brain-sandbox not found on remote"
  else
    echo "Restoring brain-sandbox/apps..."
    rsync -az --delete --rsync-path="sudo rsync" "$SANDBOX_DIR/" "$REMOTE_HOST:$REMOTE_SANDBOX"
    ssh "$REMOTE_HOST" "sudo chown -R brain-sandbox:brain-sandbox /home/brain-sandbox/apps/"
    echo "brain-sandbox/apps restored."
  fi
fi

echo ""
echo "Starting brain app on remote..."
ssh "$REMOTE_HOST" "sudo systemctl start $APP_NAME"

echo ""
echo "=== Restore completed ==="
