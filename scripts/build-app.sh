#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT/mac-app" -c release
BIN="$(swift build --package-path "$ROOT/mac-app" -c release --show-bin-path)"
APP="$ROOT/dist/Reminders Bridge.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/RemindersBridge" "$APP/Contents/MacOS/RemindersBridge"
cp "$ROOT/mac-app/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign "${SIGNING_IDENTITY:--}" "$APP"
printf '\nBuilt %s\n' "$APP"
