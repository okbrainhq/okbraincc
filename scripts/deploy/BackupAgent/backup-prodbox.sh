#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="arunoda@prodbox.local"
BACKUP_ROOT="$HOME/okbraincc-backups/prodbox"
RUNS_DIR="$BACKUP_ROOT/runs"
RETENTION_COUNT="${OKBRAINCC_BACKUP_RETENTION_COUNT:-30}"

if ! [[ "$RETENTION_COUNT" =~ ^[0-9]+$ ]] || [ "$RETENTION_COUNT" -lt 1 ]; then
  RETENTION_COUNT=30
fi

RUN_ID_BASE="$(date +%Y-%m-%d-%H%M)"
RUN_ID="${OKBRAINCC_BACKUP_RUN_ID:-$RUN_ID_BASE}"
if [ -e "$RUNS_DIR/$RUN_ID" ]; then
  RUN_ID="$RUN_ID_BASE-$(date +%S)"
fi

RUN_DIR="$RUNS_DIR/$RUN_ID"
DATA_DIR="$RUN_DIR/data"
LOG_FILE="$RUN_DIR/backup.log"
STDOUT_LOG="$RUN_DIR/stdout.log"
STDERR_LOG="$RUN_DIR/stderr.log"
METADATA_FILE="$RUN_DIR/metadata.env"
STATUS="failed"
STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"

mkdir -p "$DATA_DIR/db"
mkdir -p "$DATA_DIR/brain-data"
mkdir -p "$DATA_DIR/brain-uploads"

write_metadata() {
  cat >"$METADATA_FILE" <<EOF
system=prodbox
run_id=$RUN_ID
status=$STATUS
started_at=$STARTED_AT
finished_at=$(date '+%Y-%m-%d %H:%M:%S')
remote_host=$REMOTE_HOST
EOF
}

finish() {
  write_metadata
}
trap finish EXIT

exec > >(tee -a "$STDOUT_LOG") 2> >(tee -a "$STDERR_LOG" >&2)

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

previous_component_path() {
  local component="$1"

  while IFS= read -r previous_run; do
    if [ -d "$RUNS_DIR/$previous_run/data/$component" ]; then
      printf '%s' "$RUNS_DIR/$previous_run/data/$component"
      return
    fi
  done < <(find "$RUNS_DIR" -maxdepth 1 -mindepth 1 -type d -name "20*" ! -name "$RUN_ID" -exec basename {} \; 2>/dev/null | sort -r)
}

sync_snapshot() {
  local name="$1"
  local remote_path="$2"
  local local_component="$3"
  local rsync_path="${4:-}"

  local dest="$DATA_DIR/$local_component"
  mkdir -p "$dest"

  local args=(-az --delete)
  if [ -n "$rsync_path" ]; then
    args+=(--rsync-path="$rsync_path")
  fi

  local link_dest
  link_dest="$(previous_component_path "$local_component")"
  if [ -n "$link_dest" ]; then
    log "Syncing $name with link-dest from previous run..."
    args+=(--link-dest="$link_dest")
  else
    log "Syncing $name (first run, no link-dest)..."
  fi

  rsync "${args[@]}" "$REMOTE_HOST:$remote_path" "$dest/"
  touch "$dest"
  log "$name backup saved: $dest ($(du -sh "$dest" | cut -f1))"
}

cleanup_old_runs() {
  local index=0

  while IFS= read -r run; do
    index=$((index + 1))
    if [ "$index" -le "$RETENTION_COUNT" ]; then
      continue
    fi

    rm -rf "$RUNS_DIR/$run"
    log "Removed old run: $run"
  done < <(find "$RUNS_DIR" -maxdepth 1 -mindepth 1 -type d -name "20*" -exec basename {} \; 2>/dev/null | sort -r)
}

log "=== Backup started: $RUN_ID ==="

REMOTE_DB="/var/www/brain/brain.db"
REMOTE_BACKUP="/tmp/prodbox-backup-$(date +%s).db"
LOCAL_DB="$DATA_DIR/db/brain.db"

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
  sync_snapshot "brain-sandbox/apps" "/home/brain-sandbox/apps/" "brain-sandbox/apps" "sudo rsync"
else
  log "Skipping brain-sandbox/apps: directory not found on remote"
fi

if ssh "$REMOTE_HOST" "test -d /home/brain-sandbox/skills" 2>/dev/null; then
  sync_snapshot "brain-sandbox/skills" "/home/brain-sandbox/skills/" "brain-sandbox/skills" "sudo rsync"
else
  log "Skipping brain-sandbox/skills: directory not found on remote"
fi

if ssh "$REMOTE_HOST" "test -d /home/brain-sandbox/upload_images" 2>/dev/null; then
  sync_snapshot "brain-sandbox/upload_images" "/home/brain-sandbox/upload_images/" "brain-sandbox/upload-images" "sudo rsync"
else
  log "Skipping brain-sandbox/upload_images: directory not found on remote"
fi

log "Keeping newest $RETENTION_COUNT backup runs..."
cleanup_old_runs

STATUS="success"
log "=== Backup completed: $RUN_ID ==="
