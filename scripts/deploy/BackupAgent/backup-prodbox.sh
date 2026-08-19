#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="${OKBRAINCC_BACKUP_REMOTE_HOST:-arunoda@prodbox.local}"
BACKUP_ROOT="${OKBRAINCC_BACKUP_ROOT:-$HOME/okbraincc-backups/prodbox}"
RUNS_DIR="$BACKUP_ROOT/runs"
RETENTION_COUNT="${OKBRAINCC_BACKUP_RETENTION_COUNT:-30}"

if ! [[ "$RETENTION_COUNT" =~ ^[0-9]+$ ]] || [ "$RETENTION_COUNT" -lt 1 ]; then
  RETENTION_COUNT=30
fi

REMOTE_DB="/var/www/brain/brain.db"
# Staging dir for the remote temp DB copy. MUST be a persistent filesystem:
# /tmp is a quota-controlled tmpfs (usrquota) and was the root cause of the
# Aug 2026 production outage (EDQUOT / errno -122). /var/www/brain is proven
# writable by the backup user. Override via env var if needed, e.g.
# OKBRAINCC_BACKUP_REMOTE_STAGING=/mnt/okrun/brain-backup-tmp
REMOTE_STAGING="${OKBRAINCC_BACKUP_REMOTE_STAGING:-/var/www/brain/backup-tmp}"
# Abort if a leftover temp backup is younger than this (possible concurrent run).
STALE_MAX_AGE_MIN="${OKBRAINCC_BACKUP_STALE_MAX_AGE_MIN:-60}"
# Minimum free space margin (MiB) required beyond the DB size in the staging dir.
SPACE_MARGIN_MB="${OKBRAINCC_BACKUP_SPACE_MARGIN_MB:-512}"
# Lock staleness threshold (min). Independent of STALE_MAX_AGE_MIN: must exceed
# the max expected backup duration so a long-running backup's lock is never
# reclaimed mid-run. Fresh temp .db files are the primary concurrency guard.
LOCK_STALE_MAX_AGE_MIN="${OKBRAINCC_BACKUP_LOCK_STALE_MAX_AGE_MIN:-180}"

if ! [[ "$STALE_MAX_AGE_MIN" =~ ^[0-9]+$ ]] || [ "$STALE_MAX_AGE_MIN" -lt 1 ]; then
  STALE_MAX_AGE_MIN=60
fi
if ! [[ "$SPACE_MARGIN_MB" =~ ^[0-9]+$ ]] || [ "$SPACE_MARGIN_MB" -lt 1 ]; then
  SPACE_MARGIN_MB=512
fi
if ! [[ "$LOCK_STALE_MAX_AGE_MIN" =~ ^[0-9]+$ ]] || [ "$LOCK_STALE_MAX_AGE_MIN" -lt 1 ]; then
  LOCK_STALE_MAX_AGE_MIN=180
fi

RUN_ID_BASE="$(date +%Y-%m-%d-%H%M)"
RUN_ID="${OKBRAINCC_BACKUP_RUN_ID:-$RUN_ID_BASE}"
if [ -e "$RUNS_DIR/$RUN_ID" ] || [ -e "$RUNS_DIR/$RUN_ID.zip" ]; then
  RUN_ID="$RUN_ID_BASE-$(date +%S)"
fi
# Owner token written inside the remote lock dir; release only succeeds when it matches.
LOCK_OWNER_TOKEN="$$-$(hostname -s)-$RUN_ID"

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

mkdir -p "$DATA_DIR/db"
mkdir -p "$DATA_DIR/brain-data"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# --- Remote DB backup helpers (RCA fix: no /tmp, guaranteed cleanup) ---
remote_cmd() {
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$REMOTE_HOST" "$@"
}

cleanup_remote_backup() {
  # Always rm -f (no test -e guard) so orphan -journal/-wal/-shm sidecars are
  # removed even when the .db itself is already absent.
  if [ -n "${REMOTE_BACKUP:-}" ]; then
    if remote_cmd "rm -f '$REMOTE_BACKUP' '$REMOTE_BACKUP-journal' '$REMOTE_BACKUP-wal' '$REMOTE_BACKUP-shm'"; then
      log "Remote temp file cleaned up: $REMOTE_BACKUP"
    else
      log "WARNING: Could not remove remote temp file: $REMOTE_BACKUP"
    fi
    REMOTE_BACKUP=""
  fi
}

