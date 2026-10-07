# Obsidian ↔ Apple Reminders

**Reminders Bridge** is a native macOS menu-bar app plus a matching Obsidian plugin of the same name. Your **Tasks query** selects what goes into a dedicated Apple Reminders list. Completion and reopening sync both ways; Obsidian owns titles, due dates and priorities.

No cloud service, network listener, API key or Obsidian vault scanning by the Mac app. The two processes exchange local JSON files inside the Reminders Bridge plugin folder.

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

1. Open **Settings → Community plugins** and enable **Reminders Bridge**. Restart Obsidian if the newly copied plugin is not listed. Tasks must also be enabled.
2. In Tasks settings, open **Searches → Enable custom searches**, since your query uses `filter by function`.
3. Open **Reminders Bridge** settings. Under **Tasks to sync**, start from the default query (below) or write your own, then click **Save**. Under **Advanced**, **Run query as if in note** is only needed if your query refers to its own note (`query.file` properties or placeholders such as `{{query.file.folder}}`): enter a vault-relative note path, and those references resolve against that note. The query itself still lives in plugin settings.
4. Turn on **Sync automatically**. Check Obsidian's status bar for query errors.

Sync does **not** add IDs or other metadata to your Markdown. Task identities live in `bridge/identities.json` inside the plugin folder, with an automatically maintained `identities.json.bak` copy. Back up these files alongside your notes; they contain task text, paths and matching context.

The plugin matches tasks using their text, note, neighboring lines and note revision. Unique unchanged tasks can be tracked across moves and renames; completion changes and same-position edits with unchanged neighboring context can usually retain their link. Line numbers alone and fuzzy title matches are never used. Identical tasks are distinguishable in an unchanged note but can become uncertain after edits. Without an attached ID, a deleted task replaced by an identical task cannot always be distinguished from the original.

Uncertain links are frozen, not treated as deletions. The Mac app offers **Review 1 Task in Obsidian…** (or the corresponding task count), opening the detailed review dialog in Obsidian. You can also click the plugin status bar, use **Review task links** in the command palette, or click **Review…** under **Task links** in plugin settings. Each task in the review dialog shows where it was (note, line and neighboring lines) next to where it probably is now, with the reasons for the suggestion (same title, same note, shared context). Click a location to open that note. Then choose one: **Link to this task** keeps its reminder and links it to the suggested task; **Choose another…** opens a picker that ranks likely matches first and searches task text, note paths and neighboring lines (case/accent insensitive); **Task was deleted**, confirmed with **Delete its reminder**, removes the reminder. Nothing is relinked until you click. Other confidently linked tasks keep syncing; unmatched new tasks wait until uncertain links are resolved so a moved task cannot create a duplicate reminder. Pending completion requests wait too, and apply after relinking.

**Upgrading from the marker-based version:** update both the plugin and Mac app. Existing comments are migrated automatically: the original IDs are saved in both registry copies before their comments are removed. Existing reminders keep their identity. Duplicate legacy IDs stop migration; remove the copied comment first. Keep Obsidian open until migration finishes. Old Mac apps reject the new snapshot protocol rather than deleting uncertain reminders. Version 0.2 uses protocol v3 because reminder ownership now lives in the Obsidian link instead of technical notes. Update both installed pieces; do not downgrade to the note-marker app after migration.

### 2. Install the Mac app

```bash
# Quit an older copy before replacing it.
cp -R "dist/Reminders Bridge.app" /Applications/
open "/Applications/Reminders Bridge.app"
```

1. Click the **checklist icon** in the menu bar → **Settings…**.
2. Choose the **root of the same Obsidian vault**, not its `.obsidian` folder.
3. Click **Sync Now** in the menu. Approve **full Reminders access** when macOS asks.
4. The app creates its own list, **Obsidian**, using the default Reminders account. Edit **Reminders list** in settings and press Return to rename that same list; no reminders or mappings are recreated. Older automatically generated `Obsidian — VAULT` names migrate to `Obsidian` on sync; existing user-chosen names are preserved.
5. Optionally enable **Launch at login**, after installing the app in `/Applications`.

