#!/bin/bash

# backup-prodbox.sh
# Purpose: Daily backup of Prodbox VM data to the MacBook Pro host.
# Runs on the MacBook Pro, pulls from the VM via SSH.
#
# Backs up:
#   1. SQLite database (safe .backup snapshot)
#   2. /var/www/brain-data/ (chat uploads, chat-data, smart-doc-data)
#   3. /var/www/brain-data/uploads/ (docs system uploads)
#   4. /home/brain-sandbox/apps/ (sandbox apps)
#
# Uses rsync --link-dest for space-efficient snapshots.
# Retains 30 days of backups.

set -e

# ── Configuration ──────────────────────────────────────────────
REMOTE_HOST="arunoda@prodbox.local"
BACKUP_DIR="$HOME/prodbox-backups"
RETENTION_DAYS=30
LOG_FILE="$BACKUP_DIR/backup.log"
# ───────────────────────────────────────────────────────────────

DATE=$(date +%Y-%m-%d)

mkdir -p "$BACKUP_DIR/db"
mkdir -p "$BACKUP_DIR/brain-data"
mkdir -p "$BACKUP_DIR/brain-uploads"
mkdir -p "$BACKUP_DIR/brain-sandbox"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== Backup started ==="

# ── 1. Database backup ────────────────────────────────────────
REMOTE_DB="/var/www/brain/brain.db"
REMOTE_BACKUP="/tmp/prodbox-backup-$(date +%s).db"
LOCAL_DB="$BACKUP_DIR/db/brain-$DATE.db"

log "Creating sqlite3 backup on remote..."
ssh "$REMOTE_HOST" "sqlite3 '$REMOTE_DB' \".backup '$REMOTE_BACKUP'\""

log "Downloading database backup..."
scp "$REMOTE_HOST:$REMOTE_BACKUP" "$LOCAL_DB"

log "Cleaning up remote temp file..."
ssh "$REMOTE_HOST" "rm -f '$REMOTE_BACKUP'"

log "Database backup saved: $LOCAL_DB ($(du -h "$LOCAL_DB" | cut -f1))"

# ── 2. brain-data backup ─────────────────────────────────────
DEST="$BACKUP_DIR/brain-data/$DATE"
LINK_DEST="$BACKUP_DIR/brain-data/latest"

mkdir -p "$DEST"

if [ -d "$LINK_DEST" ]; then
    log "Syncing brain-data with link-dest from latest..."
    rsync -az --delete --link-dest="$LINK_DEST" "$REMOTE_HOST:/var/www/brain-data/" "$DEST/"
else
    log "Syncing brain-data (first run, no link-dest)..."
    rsync -az --delete "$REMOTE_HOST:/var/www/brain-data/" "$DEST/"
fi

touch "$DEST"
ln -snf "$DATE" "$BACKUP_DIR/brain-data/latest"
log "brain-data backup saved: $DEST ($(du -sh "$DEST" | cut -f1))"

# ── 3. brain-uploads backup (docs system) ──────────────────
DEST="$BACKUP_DIR/brain-uploads/$DATE"
LINK_DEST="$BACKUP_DIR/brain-uploads/latest"

mkdir -p "$DEST"

if [ -d "$LINK_DEST" ]; then
    log "Syncing brain-uploads with link-dest from latest..."
    rsync -az --delete --link-dest="$LINK_DEST" "$REMOTE_HOST:/var/www/brain-data/uploads/" "$DEST/"
else
    log "Syncing brain-uploads (first run, no link-dest)..."
    rsync -az --delete "$REMOTE_HOST:/var/www/brain-data/uploads/" "$DEST/"
fi

touch "$DEST"
ln -snf "$DATE" "$BACKUP_DIR/brain-uploads/latest"
log "brain-uploads backup saved: $DEST ($(du -sh "$DEST" | cut -f1))"

# ── 4. brain-sandbox/apps backup ─────────────────────────────
DEST="$BACKUP_DIR/brain-sandbox/$DATE"
LINK_DEST="$BACKUP_DIR/brain-sandbox/latest"

if ssh "$REMOTE_HOST" "test -d /home/brain-sandbox/apps" 2>/dev/null; then
    mkdir -p "$DEST"
    if [ -d "$LINK_DEST" ]; then
        log "Syncing brain-sandbox/apps with link-dest from latest..."
        rsync -az --delete --rsync-path="sudo rsync" --link-dest="$LINK_DEST" "$REMOTE_HOST:/home/brain-sandbox/apps/" "$DEST/"
    else
        log "Syncing brain-sandbox/apps (first run, no link-dest)..."
        rsync -az --delete --rsync-path="sudo rsync" "$REMOTE_HOST:/home/brain-sandbox/apps/" "$DEST/"
    fi
    touch "$DEST"
    ln -snf "$DATE" "$BACKUP_DIR/brain-sandbox/latest"
    log "brain-sandbox/apps backup saved: $DEST ($(du -sh "$DEST" | cut -f1))"
