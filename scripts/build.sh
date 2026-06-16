#!/usr/bin/env bash
set -euo pipefail

APP_BASENAME="OkBrainCC"
BUNDLE_ID_PROD="com.okbraincc.app"
BUNDLE_ID_DEV="com.okbraincc.app.dev"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
SWIFTPM_CACHE="$ROOT_DIR/.build/swiftpm-cache"
SWIFTPM_FLAGS=(--disable-sandbox --cache-path "$SWIFTPM_CACHE")
BACKUP_AGENT_SOURCE="$ROOT_DIR/scripts/deploy/BackupAgent"
MENU_BAR_SYMBOL="brain.head.profile"

ENV="dev"
for arg in "$@"; do
  case "$arg" in
    --prod) ENV="prod" ;;
    --dev)  ENV="dev" ;;
  esac
done

if [[ "$ENV" == "dev" ]]; then
  APP_NAME="${APP_BASENAME}-Dev"
  PLIST="$ROOT_DIR/Info-Dev.plist"
  BUNDLE_ID="$BUNDLE_ID_DEV"
else
  APP_NAME="$APP_BASENAME"
  PLIST="$ROOT_DIR/Info.plist"
  BUNDLE_ID="$BUNDLE_ID_PROD"
fi

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_NAME="$APP_NAME"
APP_ICON="$APP_RESOURCES/$APP_ICON_NAME.icns"

cd "$ROOT_DIR"
mkdir -p "$SWIFTPM_CACHE"
swift build "${SWIFTPM_FLAGS[@]}"
BUILD_BINARY="$(swift build "${SWIFTPM_FLAGS[@]}" --show-bin-path)/$APP_BASENAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp -R "$BACKUP_AGENT_SOURCE" "$APP_RESOURCES/BackupAgent"
/usr/bin/swift "$ROOT_DIR/scripts/generate_app_icon.swift" "$APP_ICON" "$MENU_BAR_SYMBOL"

cp "$PLIST" "$INFO_PLIST"

# Ensure the executable name and bundle identifier match the chosen environment.
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$INFO_PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST" >/dev/null

export CODE_SIGNING_ALLOWED=NO
export CODE_SIGN_IDENTITY="-"
codesign --force --sign - --timestamp=none "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "Built $APP_BUNDLE (env=$ENV)"