Both Obsidian and the Mac app must stay running. Note metadata changes, renames and deletions trigger a debounced companion sync. Completion commands are checked every second. The Mac app watches snapshot/error changes and listens for Reminders changes. Both still check every ten seconds as a fallback. Changes usually settle within a few seconds, but cold caches, migration, permissions or sleeping Macs can take longer.

The menu bar item is a standard macOS menu: a status line with the same coloured dot as Settings (click it to open Settings) and, beneath it, the last sync time or the current error (“Up to date”, “Waiting for Obsidian”, “Sync paused”), then **Sync Now**, **Pause/Resume Sync**, **Open Vault in Obsidian**, **Open Reminders**, **Settings…** and **Quit**. Pausing is remembered across app restarts. Both sides offer **Sync Now**; the Mac button consumes the latest Obsidian snapshot rather than forcing Obsidian’s query engine to refresh.

Settings is three short groups: a status row (current state, last sync time or error, and **Sync Now** / **Try Again**), the vault with **Choose…**, the Reminders list name and the configuration folder, and **Launch at login**. Text fields save on Return or when you click elsewhere.

Problems are shown in the menu itself, never only in Settings:

- **Obsidian closed or not sending updates** is not treated as an error. The menu says “Waiting for Obsidian”, with the last sync time.
- **Brief conflicts** (Reminders changing mid-sync) retry silently on the next check.
- **Real problems** turn the menu bar icon into a warning triangle. The menu and Settings show the message and, where there is one, the action that fixes it: **Open Privacy Settings…** for denied Reminders access, **Open Obsidian** for errors reported by the plugin, **Choose Vault…** when the vault can't be opened. **Try Again** replaces **Sync Now**. Errors clear on the next successful sync.

The local build is **ad-hoc signed**, not notarized. Use the normal macOS right-click → Open flow if required. For a stable development signing identity:

```bash
SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh
```

Do not launch the bare Swift executable for normal use: the `.app` bundle supplies Reminders permission descriptions and the login-item identity.

### Custom configuration folder

```bash
./scripts/install-plugin.sh "/absolute/path/to/vault" ".obsidian-work"
```

The app finds the configuration folder automatically (whichever hidden folder in the vault contains the Reminders Bridge plugin); you can also set it under **Configuration folder** in Settings. To update, quit the app, rerun the install/build commands, replace the application, and reload/restart Obsidian. Plugin settings and bridge files are not overwritten by the install script.

## Default query

```tasks
not done
(due before in 14 days) OR (scheduled before in 14 days)
sort by due
sort by priority
```

Replace it with any Tasks query under **Tasks to sync** in the plugin settings. The plugin runs it through **Tasks' real query engine**, including Tasks' global query/filter, note properties, JavaScript expressions, date parsing, boolean filters and sorting. Function filters (`filter by function …`) need **Tasks → Searches → Enable custom searches**. If your Tasks settings require a global task tag such as `#task`, your tasks must still carry it.

For example, to sync only tasks from project notes and skip an archive folder:

```tasks
not done
filter by function task.file.property('type') === 'project'
(due before in 14 days) OR (scheduled before in 14 days)
path does not include Archive
sort by due
```

The exported snapshot and initial reminder creation preserve Tasks’ actual query order, not UUID order. EventKit cannot set Reminders’ custom/manual ordering or its Sort By setting, so existing reminders cannot be rearranged to exactly mirror your query's order. In Reminders, choose **Sort By → Due Date** (or Priority) for the closest native approximation. Reminders’ tie-breaking and scheduled-only tasks may still differ. Grouping/limits are evaluated by Tasks; a task appearing in multiple groups is synced only once. Function queries execute JavaScript in Obsidian, so only use expressions you trust.

Tasks descriptions stay clean: there are no injected identity comments for description filters or function queries to account for. Old comments are removed during migration.

## Sync rules

