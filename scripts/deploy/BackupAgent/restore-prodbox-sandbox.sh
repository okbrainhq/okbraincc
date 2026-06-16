#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="arunoda@prodbox-sandbox.local"
BACKUP_ROOT="${OKBRAINCC_BACKUP_ROOT:-$HOME/okbraincc-backups/prodbox-sandbox}"
RUNS_DIR="$BACKUP_ROOT/runs"
REMOTE_APPS="/home/brain-sandbox/apps/"
REMOTE_IMAGES="/home/brain-sandbox/upload_images/"
REMOTE_SKILLS="/home/brain-sandbox/skills/"
REMOTE_BRAIN_DATA="/var/www/brain-data/"

RUN_ID=""
FILTER=""
ASSUME_YES="0"

for arg in "$@"; do
  case "$arg" in
    --yes)
      ASSUME_YES="1"
      ;;
    --apps-only|--images-only|--skills-only|--data-only)
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

resolve_run_dir

DATA_ROOT="$RUN_DIR/data"
APPS_DIR="$DATA_ROOT/apps"
IMAGES_DIR="$DATA_ROOT/upload-images"
SKILLS_DIR="$DATA_ROOT/skills"
BRAIN_DATA_DIR="$DATA_ROOT/brain-data"

MISSING=()
if selected "--apps-only" && [ ! -d "$APPS_DIR" ]; then MISSING+=("apps: $APPS_DIR"); fi
if selected "--images-only" && [ ! -d "$IMAGES_DIR" ]; then MISSING+=("upload images: $IMAGES_DIR"); fi
if selected "--skills-only" && [ ! -d "$SKILLS_DIR" ]; then MISSING+=("skills: $SKILLS_DIR"); fi
if selected "--data-only" && [ ! -d "$BRAIN_DATA_DIR" ]; then MISSING+=("brain-data: $BRAIN_DATA_DIR"); fi

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "Error: Missing backup components for $RUN_ID:"
  for item in "${MISSING[@]}"; do
    echo "  - $item"
  done
  exit 1
fi

echo "=== Restore prodbox-sandbox from $RUN_ID ==="
if selected "--apps-only"; then echo "  - apps: $APPS_DIR/ -> $REMOTE_APPS"; fi
if selected "--images-only"; then echo "  - upload_images: $IMAGES_DIR/ -> $REMOTE_IMAGES"; fi
if selected "--skills-only"; then echo "  - skills: $SKILLS_DIR/ -> $REMOTE_SKILLS"; fi
if selected "--data-only"; then echo "  - brain-data: $BRAIN_DATA_DIR/ -> $REMOTE_BRAIN_DATA"; fi

if [ "$ASSUME_YES" != "1" ]; then
  echo ""
  echo "WARNING: This will overwrite current data on prodbox-sandbox."
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
  local chown_target="${4:-}"

  if [ ! -d "$source_dir" ]; then
    echo "Skipping $title restore: $source_dir not found"
    return
  fi

  echo "Restoring $title..."
  rsync -az --delete --rsync-path="sudo rsync" "$source_dir/" "$REMOTE_HOST:$destination"

  if [ -n "$chown_target" ]; then
    ssh "$REMOTE_HOST" "sudo chown -R brain-sandbox:brain-sandbox '$chown_target'"
  fi

  echo "$title restored."
}

if selected "--apps-only"; then
  restore_directory "apps" "$APPS_DIR" "$REMOTE_APPS" "/home/brain-sandbox/apps/"
fi

if selected "--images-only"; then
  restore_directory "upload_images" "$IMAGES_DIR" "$REMOTE_IMAGES" "/home/brain-sandbox/upload_images/"
fi

if selected "--skills-only"; then
  restore_directory "skills" "$SKILLS_DIR" "$REMOTE_SKILLS" "/home/brain-sandbox/skills/"
fi

if selected "--data-only"; then
  restore_directory "brain-data" "$BRAIN_DATA_DIR" "$REMOTE_BRAIN_DATA"
fi

echo ""
echo "=== Restore completed ==="
