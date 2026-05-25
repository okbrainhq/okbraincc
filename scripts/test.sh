#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="OkBrainCC"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
BACKUP_AGENT_DIR="$APP_BUNDLE/Contents/Resources/BackupAgent"

"$ROOT_DIR/scripts/build.sh" >/dev/null

test -d "$APP_BUNDLE"
test -x "$APP_BINARY"
test -f "$INFO_PLIST"
test -f "$BACKUP_AGENT_DIR/backup-prodbox.sh"
test -f "$BACKUP_AGENT_DIR/backup-prodbox-sandbox.sh"
test -f "$BACKUP_AGENT_DIR/restore-prodbox.sh"
test -f "$BACKUP_AGENT_DIR/restore-prodbox-sandbox.sh"
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null

echo "Tests passed"
