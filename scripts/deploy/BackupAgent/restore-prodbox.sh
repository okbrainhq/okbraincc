#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="arunoda@prodbox.local"
BACKUP_ROOT="$HOME/okbraincc-backups/prodbox"
RUNS_DIR="$BACKUP_ROOT/runs"
REMOTE_DB="/var/www/brain/brain.db"
REMOTE_DATA="/var/www/brain-data/"
REMOTE_UPLOADS="/var/www/brain-data/uploads/"
REMOTE_SANDBOX_APPS="/home/brain-sandbox/apps/"
REMOTE_SANDBOX_SKILLS="/home/brain-sandbox/skills/"
REMOTE_SANDBOX_IMAGES="/home/brain-sandbox/upload_images/"
APP_NAME="brain"
APP_STOPPED="0"

RUN_ID=""
FILTER=""
ASSUME_YES="0"

restart_app() {
  local exit_status=$?

  if [ "$APP_STOPPED" != "1" ]; then
    return "$exit_status"
  fi

  echo ""
  echo "Starting brain app on remote..."
  set +e
  ssh "$REMOTE_HOST" "sudo systemctl start $APP_NAME"
  local start_status=$?
  set -e

  APP_STOPPED="0"
  if [ "$start_status" -ne 0 ]; then
    return "$start_status"
  fi

  return "$exit_status"
}

trap restart_app EXIT

for arg in "$@"; do
  case "$arg" in
    --yes)
      ASSUME_YES="1"
      ;;
    --db-only|--data-only|--uploads-only|--sandbox-only|--sandbox-skills-only|--sandbox-images-only)
      FILTER="$arg"
      ;;
    *)
      RUN_ID="$arg"
      ;;
  esac
done

resolve_run_dir() {
  if [ -z "$RUN_ID" ]; then
    if [ ! -d "$RUNS_DIR" ]; then
      echo "Error: No backup runs found. Specify a run id."
      exit 1
    fi

    RUN_ID="$(find "$RUNS_DIR" -maxdepth 1 -mindepth 1 -type d -name "20*" -exec basename {} \; | sort -r | sed -n '1p')"
    if [ -z "$RUN_ID" ]; then
      echo "Error: No backup runs found. Specify a run id."
      exit 1
    fi
  fi

  RUN_DIR="$RUNS_DIR/$RUN_ID"

  if [ ! -d "$RUN_DIR" ]; then
    echo "Error: Backup run not found: $RUN_DIR"
    echo ""
    echo "Available backup runs:"
    find "$RUNS_DIR" -maxdepth 1 -mindepth 1 -type d -name "20*" -exec basename {} \; 2>/dev/null | sort -r | head -20 || true
    exit 1
  fi

  RUN_ID="$(basename "$RUN_DIR")"
}

selected() {
  [ -z "$FILTER" ] || [ "$FILTER" = "$1" ]
}

directory_has_entries() {
  find "$1" -mindepth 1 -maxdepth 1 -print -quit | grep -q .
}

resolve_run_dir

DATA_ROOT="$RUN_DIR/data"
DB_FILE="$DATA_ROOT/db/brain.db"
DATA_DIR="$DATA_ROOT/brain-data"
UPLOADS_DIR="$DATA_ROOT/brain-uploads"
SANDBOX_APPS_DIR="$DATA_ROOT/brain-sandbox/apps"
SANDBOX_SKILLS_DIR="$DATA_ROOT/brain-sandbox/skills"
SANDBOX_IMAGES_DIR="$DATA_ROOT/brain-sandbox/upload-images"

MISSING=()
if selected "--db-only" && [ ! -f "$DB_FILE" ]; then MISSING+=("database: $DB_FILE"); fi
if selected "--data-only" && [ ! -d "$DATA_DIR" ]; then MISSING+=("brain-data: $DATA_DIR"); fi
if selected "--uploads-only" && [ ! -d "$UPLOADS_DIR" ]; then MISSING+=("brain-uploads: $UPLOADS_DIR"); fi
if [ "$FILTER" = "--sandbox-only" ] && [ ! -d "$SANDBOX_APPS_DIR" ]; then MISSING+=("sandbox apps: $SANDBOX_APPS_DIR"); fi
if [ "$FILTER" = "--sandbox-skills-only" ] && [ ! -d "$SANDBOX_SKILLS_DIR" ]; then MISSING+=("sandbox skills: $SANDBOX_SKILLS_DIR"); fi
if [ "$FILTER" = "--sandbox-images-only" ] && [ ! -d "$SANDBOX_IMAGES_DIR" ]; then MISSING+=("sandbox images: $SANDBOX_IMAGES_DIR"); fi

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "Error: Missing backup components for $RUN_ID:"
  for item in "${MISSING[@]}"; do
    echo "  - $item"
  done
  exit 1
fi

