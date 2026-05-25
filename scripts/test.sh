#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="OkBrainCC"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

"$ROOT_DIR/scripts/build.sh" >/dev/null

test -d "$APP_BUNDLE"
test -x "$APP_BINARY"
test -f "$INFO_PLIST"
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null

echo "Tests passed"
