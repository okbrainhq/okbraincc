#!/bin/bash

# backup-prodbox-sandbox.sh
# Purpose: Daily backup of Prodbox Sandbox VM data to the MacBook Pro host.
# Runs on the MacBook Pro, pulls from prodbox-sandbox VM via SSH.
#
# Backs up:
#   1. /home/brain-sandbox/apps/       (app files)
#   2. /home/brain-sandbox/upload_images/  (uploaded images)
#   3. /home/brain-sandbox/skills/     (skills data)
#   4. /var/www/brain-data/            (chat-data, smart-doc-data, uploads)
#
# Uses rsync --link-dest for space-efficient snapshots.
# Retains 30 days of backups.

set -e

# ── Configuration ──────────────────────────────────────────────
REMOTE_HOST="arunoda@prodbox-sandbox.local"
BACKUP_DIR="$HOME/prodbox-sandbox-backups"
RETENTION_DAYS=30
LOG_FILE="$BACKUP_DIR/backup.log"
# ───────────────────────────────────────────────────────────────

DATE=$(date +%Y-%m-%d)

mkdir -p "$BACKUP_DIR/apps"
mkdir -p "$BACKUP_DIR/upload_images"
mkdir -p "$BACKUP_DIR/skills"
mkdir -p "$BACKUP_DIR/brain-data"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== Prodbox sandbox backup started ==="

# ── 1. brain-sandbox/apps ────────────────────────────────────
DEST="$BACKUP_DIR/apps/$DATE"
LINK_DEST="$BACKUP_DIR/apps/latest"

mkdir -p "$DEST"

if [ -d "$LINK_DEST" ]; then
    log "Syncing brain-sandbox/apps with link-dest from latest..."
    rsync -az --delete --rsync-path="sudo rsync" --link-dest="$LINK_DEST" "$REMOTE_HOST:/home/brain-sandbox/apps/" "$DEST/"
else
    log "Syncing brain-sandbox/apps (first run, no link-dest)..."
    rsync -az --delete --rsync-path="sudo rsync" "$REMOTE_HOST:/home/brain-sandbox/apps/" "$DEST/"
fi

touch "$DEST"
ln -snf "$DATE" "$BACKUP_DIR/apps/latest"
log "apps backup saved: $DEST ($(du -sh "$DEST" | cut -f1))"

# ── 2. brain-sandbox/upload_images ─────────────────────────────
DEST="$BACKUP_DIR/upload_images/$DATE"
LINK_DEST="$BACKUP_DIR/upload_images/latest"

mkdir -p "$DEST"

if [ -d "$LINK_DEST" ]; then
    log "Syncing brain-sandbox/upload_images with link-dest from latest..."
    rsync -az --delete --rsync-path="sudo rsync" --link-dest="$LINK_DEST" "$REMOTE_HOST:/home/brain-sandbox/upload_images/" "$DEST/"
else
    log "Syncing brain-sandbox/upload_images (first run, no link-dest)..."
    rsync -az --delete --rsync-path="sudo rsync" "$REMOTE_HOST:/home/brain-sandbox/upload_images/" "$DEST/"
fi

touch "$DEST"
ln -snf "$DATE" "$BACKUP_DIR/upload_images/latest"
log "upload_images backup saved: $DEST ($(du -sh "$DEST" | cut -f1))"

# ── 3. brain-sandbox/skills ──────────────────────────────────
DEST="$BACKUP_DIR/skills/$DATE"
LINK_DEST="$BACKUP_DIR/skills/latest"

mkdir -p "$DEST"

if [ -d "$LINK_DEST" ]; then
    log "Syncing brain-sandbox/skills with link-dest from latest..."
    rsync -az --delete --rsync-path="sudo rsync" --link-dest="$LINK_DEST" "$REMOTE_HOST:/home/brain-sandbox/skills/" "$DEST/"
else
    log "Syncing brain-sandbox/skills (first run, no link-dest)..."
    rsync -az --delete --rsync-path="sudo rsync" "$REMOTE_HOST:/home/brain-sandbox/skills/" "$DEST/"
fi

touch "$DEST"
ln -snf "$DATE" "$BACKUP_DIR/skills/latest"
log "skills backup saved: $DEST ($(du -sh "$DEST" | cut -f1))"

# ── 4. brain-data ────────────────────────────────────────────
DEST="$BACKUP_DIR/brain-data/$DATE"
LINK_DEST="$BACKUP_DIR/brain-data/latest"

mkdir -p "$DEST"

if [ -d "$LINK_DEST" ]; then
    log "Syncing brain-data with link-dest from latest..."
    rsync -az --delete --rsync-path="sudo rsync" --link-dest="$LINK_DEST" "$REMOTE_HOST:/var/www/brain-data/" "$DEST/"
else
    log "Syncing brain-data (first run, no link-dest)..."
    rsync -az --delete --rsync-path="sudo rsync" "$REMOTE_HOST:/var/www/brain-data/" "$DEST/"
fi

touch "$DEST"
ln -snf "$DATE" "$BACKUP_DIR/brain-data/latest"
log "brain-data backup saved: $DEST ($(du -sh "$DEST" | cut -f1))"

# ── 5. Cleanup old backups ───────────────────────────────────
log "Cleaning up backups older than $RETENTION_DAYS days..."

for component in apps upload_images skills brain-data; do
    find "$BACKUP_DIR/$component" -maxdepth 1 -mindepth 1 -type d -name "20*" -mtime +$RETENTION_DAYS -exec rm -rf {} \; -print | while read f; do
        log "Removed old $component snapshot: $f"
    done
done

log "=== Prodbox sandbox backup completed ==="
