# Obsidian ↔ Apple Reminders

A native macOS menu-bar app plus an Obsidian companion plugin. Your **Tasks query** selects what goes into a dedicated Apple Reminders list. Completion and reopening sync both ways; Obsidian owns titles, due dates and priorities.

No cloud service, network listener, API key or Obsidian vault scanning by the Mac app. The two processes exchange local JSON files inside the companion plugin folder.

**Status:** locally validated end-to-end with **macOS 27.0, Obsidian 1.13.7, Tasks 8.4.0 and real Apple Reminders/EventKit**, using an isolated vault/profile and the production sync controller in a disposable test app. Automated unit and integration tests pass. Menu-bar interactions and launch-at-login still need manual verification. Start with a test vault and back up your notes. The Tasks query adapter uses private internals.

## Requirements

- macOS 14 Sonoma or newer.
- Xcode Command Line Tools (`xcode-select --install`), with Swift 5.9 or newer.
- Node.js 22 or newer and npm (the integration harness uses its built-in WebSocket).
- Desktop Obsidian 1.8.7 or newer, with the **Tasks** community plugin enabled.
- A writable Apple Reminders account/list.

The query adapter was checked against **Tasks 8.4.0 source**, revision [`a722a85`](https://github.com/obsidian-tasks-group/obsidian-tasks/tree/a722a85f54e219ffaad33ec360688cd494daa80d), and tested against the official **8.4.0 release inside Obsidian**. This is not a promise of compatibility with every Tasks version. If the integration is unavailable or a query fails, syncing pauses instead of treating the results as empty.

## Install

Run these commands from this repository:

```bash
npm ci
./scripts/install-plugin.sh "/absolute/path/to/your/vault"
./scripts/build-app.sh
```

### 1. Set up Obsidian

1. Open **Settings → Community plugins** and enable **Apple Reminders Bridge**. Restart Obsidian if the newly copied plugin is not listed. Tasks must also be enabled.
2. In Tasks settings, allow **JavaScript / function queries**, since your query uses `filter by function`.
3. Open **Apple Reminders Bridge** settings. Your query is already the default (below). Optionally set **Query context note** to a vault-relative Markdown path if using `query.file` properties or placeholders. The query itself lives in plugin settings, not in that note.
4. Turn on **Enable sync**. Check Obsidian's status bar for query errors.

Matching tasks receive an invisible identity comment, for example:

```markdown
- [ ] <!-- reminders:11111111-1111-4111-a111-111111111111 --> Call Alex 📅 2026-10-01
```

Leave these comments in place. They preserve identity across edits, note renames and moving tasks between notes. Comments go immediately after the checkbox: placing them after a due date breaks Tasks' trailing-metadata parser. Older trailing markers are automatically migrated. Block references remain at the end of the line. When copying a task to create a different task, remove the copied comment; duplicate identities pause syncing.

### 2. Install the Mac app

```bash
# Quit an older copy before replacing it.
cp -R "dist/Obsidian Reminders Bridge.app" /Applications/
open "/Applications/Obsidian Reminders Bridge.app"
```

1. Click the **checklist icon** in the menu bar → **Settings…**.
2. Choose the **root of the same Obsidian vault**, not its `.obsidian` folder.
3. If you use a custom Obsidian configuration folder, enter it and click **Apply**.
4. Click **Sync now**. Approve **full Reminders access** when macOS asks.
5. The app creates its own list, **Obsidian — YOUR VAULT NAME**, using the default Reminders account.
6. Optionally enable **Launch at login**, after installing the app in `/Applications`.

Both Obsidian and the Mac app must stay running. Each polls every ten seconds; Reminders changes also trigger a sync. Initial tagging and completion acknowledgements can take several passes (usually 10–30 seconds). Sleeping Macs sync after waking.

The local build is **ad-hoc signed**, not notarized. Use the normal macOS right-click → Open flow if required. For a stable development signing identity:

```bash
SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh
```

Do not launch the bare Swift executable for normal use: the `.app` bundle supplies Reminders permission descriptions and the login-item identity.

### Custom configuration folder

```bash
./scripts/install-plugin.sh "/absolute/path/to/vault" ".obsidian-work"
```

Use the same configuration folder in the app. To update, quit the app, rerun the install/build commands, replace the application, and reload/restart Obsidian. Plugin settings and bridge files are not overwritten by the install script.

## Your default query

```tasks
not done
filter by function ['project', 'area', 'person'].includes(task.file.property('type'))
(due before in 15 days) OR (scheduled before in 15 days)
path does not include _ meta/templates
path does not include 9 Archive
sort by due
sort by scheduled
sort by priority
```

The companion delegates this to **Tasks' real query engine**, including Tasks' global query/filter, note properties, JavaScript expressions, date parsing, boolean filters and sorting. Ensure the appropriate notes have `type: project`, `type: area` or `type: person` in their YAML properties. If your Tasks settings require a global task tag such as `#task`, your tasks must still carry it.

Reminders does not expose the same custom ordering: choose its built-in due-date or priority sorting. Grouping/limits are evaluated by Tasks; a task appearing in multiple groups is synced only once. Function queries execute JavaScript in Obsidian, so only use expressions you trust.

The identity comment is part of the description seen by Tasks, although it is stripped from reminder titles. Prefix-sensitive description filters and description-based function queries may need to strip that comment themselves. Your property/date/path query is unaffected.

## Sync rules

| Change | Result |
| --- | --- |
| A task matches the query | Create/update its reminder |
| Edit title, due date or priority in Obsidian | Update the reminder |
| Complete/reopen in either app | Update the other app |
| Completed task stops matching `not done` | Keep its link and completed reminder |
| An unfinished task leaves the query for another reason | Remove its managed reminder, never the Markdown task |
| Delete a task from Obsidian | Remove its managed reminder |
| Delete a selected reminder | Recreate it; reminder deletion does **not** delete a task |
| Create an unrelated reminder | Leave it untouched; no inbox import in v1 |
| Edit a managed reminder's title/date/notes | Obsidian overwrites those fields |

- **Due dates** become all-day Reminders due dates. **Scheduled dates** stay separate in reminder notes; they do not become deadlines or alarms. Start dates are not synced.
- Tasks priorities highest/high → Reminders high; medium → medium; normal → none; low/lowest → low.
- V1 supports standard `[ ]` and `[x]`/`[X]` statuses. Custom status cycles are rejected rather than incorrectly interpreted.
- Completion uses Tasks' public toggle interface, so Tasks' completion-date and recurrence behavior apply. For recurrence, the completed instance keeps its identity; the generated next instance gets a new one if it matches the query. Reopening an old recurring instance does not remove its already-generated successor.
- A three-way comparison distinguishes an Obsidian change from a Reminders change. If both changed, Obsidian is authoritative. In-flight completion commands prevent stale snapshots from overwriting the user's reminder checkmark.
- Only reminders bearing this app's marker **in its dedicated list** are changed. Keep managed reminders in that list, and do not remove their identity line from notes. Moving them out of the list or deleting their identity line can cause a replacement reminder to be created.
- Invalid queries, duplicate IDs, stale snapshots (90 seconds), inaccessible files and permission failures pause synchronization. A list deliberately deleted in Reminders is not silently recreated.
- Stopping Obsidian is detected by snapshot expiry, not instantly. Use **Pause sync** before maintenance or disable the companion's sync setting first.
- Use **one bridge app instance on one Mac per vault**. The mailbox protocol is not a multi-device conflict-resolution system. The mailbox contains task titles and paths; do not publish it or include it in vault cloud/Git sync.

## Verify your installation

Use a test vault first:

1. Create a note with YAML `type: project` and an unfinished task due tomorrow (plus your global Tasks tag, if configured).
2. Confirm the query finds it in an ordinary Tasks block, then confirm exactly one reminder is created.
3. Complete it in Reminders. Confirm Obsidian's checkbox and completion date update, even though the task leaves the query.
4. Reopen that reminder. Confirm the task reopens without producing a duplicate.
5. Complete and reopen from Obsidian; edit its title/due date; move the task to another note. Confirm its identity is preserved.
6. Test a recurring task: the completed instance should remain linked, and only a matching successor should create a new reminder.
7. Change the note's `type` to an excluded value while the task is unfinished. Confirm its reminder disappears but the task remains.
8. Add a normal reminder yourself. It should never be imported or changed.
9. Enter an invalid query. Existing reminders should remain untouched and both apps should show a sync error.

## Troubleshooting

- **No reminders:** enable both plugins and companion sync, check the query in Obsidian, and verify the selected vault/config folder. Status messages are visible in both apps.
- **Permission denied:** System Settings → Privacy & Security → Reminders → enable the installed app, then restart it. If development rebuilds confuse TCC, quit the app, run `tccutil reset Reminders ch.lucachristen.obsidian-reminders-bridge`, and reopen the `.app` to request permission again.
- **Query internals changed:** use a source-compatible Tasks version or update `obsidian-plugin/src/tasks-adapter.ts`. Do not bypass the error by treating the results as empty.
- **Duplicate task ID:** remove the comment from the newly copied task, leaving the original intact.
- **Pending completion:** keep Obsidian open, ensure the Tasks cache is warm, and inspect its status bar. Commands retry after restart and are acknowledged before the app accepts a newer snapshot.
- **Missing/read-only list:** restore the dedicated list/account. To deliberately start over, quit the app, remove only its per-vault state file (below), and remove the old managed list before reconnecting. Otherwise you can create duplicate lists.

## Development

```bash
npm ci
npm run typecheck
npm run test:plugin
npm run build:plugin
swift test --package-path mac-app
./scripts/build-app.sh
```

Unit tests cover completion reconciliation, reopening, query departure, pending commands, freshness/duplicate validation, stable markers, recurrence identities, atomic mailbox replacement and the Tasks integration contract.

### Real Obsidian + EventKit integration tests

```bash
./scripts/test-integration.sh
```

This downloads the pinned official Tasks 8.4.0 release (verifying its JavaScript SHA-256), opens installed Obsidian with a **separate profile and vault under `dist/`**, enables function queries only in that profile, and runs real query/completion/recurrence/error checks. It then compiles a separate test `.app` using the production `SyncController`, exercises actual EventKit creation, completion/reopening in both directions, title/date edits, query departure and unrelated-reminder safety, and deletes its disposable Reminders list.

Approve the test app's macOS Reminders prompt if asked. Its permission is separate from the production app's permission. Both normal success and handled test failures attempt cleanup; forcibly interrupting the test can leave its disposable list/state behind. Existing test-vault app state causes the native test to refuse to run rather than overwrite it.

The isolated Obsidian process is closed on exit; your existing Obsidian session and real vault are not touched. Test artifacts remain ignored under `dist/`, including `reminders-integration-report.txt` and `integration-obsidian.log`. The test debugger is loopback-only and lasts only for the isolated test session. A busy port causes a safe refusal; override with `OBSIDIAN_TEST_PORT=9238`. Set `OBSIDIAN_EXECUTABLE` if Obsidian is installed elsewhere.

The integration harness does not automate menu-bar clicks, production-app permission approval or launch-at-login. Verify those manually using the installation steps above.

```text
obsidian-plugin/src/tasks-adapter.ts    Private Tasks integration, isolated behind select/toggle
obsidian-plugin/src/main.ts             Query snapshots and safe Markdown edits
obsidian-plugin/src/model.ts            Stable IDs and recurrence identity handling
mac-app/Sources/BridgeCore/             Pure reconciliation and protocol validation
mac-app/Sources/RemindersBridge/        SwiftUI, EventKit and durable mailbox processing
scripts/                               Build and plugin installation
```

### Local data and protocol

- Vault mailbox: `<config>/plugins/obsidian-reminders-companion/bridge/`.
- `snapshot.json`: versioned complete snapshot, timestamp, vault name, selected tasks plus all marker-bearing Tasks-cache tasks (including completed tasks).
- `error.json`: companion error; the Mac app refuses to sync while it exists.
- `commands/<uuid>.json`: durable, idempotent completion requests with expected prior completion.
- `acks/<uuid>.json`: success/error and processing timestamp. Commands and acknowledgements are removed after acceptance. Snapshot publication waits for Tasks' cache to reflect Markdown edits.
- App state: `~/Library/Application Support/ObsidianRemindersBridge/<vault-path-and-config-hash>.json`. Contains the dedicated list identity, task/reminder mappings, last synchronized completion and pending commands.
- Preferences/security-scoped vault bookmark: macOS defaults under `ch.lucachristen.obsidian-reminders-bridge`.

The app is not sandboxed; its source build uses a user-selected folder and security-scoped bookmark rather than an App Store entitlement setup. It only accesses the selected mailbox and its own application-support state. EventKit grants full Reminders access, but writes are restricted to managed items in the dedicated list.

### Remove

Pause and quit the Mac app, disable the companion, delete the application/plugin folder, and optionally delete the dedicated Reminders list and application-support state. Identity comments in Markdown are harmless; remove them only after disabling sync.

## V2

Import newly created reminders into an Obsidian inbox note, broader status/date support, and a supported upstream Tasks query interface would be natural extensions.
