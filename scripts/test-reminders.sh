#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/dist/integration-native"
APP="$ROOT/dist/Reminders Bridge Integration Test.app"
mkdir -p "$BUILD" "$APP/Contents/MacOS"
TARGET="$(uname -m)-apple-macos14.0"
swiftc -target "$TARGET" -parse-as-library -emit-module -emit-object \
  -module-name BridgeCore "$ROOT/mac-app/Sources/BridgeCore/Models.swift" \
  -o "$BUILD/BridgeCore.o" -emit-module-path "$BUILD/BridgeCore.swiftmodule"
swiftc -target "$TARGET" -parse-as-library -I "$BUILD" "$BUILD/BridgeCore.o" \
  "$ROOT/mac-app/Sources/RemindersBridge/SyncController.swift" \
  "$ROOT/mac-app/Integration/RemindersIntegration.swift" \
  -o "$APP/Contents/MacOS/RemindersIntegration"
cp "$ROOT/mac-app/Integration/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
printf 'Testing real EventKit. Approve the macOS Reminders prompt if asked.\n'
"$APP/Contents/MacOS/RemindersIntegration" "$ROOT"
