#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf 'Usage: %s /path/to/vault [config-folder]\n' "$0" >&2
  exit 1
fi
VAULT="$1"
CONFIG="${2:-.obsidian}"
if [[ ! -d "$VAULT/$CONFIG" || "$CONFIG" == */* || "$CONFIG" == '..' || "$CONFIG" == '.' ]]; then
  printf 'Select an existing Obsidian vault and a single configuration folder name.\n' >&2
  exit 1
fi
npm --prefix "$ROOT/obsidian-plugin" run build
DEST="$VAULT/$CONFIG/plugins/obsidian-reminders-companion"
mkdir -p "$DEST"
cp "$ROOT/obsidian-plugin/main.js" "$ROOT/obsidian-plugin/manifest.json" "$DEST/"
printf '\nInstalled in %s\nEnable Apple Reminders Bridge in Obsidian community plugins.\n' "$DEST"
