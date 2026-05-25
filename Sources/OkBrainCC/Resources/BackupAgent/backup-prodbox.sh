#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="arunoda@prodbox.local"
BACKUP_DIR="$HOME/prodbox-backups"
RETENTION_DAYS=30
LOG_FILE="$BACKUP_DIR/backup.log"
DATE="$(date +%Y-%m-%d)"

mkdir -p "$BACKUP_DIR/db"
mkdir -p "$BACKUP_DIR/brain-data"
mkdir -p "$BACKUP_DIR/brain-uploads"
mkdir -p "$BACKUP_DIR/brain-sandbox"
mkdir -p "$BACKUP_DIR/brain-sandbox-skills"
mkdir -p "$BACKUP_DIR/brain-sandbox-upload-images"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

sync_snapshot() {
  local name="$1"
  local remote_path="$2"
  local local_component="$3"
  local rsync_path="${4:-}"

  local dest="$BACKUP_DIR/$local_component/$DATE"
  local link_dest="$BACKUP_DIR/$local_component/latest"

  mkdir -p "$dest"

  local args=(-az --delete)
  if [ -n "$rsync_path" ]; then
    args+=(--rsync-path="$rsync_path")
  fi
  if [ -d "$link_dest" ]; then
    log "Syncing $name with link-dest from latest..."
    args+=(--link-dest="$link_dest")
  else
    log "Syncing $name (first run, no link-dest)..."
  fi

  rsync "${args[@]}" "$REMOTE_HOST:$remote_path" "$dest/"
  touch "$dest"
  ln -snf "$DATE" "$BACKUP_DIR/$local_component/latest"
  log "$name backup saved: $dest ($(du -sh "$dest" | cut -f1))"
}

remove_old_snapshots() {
  local component="$1"
  find "$BACKUP_DIR/$component" -maxdepth 1 -mindepth 1 -type d -name "20*" -mtime +"$RETENTION_DAYS" -exec rm -rf {} \; -print | while read -r f; do
    log "Removed old $component snapshot: $f"
  done
}

log "=== Backup started ==="

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

sync_snapshot "brain-data" "/var/www/brain-data/" "brain-data"
sync_snapshot "brain-uploads" "/var/www/brain-data/uploads/" "brain-uploads"

if ssh "$REMOTE_HOST" "test -d /home/brain-sandbox/apps" 2>/dev/null; then
  sync_snapshot "brain-sandbox/apps" "/home/brain-sandbox/apps/" "brain-sandbox" "sudo rsync"
else
  log "Skipping brain-sandbox/apps: directory not found on remote"
fi

if ssh "$REMOTE_HOST" "test -d /home/brain-sandbox/skills" 2>/dev/null; then
  sync_snapshot "brain-sandbox/skills" "/home/brain-sandbox/skills/" "brain-sandbox-skills" "sudo rsync"
else
  log "Skipping brain-sandbox/skills: directory not found on remote"
fi

if ssh "$REMOTE_HOST" "test -d /home/brain-sandbox/upload_images" 2>/dev/null; then
  sync_snapshot "brain-sandbox/upload_images" "/home/brain-sandbox/upload_images/" "brain-sandbox-upload-images" "sudo rsync"
else
  log "Skipping brain-sandbox/upload_images: directory not found on remote"
fi

log "Cleaning up backups older than $RETENTION_DAYS days..."

find "$BACKUP_DIR/db" -name "brain-*.db" -mtime +"$RETENTION_DAYS" -delete -print | while read -r f; do
  log "Removed old db: $f"
done

remove_old_snapshots "brain-data"
remove_old_snapshots "brain-uploads"
remove_old_snapshots "brain-sandbox"
remove_old_snapshots "brain-sandbox-skills"
remove_old_snapshots "brain-sandbox-upload-images"

log "=== Backup completed ==="