| Change | Result |
| --- | --- |
| A task matches the query | Create/update its reminder |
| Edit title, due date or priority in Obsidian | Update the reminder |
| Complete/reopen in either app | Update the other app |
| Completed task stops matching `not done` | Keep its link and completed reminder |
| An unfinished task leaves the query for another reason | Remove its managed reminder, never the Markdown task |
| Delete a task from Obsidian | Freeze its link; choose **Task was deleted** to remove its reminder |
| Delete a selected reminder | Recreate it; reminder deletion does **not** delete a task |
| Create an unrelated reminder | Leave it untouched; no inbox import in v1 |
| Edit a managed reminder's title/date/notes | Obsidian overwrites those fields |

- **Due dates** become all-day Reminders due dates. **Scheduled dates** stay separate in reminder notes; they do not become deadlines or alarms. Start dates are not synced.
- Tasks priorities highest/high → Reminders high; medium → medium; normal → none; low/lowest → low.
- V1 supports standard `[ ]` and `[x]`/`[X]` statuses. Custom status cycles are rejected rather than incorrectly interpreted.
- Completion uses Tasks' public toggle interface, so Tasks' completion-date and recurrence behavior apply. For recurrence, the registry records the resulting completed instance; the generated next instance gets a new identity if it matches the query. Reopening an old recurring instance does not remove its already-generated successor. With `🏁 delete`, Tasks removes the completed instance instead: its link/reminder is retired, and the successor gets a new identity. Interrupted bridge completion edits are journaled and replayed without toggling the successor again.
- A three-way comparison distinguishes an Obsidian change from a Reminders change. If both changed, Obsidian is authoritative. In-flight completion commands prevent stale snapshots from overwriting the user's reminder checkmark.
- Reminder titles use wiki-link display text/aliases rather than `[[brackets]]`. Notes contain only scheduling information when needed—no UUID or vault path. The Obsidian URL carries a `bridgeTask` identity parameter for crash recovery; clicking it still opens the source note.
- Only reminders bearing this app's ownership identity **in its dedicated list** are changed. Keep managed reminders in that list and preserve their Obsidian links. Moving them out or removing those links can cause replacements. Legacy note markers are accepted and migrated into links without changing task identity or completion, including pending/review links. The rest of an uncertain reminder remains frozen.
- Uncertain identities pause only the affected links (and hold unmatched newcomers). Invalid queries, duplicate legacy IDs, corrupt/missing identity data, stale snapshots (90 seconds), inaccessible files and permission failures pause synchronization. A list deliberately deleted in Reminders is not silently recreated.
- Stopping Obsidian is detected by snapshot expiry, not instantly. Use **Pause sync** before maintenance or disable the companion's sync setting first.
- Use **one bridge app instance on one Mac per vault**. The mailbox protocol is not a multi-device conflict-resolution system. The mailbox contains task titles and paths; do not publish it or include it in vault cloud/Git sync.

## Verify your installation

Use a test vault first:

1. Create a note with YAML `type: project` and an unfinished task due tomorrow (plus your global Tasks tag, if configured).
2. Confirm the query finds it in an ordinary Tasks block, then confirm exactly one reminder is created.
3. Complete it in Reminders. Confirm Obsidian's checkbox and completion date update, even though the task leaves the query.
4. Reopen that reminder. Confirm the task reopens without producing a duplicate.
5. Complete and reopen from Obsidian; edit its title/due date with surrounding lines unchanged; move the unchanged task to another note. Confirm its identity is preserved and no ID comments are added.
6. Test a recurring task: the completed instance should remain linked, and only a matching successor should create a new reminder.
7. Change the note's `type` to an excluded value while the task is unfinished. Confirm its reminder disappears but the task remains.
8. Add a normal reminder yourself. It should never be imported or changed.
9. Enter an invalid query. Existing reminders should remain untouched and both apps should show a sync error.
10. Move and substantially rewrite a task so matching becomes uncertain. Confirm its reminder is frozen, other linked tasks keep syncing, and **Review…** under **Task links** lets you explicitly relink it.
11. Delete a linked task. Confirm its reminder remains untouched until you choose **Task was deleted** in the review dialog.
12. Restart the plugin and verify it restores existing identities. In a test vault with both processes stopped, remove `identities.json` and confirm its backup restores it on restart.

## Troubleshooting

