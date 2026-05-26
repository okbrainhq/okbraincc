#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="arunoda@prodbox-sandbox.local"
BACKUP_ROOT="$HOME/okbraincc-backups/prodbox-sandbox"
RUNS_DIR="$BACKUP_ROOT/runs"
RETENTION_DAYS=30

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

mkdir -p "$DATA_DIR/apps"
mkdir -p "$DATA_DIR/upload-images"
mkdir -p "$DATA_DIR/skills"
mkdir -p "$DATA_DIR/brain-data"

write_metadata() {
  cat >"$METADATA_FILE" <<EOF
system=prodbox-sandbox
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

  local dest="$DATA_DIR/$local_component"
  mkdir -p "$dest"

  local args=(-az --delete --rsync-path="sudo rsync")
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

log "=== Prodbox sandbox backup started: $RUN_ID ==="

sync_snapshot "brain-sandbox/apps" "/home/brain-sandbox/apps/" "apps"
sync_snapshot "brain-sandbox/upload_images" "/home/brain-sandbox/upload_images/" "upload-images"
sync_snapshot "brain-sandbox/skills" "/home/brain-sandbox/skills/" "skills"
sync_snapshot "brain-data" "/var/www/brain-data/" "brain-data"

log "Cleaning up runs older than $RETENTION_DAYS days..."
find "$RUNS_DIR" -maxdepth 1 -mindepth 1 -type d -name "20*" -mtime +"$RETENTION_DAYS" -exec rm -rf {} \; -print | while read -r f; do
  log "Removed old run: $f"
done

STATUS="success"
log "=== Prodbox sandbox backup completed: $RUN_ID ==="
