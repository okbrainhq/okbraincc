#!/usr/bin/env bash
set -euo pipefail

APP_BASENAME="OkBrainCC"
BUNDLE_ID_PROD="com.okbraincc.app"
BUNDLE_ID_DEV="com.okbraincc.app.dev"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV="dev"
MODE=""

for arg in "$@"; do
  case "$arg" in
    --prod) ENV="prod" ;;
    --dev)  ENV="dev" ;;
    *)
      if [[ -z "$MODE" ]]; then
        MODE="$arg"
      else
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--mock|--mock-verify] [--dev|--prod]" >&2
        exit 2
      fi
      ;;
  esac
done

MODE="${MODE:-run}"

if [[ "$ENV" == "dev" ]]; then
  APP_NAME="${APP_BASENAME}-Dev"
  BUNDLE_ID="$BUNDLE_ID_DEV"
else
  APP_NAME="$APP_BASENAME"
  BUNDLE_ID="$BUNDLE_ID_PROD"
fi

APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

"$ROOT_DIR/scripts/build.sh" "--$ENV"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

open_mock_app() {
  /usr/bin/open -n "$APP_BUNDLE" --args --mock-backups
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --mock|mock)
    open_mock_app
    ;;
  --mock-verify|mock-verify)
    open_mock_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--mock|--mock-verify] [--dev|--prod]" >&2
    exit 2
    ;;
esac