- **No reminders:** enable both plugins and companion sync, check the query in Obsidian, and verify the selected vault. Status messages are visible in both apps.
- **Permission denied:** choose **Open Privacy Settings…** in the menu, or go to System Settings → Privacy & Security → Reminders → enable the installed app, then restart it. If development rebuilds confuse TCC, quit the app, run `tccutil reset Reminders ch.lucachristen.obsidian-reminders-bridge`, and reopen the `.app` to request permission again.
- **Query internals changed:** use a source-compatible Tasks version or update `obsidian-plugin/src/tasks-adapter.ts`. Do not bypass the error by treating the results as empty.
- **Task needs review:** click **Review N Tasks in Obsidian…** in the Mac app, click the plugin status bar, or open **Review…** under **Task links** in its settings. Click **Link to this task** (or **Choose another…**), or **Task was deleted** if it's gone. New unmatched tasks wait until all uncertain links are resolved.
- **Identity data missing/corrupt:** stop both processes and restore `bridge/identities.json` or `identities.json.bak` from backup. A valid backup automatically restores a missing/corrupt primary on startup. Do not delete both to reset sync: an existing snapshot prevents unsafe reinitialization.
- **Duplicate legacy task ID:** remove the comment from the newly copied task, leaving the original intact, then retry migration.
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

Unit tests cover completion reconciliation, reopening, query departure, pending commands, paused identities, freshness/duplicate validation, conservative identity matching, competing/duplicate tasks, recurrence identities, legacy migration, explicit relinking, registry backup recovery, atomic mailbox replacement and the Tasks integration contract.

### Real Obsidian + EventKit integration tests

```bash
./scripts/test-integration.sh
```

This downloads the pinned official Tasks 8.4.0 release (verifying its JavaScript SHA-256), opens installed Obsidian with a **separate profile and vault under `dist/`**, enables function queries only in that profile, and runs real query/completion/recurrence/error checks, marker migration, clean-Markdown assertions, plugin restart, uncertain-link protection, relinking and forgetting. It then compiles a separate test `.app` using the production `SyncController`, exercises actual EventKit creation, completion/reopening in both directions, title/date edits, configurable list renaming, clean reminder content, legacy ownership migration, uncertain-identity freezing, no-op write suppression, query departure and unrelated-reminder safety, and deletes its disposable Reminders list.

Approve the test app's macOS Reminders prompt if asked. Its permission is separate from the production app's permission. Both normal success and handled test failures attempt cleanup; forcibly interrupting the test can leave its disposable list/state behind. Existing test-vault app state causes the native test to refuse to run rather than overwrite it.

The isolated Obsidian process is closed on exit; your existing Obsidian session and real vault are not touched. Test artifacts remain ignored under `dist/`, including `reminders-integration-report.txt` and `integration-obsidian.log`. The test debugger is loopback-only and lasts only for the isolated test session. A busy port causes a safe refusal; override with `OBSIDIAN_TEST_PORT=9238`. Set `OBSIDIAN_EXECUTABLE` if Obsidian is installed elsewhere.

The integration harness does not automate menu-bar clicks, production-app permission approval or launch-at-login. Verify those manually using the installation steps above.

```text
obsidian-plugin/src/tasks-adapter.ts    Private Tasks integration, isolated behind select/toggle
obsidian-plugin/src/main.ts             Query snapshots and safe Markdown edits
obsidian-plugin/src/identity.ts         Conservative identity matching and explicit relinking
obsidian-plugin/src/identity-store.ts   Atomic backed-up registry persistence/recovery
obsidian-plugin/src/model.ts            Protocol types and marker-free recurrence toggles
mac-app/Sources/BridgeCore/             Pure reconciliation and protocol validation
mac-app/Sources/RemindersBridge/        SwiftUI, EventKit and durable mailbox processing
scripts/                               Build and plugin installation
```

### Local data and protocol

