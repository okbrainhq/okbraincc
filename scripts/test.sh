#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BASENAME="OkBrainCC"
DEV_APP_NAME="${APP_BASENAME}-Dev"
PROD_APP_NAME="$APP_BASENAME"
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
    pkill -x "$DEV_APP_NAME" >/dev/null 2>&1 || true
    pkill -x "$PROD_APP_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

section() {
  printf '\n==> %s\n' "$1"
}

verify_bundle() {
  local app_name="$1"
  local bundle_id="$2"
  local app_bundle="$ROOT_DIR/dist/$app_name.app"
  local app_binary="$app_bundle/Contents/MacOS/$app_name"
  local info_plist="$app_bundle/Contents/Info.plist"
  local app_icon="$app_bundle/Contents/Resources/$app_name.icns"
  local backup_agent_dir="$app_bundle/Contents/Resources/BackupAgent"
  local deploy_backup_agent_dir="$ROOT_DIR/scripts/deploy/BackupAgent"

  test -d "$app_bundle"
  test -x "$app_binary"
  test -f "$info_plist"
  test -f "$app_icon"
  test -f "$backup_agent_dir/backup-prodbox.sh"
  test -f "$backup_agent_dir/backup-prodbox-sandbox.sh"
  test -f "$backup_agent_dir/restore-prodbox.sh"
  test -f "$backup_agent_dir/restore-prodbox-sandbox.sh"
  cmp "$deploy_backup_agent_dir/backup-prodbox.sh" "$backup_agent_dir/backup-prodbox.sh"
  cmp "$deploy_backup_agent_dir/backup-prodbox-sandbox.sh" "$backup_agent_dir/backup-prodbox-sandbox.sh"
  cmp "$deploy_backup_agent_dir/restore-prodbox.sh" "$backup_agent_dir/restore-prodbox.sh"
  cmp "$deploy_backup_agent_dir/restore-prodbox-sandbox.sh" "$backup_agent_dir/restore-prodbox-sandbox.sh"
  /usr/bin/plutil -lint "$info_plist" >/dev/null
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info_plist")" = "$app_name"
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" = "$bundle_id"
  test "$(/usr/libexec/PlistBuddy -c 'Print :AppEnvironment' "$info_plist")" = "${3:-}"
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
swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  "$ROOT_DIR/Sources/OkBrainCC/Support/AppEnvironment.swift" \
  "$ROOT_DIR/Sources/OkBrainCC/Models/BackupModels.swift" \
  "$SCHEDULER_TEST_DIR/main.swift" \
  -o "$SCHEDULER_TEST_DIR/verify_scheduler"
"$SCHEDULER_TEST_DIR/verify_scheduler"

section "Shell syntax checks"
while IFS= read -r script; do
  bash -n "$script"
done < <(find "$ROOT_DIR/scripts" -type f -name '*.sh' | sort)

section "Dev app bundle build"
"$ROOT_DIR/scripts/build.sh" --dev >/dev/null

section "Backup deploy scripts"
test ! -e "$ROOT_DIR/Sources/OkBrainCC/Resources/BackupAgent"
test -f "$ROOT_DIR/scripts/deploy/BackupAgent/backup-prodbox.sh"
test -f "$ROOT_DIR/scripts/deploy/BackupAgent/backup-prodbox-sandbox.sh"
test -f "$ROOT_DIR/scripts/deploy/BackupAgent/restore-prodbox.sh"
test -f "$ROOT_DIR/scripts/deploy/BackupAgent/restore-prodbox-sandbox.sh"

section "Dev app bundle contents"
verify_bundle "$DEV_APP_NAME" "com.okbraincc.app.dev" "dev"

section "Prod app bundle build"
"$ROOT_DIR/scripts/build.sh" --prod >/dev/null

section "Prod app bundle contents"
verify_bundle "$PROD_APP_NAME" "com.okbraincc.app" "prod"

section "Mock dev app launch via run.sh"
pkill -x "$DEV_APP_NAME" >/dev/null 2>&1 || true
"$ROOT_DIR/scripts/run.sh" --mock-verify --dev
MOCK_APP_STARTED="1"

section "Mock prod app launch via run.sh"
pkill -x "$PROD_APP_NAME" >/dev/null 2>&1 || true
"$ROOT_DIR/scripts/run.sh" --mock-verify --prod
MOCK_APP_STARTED="1"

echo "Tests passed"
