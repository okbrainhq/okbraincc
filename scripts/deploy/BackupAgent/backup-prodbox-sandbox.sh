#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="${OKBRAINCC_BACKUP_REMOTE_HOST:-arunoda@prodbox-sandbox.local}"
BACKUP_ROOT="${OKBRAINCC_BACKUP_ROOT:-$HOME/okbraincc-backups/prodbox-sandbox}"
RUNS_DIR="$BACKUP_ROOT/runs"
RETENTION_COUNT="${OKBRAINCC_BACKUP_RETENTION_COUNT:-30}"

if ! [[ "$RETENTION_COUNT" =~ ^[0-9]+$ ]] || [ "$RETENTION_COUNT" -lt 1 ]; then
  RETENTION_COUNT=30
fi

RUN_ID_BASE="$(date +%Y-%m-%d-%H%M)"
RUN_ID="${OKBRAINCC_BACKUP_RUN_ID:-$RUN_ID_BASE}"
if [ -e "$RUNS_DIR/$RUN_ID" ] || [ -e "$RUNS_DIR/$RUN_ID.zip" ]; then
  RUN_ID="$RUN_ID_BASE-$(date +%S)"
fi

RUN_DIR="$RUNS_DIR/$RUN_ID"
DATA_DIR="$RUN_DIR/data"
LOG_FILE="$RUN_DIR/backup.log"
STDOUT_LOG="$RUN_DIR/stdout.log"
STDERR_LOG="$RUN_DIR/stderr.log"
MANIFEST_FILE="$RUN_DIR/manifest.json"
SIDECAR_MANIFEST="$RUNS_DIR/$RUN_ID.manifest.json"
ZIP_FILE="$RUNS_DIR/$RUN_ID.zip"
STATUS="failed"
STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"

mkdir -p "$DATA_DIR/apps"
mkdir -p "$DATA_DIR/upload-images"
mkdir -p "$DATA_DIR/skills"
mkdir -p "$DATA_DIR/brain-data"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

component_size() {
  local path="$1"
  if [ -e "$path" ]; then
    du -sh "$path" 2>/dev/null | cut -f1
  else
    echo "Missing"
  fi
}

write_manifest() {
  local finished_at
  finished_at="$(date '+%Y-%m-%d %H:%M:%S')"
  local zip_size_bytes=0
  if [ -f "$ZIP_FILE" ]; then
    zip_size_bytes="$(stat -f%z "$ZIP_FILE" 2>/dev/null || echo 0)"
  fi

  MANIFEST_SYSTEM="prodbox-sandbox" \
  MANIFEST_RUN_ID="$RUN_ID" \
  MANIFEST_STATUS="$STATUS" \
  MANIFEST_STARTED_AT="$STARTED_AT" \
  MANIFEST_FINISHED_AT="$finished_at" \
  MANIFEST_REMOTE_HOST="$REMOTE_HOST" \
  MANIFEST_ZIP_FILE="$RUN_ID.zip" \
  MANIFEST_ZIP_SIZE_BYTES="$zip_size_bytes" \
  MANIFEST_APPS_SIZE="$(component_size "$DATA_DIR/apps")" \
  MANIFEST_APPS_EXISTS="$([ -d "$DATA_DIR/apps" ] && echo true || echo false)" \
  MANIFEST_IMAGES_SIZE="$(component_size "$DATA_DIR/upload-images")" \
  MANIFEST_IMAGES_EXISTS="$([ -d "$DATA_DIR/upload-images" ] && echo true || echo false)" \
  MANIFEST_SKILLS_SIZE="$(component_size "$DATA_DIR/skills")" \
  MANIFEST_SKILLS_EXISTS="$([ -d "$DATA_DIR/skills" ] && echo true || echo false)" \
  MANIFEST_BRAIN_DATA_SIZE="$(component_size "$DATA_DIR/brain-data")" \
  MANIFEST_BRAIN_DATA_EXISTS="$([ -d "$DATA_DIR/brain-data" ] && echo true || echo false)" \
  MANIFEST_LOG_FILE="$LOG_FILE" \
  MANIFEST_STDOUT_FILE="$STDOUT_LOG" \
  MANIFEST_STDERR_FILE="$STDERR_LOG" \
  MANIFEST_OUTPUT="$MANIFEST_FILE" \
  python3 -c "
import json, os

def tail(path, max_bytes=60000):
    if not os.path.exists(path):
        return ''
    with open(path, 'r', errors='replace') as f:
        content = f.read()
    return content[-max_bytes:]

manifest = {
    'system': os.environ['MANIFEST_SYSTEM'],
    'run_id': os.environ['MANIFEST_RUN_ID'],
    'status': os.environ['MANIFEST_STATUS'],
    'started_at': os.environ['MANIFEST_STARTED_AT'],
    'finished_at': os.environ['MANIFEST_FINISHED_AT'],
    'remote_host': os.environ['MANIFEST_REMOTE_HOST'],
    'zip_file': os.environ['MANIFEST_ZIP_FILE'],
    'zip_size_bytes': int(os.environ['MANIFEST_ZIP_SIZE_BYTES']),
    'components': [
        {
            'id': 'apps',
            'title': 'Apps',
            'relative_path': 'data/apps',
            'size': os.environ['MANIFEST_APPS_SIZE'],
            'exists': os.environ['MANIFEST_APPS_EXISTS'] == 'true'
        },
        {
            'id': 'upload_images',
            'title': 'Upload Images',
            'relative_path': 'data/upload-images',
            'size': os.environ['MANIFEST_IMAGES_SIZE'],
            'exists': os.environ['MANIFEST_IMAGES_EXISTS'] == 'true'
        },
        {
            'id': 'skills',
            'title': 'Skills',
            'relative_path': 'data/skills',
            'size': os.environ['MANIFEST_SKILLS_SIZE'],
            'exists': os.environ['MANIFEST_SKILLS_EXISTS'] == 'true'
        },
        {
            'id': 'brain-data',
            'title': 'Brain Data',
            'relative_path': 'data/brain-data',
            'size': os.environ['MANIFEST_BRAIN_DATA_SIZE'],
            'exists': os.environ['MANIFEST_BRAIN_DATA_EXISTS'] == 'true'
        }
    ],
    'backup_log_tail': tail(os.environ['MANIFEST_LOG_FILE']),
    'stdout_log_tail': tail(os.environ['MANIFEST_STDOUT_FILE']),
    'stderr_log_tail': tail(os.environ['MANIFEST_STDERR_FILE'])
}

with open(os.environ['MANIFEST_OUTPUT'], 'w') as f:
    json.dump(manifest, f, indent=2)
"
}