release_remote_lock() {
  # Token-checked release: only remove the lock if the owner token inside it
  # matches ours. Prevents a stale-reclaimed (still running) process from
  # removing the new owner's lock via a path-only rmdir.
  if [ -n "${REMOTE_LOCK_DIR:-}" ]; then
    if remote_cmd "grep -qx '$LOCK_OWNER_TOKEN' '$REMOTE_LOCK_DIR/owner' 2>/dev/null && rm -f '$REMOTE_LOCK_DIR/owner' && rmdir '$REMOTE_LOCK_DIR' 2>/dev/null"; then
      log "Remote backup lock released: $REMOTE_LOCK_DIR"
    else
      log "WARNING: Lock '$REMOTE_LOCK_DIR' not ours (or already gone) — not removing."
    fi
    REMOTE_LOCK_DIR=""
  fi
}

on_exit() {
  cleanup_remote_backup || true
  release_remote_lock || true
  finish
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

  MANIFEST_SYSTEM="prodbox" \
  MANIFEST_RUN_ID="$RUN_ID" \
  MANIFEST_STATUS="$STATUS" \
  MANIFEST_STARTED_AT="$STARTED_AT" \
  MANIFEST_FINISHED_AT="$finished_at" \
  MANIFEST_REMOTE_HOST="$REMOTE_HOST" \
  MANIFEST_ZIP_FILE="$RUN_ID.zip" \
  MANIFEST_ZIP_SIZE_BYTES="$zip_size_bytes" \
  MANIFEST_DB_SIZE="$(component_size "$DATA_DIR/db/brain.db")" \
  MANIFEST_DB_EXISTS="$([ -f "$DATA_DIR/db/brain.db" ] && echo true || echo false)" \
  MANIFEST_BRAIN_DATA_SIZE="$(component_size "$DATA_DIR/brain-data")" \
  MANIFEST_BRAIN_DATA_EXISTS="$([ -d "$DATA_DIR/brain-data" ] && echo true || echo false)" \
  MANIFEST_SANDBOX_APPS_SIZE="$(component_size "$DATA_DIR/brain-sandbox/apps")" \
  MANIFEST_SANDBOX_APPS_EXISTS="$([ -d "$DATA_DIR/brain-sandbox/apps" ] && echo true || echo false)" \
  MANIFEST_SANDBOX_SKILLS_SIZE="$(component_size "$DATA_DIR/brain-sandbox/skills")" \
  MANIFEST_SANDBOX_SKILLS_EXISTS="$([ -d "$DATA_DIR/brain-sandbox/skills" ] && echo true || echo false)" \
  MANIFEST_SANDBOX_IMAGES_SIZE="$(component_size "$DATA_DIR/brain-sandbox/upload-images")" \
  MANIFEST_SANDBOX_IMAGES_EXISTS="$([ -d "$DATA_DIR/brain-sandbox/upload-images" ] && echo true || echo false)" \
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
            'id': 'db',
            'title': 'Database',
            'relative_path': 'data/db/brain.db',
            'size': os.environ['MANIFEST_DB_SIZE'],
            'exists': os.environ['MANIFEST_DB_EXISTS'] == 'true'
        },
        {
            'id': 'brain-data',
            'title': 'Brain Data',
            'relative_path': 'data/brain-data',
            'size': os.environ['MANIFEST_BRAIN_DATA_SIZE'],
            'exists': os.environ['MANIFEST_BRAIN_DATA_EXISTS'] == 'true'
        },
        {
            'id': 'brain-sandbox',
            'title': 'Sandbox Apps',
            'relative_path': 'data/brain-sandbox/apps',
            'size': os.environ['MANIFEST_SANDBOX_APPS_SIZE'],
            'exists': os.environ['MANIFEST_SANDBOX_APPS_EXISTS'] == 'true'
        },
        {
            'id': 'brain-sandbox-skills',
            'title': 'Sandbox Skills',
            'relative_path': 'data/brain-sandbox/skills',
            'size': os.environ['MANIFEST_SANDBOX_SKILLS_SIZE'],
            'exists': os.environ['MANIFEST_SANDBOX_SKILLS_EXISTS'] == 'true'
        },
        {
            'id': 'brain-sandbox-upload-images',
            'title': 'Sandbox Images',
            'relative_path': 'data/brain-sandbox/upload-images',
            'size': os.environ['MANIFEST_SANDBOX_IMAGES_SIZE'],
            'exists': os.environ['MANIFEST_SANDBOX_IMAGES_EXISTS'] == 'true'
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
trap on_exit EXIT

exec > >(tee -a "$STDOUT_LOG") 2> >(tee -a "$STDERR_LOG" >&2)

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

log "=== Backup started: $RUN_ID ==="

check_remote_staging() {
  log "Preparing remote staging dir: $REMOTE_STAGING"
  if ! remote_cmd "mkdir -p '$REMOTE_STAGING'"; then
    log "ERROR: Cannot create remote staging dir '$REMOTE_STAGING'. Aborting backup."
    exit 1
  fi

  local fs_type
  fs_type="$(remote_cmd "findmnt -n -o FSTYPE -T '$REMOTE_STAGING' 2>/dev/null || echo unknown")" || fs_type="unknown"
  log "Remote staging filesystem type: $fs_type"
  if [ "$fs_type" = "tmpfs" ]; then
    log "ERROR: Staging dir '$REMOTE_STAGING' is on tmpfs (quota-controlled). Set OKBRAINCC_BACKUP_REMOTE_STAGING to a persistent filesystem. Aborting."
    exit 1
  fi

  if ! remote_cmd "touch '$REMOTE_STAGING/.okbraincc-write-test' && rm -f '$REMOTE_STAGING/.okbraincc-write-test'"; then
    log "ERROR: Staging dir '$REMOTE_STAGING' is not writable. Aborting backup."
    exit 1
  fi
}

acquire_remote_lock() {
  local lock_dir="$REMOTE_STAGING/.backup.lock"
  # Atomic lock: mkdir succeeds for exactly one run. REMOTE_LOCK_DIR is set
  # ONLY on successful acquisition so on_exit never releases a lock we don't own.
  if remote_cmd "mkdir '$lock_dir' 2>/dev/null"; then
    REMOTE_LOCK_DIR="$lock_dir"
    remote_cmd "echo '$LOCK_OWNER_TOKEN' > '$lock_dir/owner'" || true
    log "Remote backup lock acquired: $lock_dir"
    return 0
  fi
  # Lock exists — stale (older than LOCK_STALE_MAX_AGE_MIN) locks can be reclaimed.
  if [ -n "$(remote_cmd "find '$lock_dir' -maxdepth 1 -mmin +$LOCK_STALE_MAX_AGE_MIN 2>/dev/null | head -1" || true)" ]; then
    # An active long backup may have aged past the lock threshold: if its temp
    # .db is still fresh, back off instead of stripping its lock mid-write.
    if [ -n "$(remote_cmd "find '$REMOTE_STAGING' -maxdepth 1 -name 'prodbox-backup-*.db' -mmin -$STALE_MAX_AGE_MIN 2>/dev/null | head -1" || true)" ]; then
      log "ERROR: Lock is stale but a fresh temp backup exists — another backup appears active. Aborting."
      exit 1
    fi
    log "WARNING: Reclaiming stale backup lock (older than ${LOCK_STALE_MAX_AGE_MIN}min): $lock_dir"
    # Atomic reclaim: move the old lock aside first (only one reclaimer wins the
    # mv), verify what we moved is genuinely stale, then mkdir the real lock.
    # This prevents two reclaimers from deleting each other's fresh locks.
    local stale_path="$lock_dir.stale.$$"
    if remote_cmd "mv '$lock_dir' '$stale_path' 2>/dev/null"; then
      if [ -n "$(remote_cmd "find '$stale_path' -maxdepth 1 -mmin +$LOCK_STALE_MAX_AGE_MIN 2>/dev/null | head -1" || true)" ]; then
        # Genuinely stale — safe to discard.
        remote_cmd "rm -rf '$stale_path'" || log "WARNING: Could not remove stale lock artifact '$stale_path'"
      else
        # We moved someone's FRESH lock (race) — restore it and back off.
        remote_cmd "mv '$stale_path' '$lock_dir' 2>/dev/null" || true
        log "ERROR: Lock race — another backup holds '$lock_dir'. Aborting backup."
        exit 1
      fi
    else
      log "  (another run reclaimed the stale lock first)"
    fi
    if remote_cmd "mkdir '$lock_dir' 2>/dev/null"; then
      REMOTE_LOCK_DIR="$lock_dir"
      remote_cmd "echo '$LOCK_OWNER_TOKEN' > '$lock_dir/owner'" || true
      log "Remote backup lock acquired (stale lock reclaimed): $lock_dir"
      return 0
    fi
    log "ERROR: Lock race — another backup acquired '$lock_dir'. Aborting backup."
    exit 1
  fi
  log "ERROR: Another backup appears to be running (lock '$lock_dir' is fresh). Aborting backup."
  exit 1
}

check_stale_backups() {
  local fresh stale
  fresh="$(remote_cmd "find '$REMOTE_STAGING' -maxdepth 1 -name 'prodbox-backup-*.db' -mmin -$STALE_MAX_AGE_MIN 2>/dev/null || true")" || fresh=""
  if [ -n "$fresh" ]; then
    log "ERROR: Fresh temp backup(s) found in $REMOTE_STAGING (younger than ${STALE_MAX_AGE_MIN}min). Another backup may be running:"
    log "  $fresh"
    exit 1
  fi

  stale="$(remote_cmd "find '$REMOTE_STAGING' -maxdepth 1 -name 'prodbox-backup-*.db' 2>/dev/null || true")" || stale=""
  if [ -n "$stale" ]; then
    log "Removing stale temp backup(s) from $REMOTE_STAGING:"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      log "  $f"
      remote_cmd "rm -f '$f' '$f-journal' '$f-wal' '$f-shm'" || log "WARNING: Could not remove stale file $f"
    done <<< "$stale"
  else
    log "No stale temp backups in $REMOTE_STAGING"
  fi

  # Remove orphan sidecars (-journal/-wal/-shm) whose .db is already gone.
  local orphans
  orphans="$(remote_cmd "find '$REMOTE_STAGING' -maxdepth 1 -name 'prodbox-backup-*.db-*' 2>/dev/null || true")" || orphans=""
  if [ -n "$orphans" ]; then
    log "Removing orphan sidecar file(s):"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      log "  $f"
      remote_cmd "rm -f '$f'" || log "WARNING: Could not remove orphan file $f"
    done <<< "$orphans"
  fi

  # Remove abandoned stale-lock artifacts left by crashed reclaimers (only when
  # old enough that no reclaim is plausibly in flight).
  local stale_locks
  stale_locks="$(remote_cmd "find '$REMOTE_STAGING' -maxdepth 1 -name '.backup.lock.stale.*' -mmin +$LOCK_STALE_MAX_AGE_MIN 2>/dev/null || true")" || stale_locks=""
  if [ -n "$stale_locks" ]; then
    log "Removing abandoned stale-lock artifact(s):"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      log "  $f"
      remote_cmd "rm -rf '$f'" || log "WARNING: Could not remove stale-lock artifact $f"
    done <<< "$stale_locks"
  fi
}

check_backup_space() {
  local db_bytes avail_kb avail_bytes needed_bytes
  db_bytes="$(remote_cmd "stat -c %s '$REMOTE_DB' 2>/dev/null || echo 0")" || db_bytes="0"
  avail_kb="$(remote_cmd "df -Pk '$REMOTE_STAGING' 2>/dev/null | tail -1 | tr -s ' ' | cut -d' ' -f4")" || avail_kb="0"
  avail_bytes=$((avail_kb * 1024))
  needed_bytes=$((db_bytes + SPACE_MARGIN_MB * 1024 * 1024))
  log "Space check - DB: $((db_bytes / 1024 / 1024)) MiB | staging available: $((avail_bytes / 1024 / 1024)) MiB | required: $((needed_bytes / 1024 / 1024)) MiB"
  if [ "$avail_bytes" -lt "$needed_bytes" ]; then
    log "ERROR: Not enough free space in '$REMOTE_STAGING' (need at least $((needed_bytes / 1024 / 1024)) MiB, have $((avail_bytes / 1024 / 1024)) MiB). Aborting backup."
    exit 1
  fi
}

REMOTE_BACKUP="$REMOTE_STAGING/prodbox-backup-$(date +%s)-$$.db"
LOCAL_DB="$DATA_DIR/db/brain.db"

check_remote_staging
acquire_remote_lock
check_stale_backups
check_backup_space

log "Creating sqlite3 backup on remote..."
remote_cmd "sqlite3 '$REMOTE_DB' \".backup '$REMOTE_BACKUP'\"" || {
  log "ERROR: sqlite3 .backup failed on remote. Aborting."
  exit 1
}

REMOTE_BACKUP_SIZE="$(remote_cmd "stat -c %s '$REMOTE_BACKUP' 2>/dev/null || echo 0")" || REMOTE_BACKUP_SIZE="0"
log "Remote temp backup created: $REMOTE_BACKUP ($((REMOTE_BACKUP_SIZE / 1024 / 1024)) MiB)"

log "Downloading database backup..."
scp "$REMOTE_HOST:$REMOTE_BACKUP" "$LOCAL_DB"

cleanup_remote_backup

log "Database backup saved: $LOCAL_DB ($(du -h "$LOCAL_DB" | cut -f1))"

sync_snapshot "brain-data" "/var/www/brain-data/" "brain-data"

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