echo "=== Restore from $RUN_ID ==="
echo "This will restore to $REMOTE_HOST:"
if selected "--db-only"; then echo "  - Database: $DB_FILE -> $REMOTE_DB"; fi
if selected "--data-only"; then echo "  - brain-data: $DATA_DIR/ -> $REMOTE_DATA"; fi
if selected "--uploads-only"; then echo "  - brain-uploads: $UPLOADS_DIR/ -> $REMOTE_UPLOADS"; fi
if selected "--sandbox-only"; then
  if [ -d "$SANDBOX_APPS_DIR" ] && directory_has_entries "$SANDBOX_APPS_DIR"; then
    echo "  - brain-sandbox/apps: $SANDBOX_APPS_DIR/ -> $REMOTE_SANDBOX_APPS"
  else
    echo "  - brain-sandbox/apps: skipped (not present in backup)"
  fi
fi
if selected "--sandbox-skills-only"; then
  if [ -d "$SANDBOX_SKILLS_DIR" ] && directory_has_entries "$SANDBOX_SKILLS_DIR"; then
    echo "  - brain-sandbox/skills: $SANDBOX_SKILLS_DIR/ -> $REMOTE_SANDBOX_SKILLS"
  else
    echo "  - brain-sandbox/skills: skipped (not present in backup)"
  fi
fi
if selected "--sandbox-images-only"; then
  if [ -d "$SANDBOX_IMAGES_DIR" ] && directory_has_entries "$SANDBOX_IMAGES_DIR"; then
    echo "  - brain-sandbox/upload_images: $SANDBOX_IMAGES_DIR/ -> $REMOTE_SANDBOX_IMAGES"
  else
    echo "  - brain-sandbox/upload_images: skipped (not present in backup)"
  fi
fi

if [ "$ASSUME_YES" != "1" ]; then
  echo ""
  echo "WARNING: This will overwrite current data on the VM."
  read -r -p "Continue? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES)
      ;;
    *)
      echo "Aborted."
      exit 0
      ;;
  esac
fi

restore_directory() {
  local title="$1"
  local source_dir="$2"
  local destination="$3"
  local rsync_path="${4:-}"
  local chown_target="${5:-}"
  local skip_empty="${6:-0}"

  if [ ! -d "$source_dir" ]; then
    echo "Skipping $title restore: $source_dir not found"
    return
  fi

  if [ "$skip_empty" = "1" ] && ! directory_has_entries "$source_dir"; then
    echo "Skipping $title restore: $source_dir is empty"
    return
  fi

  local args=(-az --delete)
  if [ -n "$rsync_path" ]; then
    args+=(--rsync-path="$rsync_path")
  fi

  echo "Restoring $title..."
  rsync "${args[@]}" "$source_dir/" "$REMOTE_HOST:$destination"

  if [ -n "$chown_target" ]; then
    ssh "$REMOTE_HOST" "sudo chown -R brain-sandbox:brain-sandbox '$chown_target'"
  fi

  echo "$title restored."
}

echo ""
echo "Stopping brain app on remote..."
ssh "$REMOTE_HOST" "sudo systemctl stop $APP_NAME"
APP_STOPPED="1"

if selected "--db-only"; then
  if [ ! -f "$DB_FILE" ]; then
    echo "Skipping DB restore: $DB_FILE not found"
  else
    echo "Uploading database ($(du -h "$DB_FILE" | cut -f1))..."
    ssh "$REMOTE_HOST" "rm -f '${REMOTE_DB}-wal' '${REMOTE_DB}-shm'"
    scp "$DB_FILE" "$REMOTE_HOST:$REMOTE_DB"
    echo "Database restored."
  fi
fi

if selected "--data-only"; then
  restore_directory "brain-data" "$DATA_DIR" "$REMOTE_DATA"
fi

if selected "--uploads-only"; then
  restore_directory "brain-uploads" "$UPLOADS_DIR" "$REMOTE_UPLOADS"
fi

if selected "--sandbox-only"; then
  restore_directory "brain-sandbox/apps" "$SANDBOX_APPS_DIR" "$REMOTE_SANDBOX_APPS" "sudo rsync" "/home/brain-sandbox/apps/" "1"
fi

if selected "--sandbox-skills-only"; then
  restore_directory "brain-sandbox/skills" "$SANDBOX_SKILLS_DIR" "$REMOTE_SANDBOX_SKILLS" "sudo rsync" "/home/brain-sandbox/skills/" "1"
fi

if selected "--sandbox-images-only"; then
  restore_directory "brain-sandbox/upload_images" "$SANDBOX_IMAGES_DIR" "$REMOTE_SANDBOX_IMAGES" "sudo rsync" "/home/brain-sandbox/upload_images/" "1"
fi

echo ""
restart_app
trap - EXIT

echo ""
echo "=== Restore completed ==="