else
    log "Skipping brain-sandbox/apps: directory not found on remote"
fi

# ── 5. brain-sandbox/skills backup ───────────────────────────
DEST="$BACKUP_DIR/brain-sandbox-skills/$DATE"
LINK_DEST="$BACKUP_DIR/brain-sandbox-skills/latest"

if ssh "$REMOTE_HOST" "test -d /home/brain-sandbox/skills" 2>/dev/null; then
    mkdir -p "$DEST"
    if [ -d "$LINK_DEST" ]; then
        log "Syncing brain-sandbox/skills with link-dest from latest..."
        rsync -az --delete --rsync-path="sudo rsync" --link-dest="$LINK_DEST" "$REMOTE_HOST:/home/brain-sandbox/skills/" "$DEST/"
    else
        log "Syncing brain-sandbox/skills (first run, no link-dest)..."
        rsync -az --delete --rsync-path="sudo rsync" "$REMOTE_HOST:/home/brain-sandbox/skills/" "$DEST/"
    fi
    touch "$DEST"
    ln -snf "$DATE" "$BACKUP_DIR/brain-sandbox-skills/latest"
    log "brain-sandbox/skills backup saved: $DEST ($(du -sh "$DEST" | cut -f1))"
else
    log "Skipping brain-sandbox/skills: directory not found on remote"
fi

# ── 6. brain-sandbox/upload_images backup ────────────────────
DEST="$BACKUP_DIR/brain-sandbox-upload-images/$DATE"
LINK_DEST="$BACKUP_DIR/brain-sandbox-upload-images/latest"

if ssh "$REMOTE_HOST" "test -d /home/brain-sandbox/upload_images" 2>/dev/null; then
    mkdir -p "$DEST"
    if [ -d "$LINK_DEST" ]; then
        log "Syncing brain-sandbox/upload_images with link-dest from latest..."
        rsync -az --delete --rsync-path="sudo rsync" --link-dest="$LINK_DEST" "$REMOTE_HOST:/home/brain-sandbox/upload_images/" "$DEST/"
    else
        log "Syncing brain-sandbox/upload_images (first run, no link-dest)..."
        rsync -az --delete --rsync-path="sudo rsync" "$REMOTE_HOST:/home/brain-sandbox/upload_images/" "$DEST/"
    fi
    touch "$DEST"
    ln -snf "$DATE" "$BACKUP_DIR/brain-sandbox-upload-images/latest"
    log "brain-sandbox/upload_images backup saved: $DEST ($(du -sh "$DEST" | cut -f1))"
else
    log "Skipping brain-sandbox/upload_images: directory not found on remote"
fi

# ── 7. Cleanup old backups ───────────────────────────────────
log "Cleaning up backups older than $RETENTION_DAYS days..."

# Remove old database files
find "$BACKUP_DIR/db" -name "brain-*.db" -mtime +$RETENTION_DAYS -delete -print | while read f; do
    log "Removed old db: $f"
done

# Remove old brain-data snapshots
find "$BACKUP_DIR/brain-data" -maxdepth 1 -mindepth 1 -type d -name "20*" -mtime +$RETENTION_DAYS -exec rm -rf {} \; -print | while read f; do
    log "Removed old brain-data snapshot: $f"
done

# Remove old brain-uploads snapshots
find "$BACKUP_DIR/brain-uploads" -maxdepth 1 -mindepth 1 -type d -name "20*" -mtime +$RETENTION_DAYS -exec rm -rf {} \; -print | while read f; do
    log "Removed old brain-uploads snapshot: $f"
done

# Remove old brain-sandbox snapshots
find "$BACKUP_DIR/brain-sandbox" -maxdepth 1 -mindepth 1 -type d -name "20*" -mtime +$RETENTION_DAYS -exec rm -rf {} \; -print | while read f; do
    log "Removed old brain-sandbox snapshot: $f"
done

# Remove old brain-sandbox-skills snapshots
find "$BACKUP_DIR/brain-sandbox-skills" -maxdepth 1 -mindepth 1 -type d -name "20*" -mtime +$RETENTION_DAYS -exec rm -rf {} \; -print | while read f; do
    log "Removed old brain-sandbox-skills snapshot: $f"
done

# Remove old brain-sandbox-upload-images snapshots
find "$BACKUP_DIR/brain-sandbox-upload-images" -maxdepth 1 -mindepth 1 -type d -name "20*" -mtime +$RETENTION_DAYS -exec rm -rf {} \; -print | while read f; do
    log "Removed old brain-sandbox-upload-images snapshot: $f"
done

log "=== Backup completed ==="
