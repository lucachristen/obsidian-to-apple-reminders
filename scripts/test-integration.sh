#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PORT="${OBSIDIAN_TEST_PORT:-9237}"
OBSIDIAN="${OBSIDIAN_EXECUTABLE:-/Applications/Obsidian.app/Contents/MacOS/Obsidian}"
if [[ ! -x "$OBSIDIAN" ]]; then printf 'Obsidian desktop is required.\n' >&2; exit 1; fi
if curl -fsS "http://127.0.0.1:$PORT/json/list" >/dev/null 2>&1; then
  printf 'Port %s is already in use. Close the old test instance or choose OBSIDIAN_TEST_PORT.\n' "$PORT" >&2; exit 1
fi
VAULT="$ROOT/dist/integration-vault"
PROFILE="$ROOT/dist/integration-profile"
mkdir -p "$VAULT/.obsidian/plugins/obsidian-tasks-plugin" "$PROFILE"
# Only these named, disposable directories are used. No existing vault/profile is read.
node --input-type=module - "$ROOT" <<'JS'
import { rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
const root = process.argv[2];
const vault = join(root, 'dist/integration-vault');
// Previous disposable sidecar identities must not attach to freshly reset fixtures.
rmSync(join(vault, '.obsidian/plugins/obsidian-reminders-companion/bridge'), { recursive: true, force: true });
for (const name of ['IdentityExperiment.md', 'RelinkTarget.md', 'DeleteRecurring.md']) rmSync(join(vault, name), { force: true });
const write = (path, value) => writeFileSync(path, JSON.stringify(value, null, 2));
write(join(root, 'dist/integration-profile/obsidian.json'), { vaults: { '0123456789abcdef': { path: vault, ts: Date.now(), open: true } } });
write(join(vault, '.obsidian/app.json'), { safeMode: false });
write(join(vault, '.obsidian/community-plugins.json'), ['obsidian-tasks-plugin', 'obsidian-reminders-companion']);
writeFileSync(join(vault, 'Project.md'), '---\ntype: project\n---\n');
JS
./scripts/install-plugin.sh "$VAULT"
node --input-type=module - "$VAULT" <<'JS'
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
writeFileSync(join(process.argv[2], '.obsidian/plugins/obsidian-reminders-companion/data.json'), JSON.stringify({ enabled: false, queryPath: 'Project.md' }));
JS
for file in main.js manifest.json styles.css; do
  curl --fail -Ls "https://github.com/obsidian-tasks-group/obsidian-tasks/releases/download/8.4.0/$file" \
    -o "$VAULT/.obsidian/plugins/obsidian-tasks-plugin/$file"
done
printf '%s  %s\n' 'c1e3333bce3fee7c1a06397ea2989cd27e1659cc30795c53ed5a60e7941e48fa' \
  "$VAULT/.obsidian/plugins/obsidian-tasks-plugin/main.js" | shasum -a 256 --check
"$OBSIDIAN" --user-data-dir="$PROFILE" --remote-debugging-port="$PORT" \
  > "$ROOT/dist/integration-obsidian.log" 2>&1 &
OBSIDIAN_PID=$!
cleanup() { kill "$OBSIDIAN_PID" 2>/dev/null || true; wait "$OBSIDIAN_PID" 2>/dev/null || true; }
trap cleanup EXIT
READY=false
for _ in {1..100}; do
  if curl -fsS "http://127.0.0.1:$PORT/json/list" 2>/dev/null | grep -q 'app://obsidian.md/index.html'; then READY=true; break; fi
  sleep 0.2
done
if [[ "$READY" != true ]]; then printf 'Isolated Obsidian did not start; see dist/integration-obsidian.log.\n' >&2; exit 1; fi
node scripts/test-obsidian.mjs
./scripts/test-reminders.sh
printf '\n'
while IFS= read -r line || [[ -n "$line" ]]; do printf '%s\n' "$line"; done < "$ROOT/dist/reminders-integration-report.txt"