- Vault mailbox: `<config>/plugins/obsidian-reminders-companion/bridge/`.
- `identities.json` and `identities.json.bak`: versioned task identity registry and redundant latest copy, containing UUIDs, task text, note paths, neighboring-line context and note hashes. Both are written before migration, completion edits or snapshot publication; unchanged registries are not repeatedly rewritten. The backup protects against a missing/corrupt primary, not accidental deletion of both copies—keep independent vault backups.
- `snapshot.json`: protocol v3 complete snapshot, timestamp, vault name, query-ordered selected tasks plus all confidently linked Tasks-cache tasks (including completed tasks), `pausedTaskIDs`, and human-readable `pausedTasks` review details. Paused IDs must be unique and disjoint from exported tasks; review details must correspond to those IDs. The Mac app still accepts v1/v2 during upgrades; older apps safely reject v3.
- `error.json`: companion error; the Mac app refuses to sync while it exists.
- `commands/<uuid>.json`: durable, idempotent completion requests with expected prior completion.
- `acks/<uuid>.json`: success/error and processing timestamp. Commands and acknowledgements are removed after acceptance. Snapshot publication waits for Tasks' cache to reflect Markdown edits.
- App state: `~/Library/Application Support/ObsidianRemindersBridge/<vault-path-and-config-hash>.json`. Contains the dedicated list identity and configurable name, task/reminder mappings, last synchronized completion and pending commands.
- Preferences/security-scoped vault bookmark: macOS defaults under `ch.lucachristen.obsidian-reminders-bridge`.

The app is not sandboxed; its source build uses a user-selected folder and security-scoped bookmark rather than an App Store entitlement setup. It only accesses the selected mailbox and its own application-support state. EventKit grants full Reminders access, but writes are restricted to managed items in the dedicated list.

### Remove

Pause and quit the Mac app, disable the companion, delete the application/plugin folder, and optionally delete the dedicated Reminders list and application-support state. No metadata cleanup is needed in Markdown after migration. Preserve the identity registry if you may reinstall and want to retain existing reminder links.

## Task reconciliation backlog

Implemented (2026-10-05): contextual original/current comparison, ranked candidate suggestions with match reasons, and multi-field search. Unit and real Obsidian interaction tests cover these changes; user visual review and additional real-world matching examples are still needed.

User feedback (2026-10-04): task merging/reconciliation in Obsidian needs improvement. In particular, it is hard to find the correct task in the relinking picker.

- Show the original task alongside possible matches, with useful note and task context.
- Rank likely matches first and improve search so users do not have to sift through unrelated tasks.
- Keep the final choice explicit; preserve the no-guessing safety rule for ambiguous identities.
- Capture concrete examples before changing matching or completion write-back behavior.

## UI refinement backlog

Implemented (2026-10-05): quick background checks no longer publish transient activity; manual sync gives immediate feedback, and slower checks delay activity by 400 ms and keep it visible for at least 500 ms. The redundant one-second timeline and menu polling caption are removed, and unchanged summary/review values are not republished. Native integration tests cover quiet no-op refresh and manual feedback. Visual stability, focus/scroll preservation and the broader native design still need user verification.

UI iteration (2026-10-05): after user screenshot review, replaced the oversized Settings tabs and fixed-height form with an intrinsically sized single page, readable connection rows, a native rename dialog and collapsed Advanced controls. The menu now uses a compact, richer panel with a genuine Liquid Glass surface on macOS 26+, native secondary controls and a more-actions menu. Settings uses native glass buttons while keeping content surfaces readable; no custom blur shaders, gradients or glass-on-glass cards. Last-sync time is shown only while paused. This is a design candidate for user visual review, not a claim that polish is finished.

User feedback (2026-10-04, reiterated 2026-10-05): the UI is too complex and does not yet feel like a polished native macOS app. The UI redesign is not considered finished.

- Investigate reported UI flashing on every update/refresh. Updates should be visually stable, preserving focus, scroll position and view state; verify the cause before changing rendering behavior.
- Reduce visual clutter and repeated status/help text in the menu-bar popover and settings.
- Refine spacing, typography, control hierarchy and native macOS conventions—not just grouped panels.
- Keep the primary sync state and review action obvious; move secondary details out of the main flow.
- Review the next iteration visually with the user before calling it polished.

## V2

Import newly created reminders into an Obsidian inbox note, broader status/date support, and a supported upstream Tasks query interface would be natural extensions.
