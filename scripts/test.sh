#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="OkBrainCC"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_ICON="$APP_BUNDLE/Contents/Resources/$APP_NAME.icns"
BACKUP_AGENT_DIR="$APP_BUNDLE/Contents/Resources/BackupAgent"
DEPLOY_BACKUP_AGENT_DIR="$ROOT_DIR/scripts/deploy/BackupAgent"
SCHEDULER_TEST_DIR="$(mktemp -d)"
MOCK_APP_STARTED="0"
TEST_HOME="$ROOT_DIR/.build/test-home"
SWIFTPM_CACHE="$ROOT_DIR/.build/swiftpm-cache"
SWIFTPM_FLAGS=(--disable-sandbox --cache-path "$SWIFTPM_CACHE")

export HOME="$TEST_HOME"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
mkdir -p "$HOME"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
mkdir -p "$SWIFTPM_CACHE"

cleanup() {
  rm -rf "$SCHEDULER_TEST_DIR"
  if [ "$MOCK_APP_STARTED" = "1" ]; then
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

section() {
  printf '\n==> %s\n' "$1"
}

section "Swift package build"
swift build "${SWIFTPM_FLAGS[@]}" >/dev/null

section "Swift package tests"
if [ -d "$ROOT_DIR/Tests" ] && find "$ROOT_DIR/Tests" -type f -name '*.swift' | grep -q .; then
  swift test "${SWIFTPM_FLAGS[@]}"
else
  echo "No SwiftPM test target found; skipping swift test."
fi

section "Backup scheduler verification"
cp "$ROOT_DIR/scripts/verify_scheduler.swift" "$SCHEDULER_TEST_DIR/main.swift"
swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" "$ROOT_DIR/Sources/OkBrainCC/Models/BackupModels.swift" "$SCHEDULER_TEST_DIR/main.swift" -o "$SCHEDULER_TEST_DIR/verify_scheduler"
"$SCHEDULER_TEST_DIR/verify_scheduler"

section "Shell syntax checks"
while IFS= read -r script; do
  bash -n "$script"
done < <(find "$ROOT_DIR/scripts" -type f -name '*.sh' | sort)

section "App bundle build"
"$ROOT_DIR/scripts/build.sh" >/dev/null

section "Backup deploy scripts"
test ! -e "$ROOT_DIR/Sources/OkBrainCC/Resources/BackupAgent"
test -f "$DEPLOY_BACKUP_AGENT_DIR/backup-prodbox.sh"
test -f "$DEPLOY_BACKUP_AGENT_DIR/backup-prodbox-sandbox.sh"
test -f "$DEPLOY_BACKUP_AGENT_DIR/restore-prodbox.sh"
test -f "$DEPLOY_BACKUP_AGENT_DIR/restore-prodbox-sandbox.sh"

section "App bundle contents"
test -d "$APP_BUNDLE"
test -x "$APP_BINARY"
test -f "$INFO_PLIST"
test -f "$APP_ICON"
test -f "$BACKUP_AGENT_DIR/backup-prodbox.sh"
test -f "$BACKUP_AGENT_DIR/backup-prodbox-sandbox.sh"
test -f "$BACKUP_AGENT_DIR/restore-prodbox.sh"
test -f "$BACKUP_AGENT_DIR/restore-prodbox-sandbox.sh"
cmp "$DEPLOY_BACKUP_AGENT_DIR/backup-prodbox.sh" "$BACKUP_AGENT_DIR/backup-prodbox.sh"
cmp "$DEPLOY_BACKUP_AGENT_DIR/backup-prodbox-sandbox.sh" "$BACKUP_AGENT_DIR/backup-prodbox-sandbox.sh"
cmp "$DEPLOY_BACKUP_AGENT_DIR/restore-prodbox.sh" "$BACKUP_AGENT_DIR/restore-prodbox.sh"
cmp "$DEPLOY_BACKUP_AGENT_DIR/restore-prodbox-sandbox.sh" "$BACKUP_AGENT_DIR/restore-prodbox-sandbox.sh"
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$INFO_PLIST")" = "$APP_NAME.icns"

section "Mock app launch"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
/usr/bin/open -n "$APP_BUNDLE" --args --mock-backups
MOCK_APP_STARTED="1"
sleep 1
pgrep -x "$APP_NAME" >/dev/null
ps -p "$(pgrep -x "$APP_NAME" | head -1)" -o command= | grep -q -- "--mock-backups"

echo "Tests passed"
