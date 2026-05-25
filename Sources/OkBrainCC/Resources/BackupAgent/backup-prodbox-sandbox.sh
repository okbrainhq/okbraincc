#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="arunoda@prodbox-sandbox.local"
BACKUP_DIR="$HOME/prodbox-sandbox-backups"
RETENTION_DAYS=30
LOG_FILE="$BACKUP_DIR/backup.log"
DATE="$(date +%Y-%m-%d)"

mkdir -p "$BACKUP_DIR/apps"
mkdir -p "$BACKUP_DIR/upload_images"
mkdir -p "$BACKUP_DIR/skills"
mkdir -p "$BACKUP_DIR/brain-data"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

sync_snapshot() {
  local name="$1"
  local remote_path="$2"
  local local_component="$3"

  local dest="$BACKUP_DIR/$local_component/$DATE"
  local link_dest="$BACKUP_DIR/$local_component/latest"

  mkdir -p "$dest"

  local args=(-az --delete --rsync-path="sudo rsync")
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

log "=== Prodbox sandbox backup started ==="

sync_snapshot "brain-sandbox/apps" "/home/brain-sandbox/apps/" "apps"
sync_snapshot "brain-sandbox/upload_images" "/home/brain-sandbox/upload_images/" "upload_images"
sync_snapshot "brain-sandbox/skills" "/home/brain-sandbox/skills/" "skills"
sync_snapshot "brain-data" "/var/www/brain-data/" "brain-data"

log "Cleaning up backups older than $RETENTION_DAYS days..."

for component in apps upload_images skills brain-data; do
  find "$BACKUP_DIR/$component" -maxdepth 1 -mindepth 1 -type d -name "20*" -mtime +"$RETENTION_DAYS" -exec rm -rf {} \; -print | while read -r f; do
    log "Removed old $component snapshot: $f"
  done
done

log "=== Prodbox sandbox backup completed ==="
