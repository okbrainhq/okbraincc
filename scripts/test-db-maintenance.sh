#!/usr/bin/env bash
# Focused, fixture-only checks. No app launch, pkill, real SSH, or real settings.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$ROOT/.build/maintenance-verification"
CACHE_DIR="$ROOT/.build/clang-module-cache"
mkdir -p "$CHECK_DIR" "$CACHE_DIR"

python3 "$ROOT/scripts/test-db-maintenance.py"
swiftc -parse-as-library -module-cache-path "$CACHE_DIR" \
  "$ROOT/Sources/OkBrainCC/Support/AppEnvironment.swift" \
  "$ROOT/Sources/OkBrainCC/Models/DBMaintenanceModels.swift" \
  "$ROOT/Sources/OkBrainCC/Models/DBMaintenanceSafety.swift" \
  "$ROOT/Sources/OkBrainCC/Services/BackupScriptRunner.swift" \
  "$ROOT/Sources/OkBrainCC/Stores/DBMaintenanceStore.swift" \
  "$ROOT/scripts/verify_db_maintenance.swift" \
  -o "$CHECK_DIR/verify-db-maintenance"
"$CHECK_DIR/verify-db-maintenance"
for script in "$ROOT"/scripts/deploy/BackupAgent/db-maintenance-*.sh; do
  bash -n "$script"
done
printf '\nFocused maintenance verification passed. No app was launched.\n'