finish() {
  if [ "$STATUS" = "success" ]; then
    log "Creating zip archive..."
    (cd "$RUNS_DIR" && zip -qr "$RUN_ID.zip" "$RUN_ID/")

    if unzip -t "$ZIP_FILE" >/dev/null 2>&1; then
      write_manifest
      cp "$MANIFEST_FILE" "$SIDECAR_MANIFEST"
      log "Backup archived: $ZIP_FILE ($(du -sh "$ZIP_FILE" | cut -f1))"
      rm -rf "$RUN_DIR"
    else
      log "ERROR: Zip verification failed, keeping directory"
      write_manifest
      cp "$MANIFEST_FILE" "$SIDECAR_MANIFEST"
    fi
  else
    write_manifest
    cp "$MANIFEST_FILE" "$SIDECAR_MANIFEST"
    log "Backup failed, partial data removed"
    rm -rf "$RUN_DIR"
  fi
}
trap finish EXIT

exec > >(tee -a "$STDOUT_LOG") 2> >(tee -a "$STDERR_LOG" >&2)

sync_snapshot() {
  local name="$1"
  local remote_path="$2"
  local local_component="$3"

  local dest="$DATA_DIR/$local_component"
  mkdir -p "$dest"

  local args=(-az --delete --rsync-path="sudo rsync")

  log "Syncing $name..."
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

    rm -f "$RUNS_DIR/$run.zip"
    rm -f "$RUNS_DIR/$run.manifest.json"
    rm -rf "$RUNS_DIR/$run"
    log "Removed old run: $run"
  done < <(
    {
      find "$RUNS_DIR" -maxdepth 1 -name "20*.zip" -exec basename {} .zip \; 2>/dev/null
      find "$RUNS_DIR" -maxdepth 1 -name "20*.manifest.json" -exec basename {} .manifest.json \; 2>/dev/null
      find "$RUNS_DIR" -maxdepth 1 -mindepth 1 -type d -name "20*" -exec basename {} \; 2>/dev/null
    } | sort -ru
  )
}

log "=== Prodbox sandbox backup started: $RUN_ID ==="

sync_snapshot "brain-sandbox/apps" "/home/brain-sandbox/apps/" "apps"
sync_snapshot "brain-sandbox/upload_images" "/home/brain-sandbox/upload_images/" "upload-images"
sync_snapshot "brain-sandbox/skills" "/home/brain-sandbox/skills/" "skills"
sync_snapshot "brain-data" "/var/www/brain-data/" "brain-data"

log "Keeping newest $RETENTION_COUNT backup runs..."
cleanup_old_runs

STATUS="success"
log "=== Prodbox sandbox backup completed: $RUN_ID ==="
