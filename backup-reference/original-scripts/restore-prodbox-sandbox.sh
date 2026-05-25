#!/bin/bash

# restore-prodbox-sandbox.sh
# Purpose: Restore prodbox-sandbox data from prodbox backup on MacBook Pro.
# Runs on the MacBook Pro, pushes to prodbox-sandbox VM via SSH.

set -e

REMOTE_HOST="arunoda@prodbox-sandbox.local"
BACKUP_DIR="$HOME/prodbox-sandbox-backups"
REMOTE_APPS="/home/brain-sandbox/apps/"

# Parse arguments
DATE="${1:-latest}"

if [ "$DATE" = "latest" ]; then
    if [ -L "$BACKUP_DIR/apps/latest" ]; then
        DATE=$(readlink "$BACKUP_DIR/apps/latest")
    else
        echo "Error: No 'latest' symlink found. Specify a date: ./restore-prodbox-sandbox.sh YYYY-MM-DD"
        exit 1
    fi
fi

SANDBOX_DIR="$BACKUP_DIR/apps/$DATE"

if [ ! -d "$SANDBOX_DIR" ]; then
    echo "Error: Backup not found: $SANDBOX_DIR"
    exit 1
fi

echo "=== Restore prodbox-sandbox from $DATE ==="
echo "  - apps: $SANDBOX_DIR/ → $REMOTE_APPS"
echo ""
echo "WARNING: This will overwrite current data on prodbox-sandbox."
read -p "Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo "Restoring brain-sandbox/apps..."
rsync -az --delete --rsync-path="sudo rsync" "$SANDBOX_DIR/" "$REMOTE_HOST:$REMOTE_APPS"
ssh "$REMOTE_HOST" "sudo chown -R brain-sandbox:brain-sandbox /home/brain-sandbox/apps/"
echo "apps restored."

echo ""
echo "=== Restore completed ==="
