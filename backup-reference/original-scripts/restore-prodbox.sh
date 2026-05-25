#!/bin/bash

# restore-prodbox.sh
# Purpose: Restore Prodbox VM data from a MacBook Pro backup.
# Runs on the MacBook Pro, pushes to the VM via SSH.
#
# Usage:
#   ./restore-prodbox.sh                  # restore from latest backup
#   ./restore-prodbox.sh 2026-03-11       # restore from a specific date
#   ./restore-prodbox.sh 2026-03-11 --db-only      # restore only the database
#   ./restore-prodbox.sh 2026-03-11 --data-only     # restore only brain-data
#   ./restore-prodbox.sh 2026-03-11 --uploads-only   # restore only brain-uploads
#   ./restore-prodbox.sh 2026-03-11 --sandbox-only   # restore only brain-sandbox

set -e

# ── Configuration ──────────────────────────────────────────────
REMOTE_HOST="arunoda@prodbox.local"
BACKUP_DIR="$HOME/prodbox-backups"
REMOTE_DB="/var/www/brain/brain.db"
REMOTE_DATA="/var/www/brain-data/"
REMOTE_UPLOADS="/var/www/brain-data/uploads/"
REMOTE_SANDBOX="/home/brain-sandbox/apps/"
APP_NAME="brain"
# ───────────────────────────────────────────────────────────────

# Parse arguments
DATE="${1:-latest}"
FILTER="${2:-}"

if [ "$DATE" = "latest" ]; then
    # Resolve latest from the brain-data symlink
    if [ -L "$BACKUP_DIR/brain-data/latest" ]; then
        DATE=$(readlink "$BACKUP_DIR/brain-data/latest")
    else
        echo "Error: No 'latest' symlink found. Specify a date: ./restore-prodbox.sh YYYY-MM-DD"
        exit 1
    fi
fi

# Validate backup exists
DB_FILE="$BACKUP_DIR/db/brain-$DATE.db"
DATA_DIR="$BACKUP_DIR/brain-data/$DATE"
UPLOADS_DIR="$BACKUP_DIR/brain-uploads/$DATE"
SANDBOX_DIR="$BACKUP_DIR/brain-sandbox/$DATE"

MISSING=()
[ ! -f "$DB_FILE" ] && MISSING+=("db: $DB_FILE")
[ ! -d "$DATA_DIR" ] && MISSING+=("brain-data: $DATA_DIR")
[ ! -d "$UPLOADS_DIR" ] && MISSING+=("brain-uploads: $UPLOADS_DIR")
[ ! -d "$SANDBOX_DIR" ] && MISSING+=("brain-sandbox: $SANDBOX_DIR")

if [ ${#MISSING[@]} -gt 0 ] && [ -z "$FILTER" ]; then
    echo "Error: Missing backup components for $DATE:"
    for m in "${MISSING[@]}"; do echo "  - $m"; done
    echo ""
    echo "Available backups:"
    ls "$BACKUP_DIR/db/" 2>/dev/null | sed 's/brain-//;s/.db//' | sort
    exit 1
fi

echo "=== Restore from $DATE ==="
echo ""
echo "This will restore to $REMOTE_HOST:"
[ -z "$FILTER" ] || [ "$FILTER" = "--db-only" ] && echo "  - Database: $DB_FILE → $REMOTE_DB"
[ -z "$FILTER" ] || [ "$FILTER" = "--data-only" ] && echo "  - brain-data: $DATA_DIR/ → $REMOTE_DATA"
[ -z "$FILTER" ] || [ "$FILTER" = "--uploads-only" ] && echo "  - brain-uploads: $UPLOADS_DIR/ → $REMOTE_UPLOADS"
[ -z "$FILTER" ] || [ "$FILTER" = "--sandbox-only" ] && echo "  - brain-sandbox/apps: $SANDBOX_DIR/ → $REMOTE_SANDBOX"
echo ""
echo "WARNING: This will overwrite current data on the VM."
read -p "Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ── 1. Stop the app ──────────────────────────────────────────
echo ""
echo "Stopping brain app on remote..."
ssh "$REMOTE_HOST" "sudo systemctl stop $APP_NAME"

# ── 2. Restore database ──────────────────────────────────────
if [ -z "$FILTER" ] || [ "$FILTER" = "--db-only" ]; then
    if [ ! -f "$DB_FILE" ]; then
        echo "Skipping DB restore: $DB_FILE not found"
    else
        echo "Uploading database ($( du -h "$DB_FILE" | cut -f1 ))..."
        # Remove WAL/SHM files first, then replace the main db
        ssh "$REMOTE_HOST" "rm -f '${REMOTE_DB}-wal' '${REMOTE_DB}-shm'"
        scp "$DB_FILE" "$REMOTE_HOST:$REMOTE_DB"
        echo "Database restored."
    fi
fi

# ── 3. Restore brain-data ────────────────────────────────────
if [ -z "$FILTER" ] || [ "$FILTER" = "--data-only" ]; then
    if [ ! -d "$DATA_DIR" ]; then
        echo "Skipping brain-data restore: $DATA_DIR not found"
    else
        echo "Restoring brain-data..."
        rsync -az --delete "$DATA_DIR/" "$REMOTE_HOST:$REMOTE_DATA"
        echo "brain-data restored."
    fi
fi

# ── 4. Restore brain-uploads ────────────────────────────────
if [ -z "$FILTER" ] || [ "$FILTER" = "--uploads-only" ]; then
    if [ ! -d "$UPLOADS_DIR" ]; then
        echo "Skipping brain-uploads restore: $UPLOADS_DIR not found"
    else
        echo "Restoring brain-uploads..."
        rsync -az --delete "$UPLOADS_DIR/" "$REMOTE_HOST:$REMOTE_UPLOADS"
        echo "brain-uploads restored."
    fi
fi

# ── 5. Restore brain-sandbox ─────────────────────────────────
if [ -z "$FILTER" ] || [ "$FILTER" = "--sandbox-only" ]; then
    if [ ! -d "$SANDBOX_DIR" ]; then
        echo "Skipping brain-sandbox restore: $SANDBOX_DIR not found"
    elif ! ssh "$REMOTE_HOST" "test -d /home/brain-sandbox" 2>/dev/null; then
        echo "Skipping brain-sandbox restore: /home/brain-sandbox not found on remote"
    else
        echo "Restoring brain-sandbox/apps..."
        rsync -az --delete --rsync-path="sudo rsync" "$SANDBOX_DIR/" "$REMOTE_HOST:$REMOTE_SANDBOX"
        # Fix ownership back to brain-sandbox user
        ssh "$REMOTE_HOST" "sudo chown -R brain-sandbox:brain-sandbox /home/brain-sandbox/apps/"
        echo "brain-sandbox/apps restored."
    fi
fi

# ── 6. Start the app ─────────────────────────────────────────
echo ""
echo "Starting brain app on remote..."
ssh "$REMOTE_HOST" "sudo systemctl start $APP_NAME"

echo ""
echo "=== Restore completed ==="
