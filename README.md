# Obsidian ↔ Apple Reminders

**Reminders Bridge** pairs a native macOS menu-bar app with an Obsidian plugin. A **Tasks query** selects which tasks appear in a dedicated Reminders list. Completion and reopening sync both ways; Obsidian owns titles, dates and priorities.

**Experimental, source-build software.** This project was vibe-coded with OpenAI's `gpt-6.1-sol` model. Tests are included, but are not a guarantee of correctness. Start with a test vault and back up your notes and task identity registry.

The bridge exchanges local JSON files—no cloud backend, network listener or API key. Apple Reminders may still sync through iCloud or another configured account.

## Requirements

- macOS 14 Sonoma or newer, with a writable Reminders account.
- Xcode Command Line Tools (`xcode-select --install`), Swift 5.9+, Node.js 22+ and npm.
- Desktop Obsidian 1.8.7+ with the **Tasks** community plugin enabled.

The adapter uses private Tasks internals and was tested with **Tasks 8.4.0**. Other versions may be incompatible; query or integration failures pause syncing rather than delete reminders.

## Install

Clone this repository and run from its root:

```bash
npm ci
./scripts/install-plugin.sh "/absolute/path/to/your/vault"
./scripts/build-app.sh
cp -R "dist/Reminders Bridge.app" /Applications/
open "/Applications/Reminders Bridge.app"
```

The app is ad-hoc signed, not notarized. Use macOS's right-click → **Open** flow if required. Launch the `.app`, not its bare executable.

### Obsidian

1. Enable **Reminders Bridge** under **Settings → Community plugins**. Restart Obsidian if it isn't listed.
2. Open its settings, edit **Tasks to sync** if needed, and click **Save**.
3. Turn on **Sync automatically**.

The default query selects unfinished tasks due or scheduled within the next two weeks, including overdue tasks:

```tasks
not done
(due before in 14 days) OR (scheduled before in 14 days)
sort by due
sort by priority
```

Queries run through Tasks' own engine, including global filters. Keep your global task tag, if configured. Function filters require **Tasks → Searches → Enable custom searches**; only use expressions you trust. **Advanced → Run query as if in note** supplies a note context for `query.file` references and placeholders.

### Mac app

1. Open the menu-bar **Settings…** and choose the same vault's root folder—not `.obsidian`.
2. Click **Sync Now** and approve full Reminders access.
3. Tasks appear in the **Obsidian** list. Rename it in settings if desired; optionally enable **Launch at login**.

**Both apps must stay running.** Changes usually settle within a few seconds, with ten-second fallback checks. The menu shows status, errors, **Pause/Resume Sync**, and review actions. Mac-side **Sync Now** reads the latest snapshot; it does not force Obsidian to refresh its query.

For a custom configuration folder:

```bash
./scripts/install-plugin.sh "/absolute/path/to/vault" ".obsidian-work"
```

The app detects the folder automatically; you can override it in settings. To update, quit the Mac app, rerun the installation/build commands, replace the app, and restart Obsidian. Plugin settings and bridge data are preserved.

## Sync behavior

| Change | Result |
| --- | --- |
| Task matches the query | Create/update its reminder |
| Edit title, dates or priority in Obsidian | Update the reminder |
| Complete/reopen in either app | Update the other app; Obsidian wins simultaneous conflicts |
| Completed task leaves `not done` query | Keep its completed reminder and link |
| Unfinished task leaves the query | Remove its reminder, not the Markdown task |
| Delete or ambiguously change a task | Freeze its link for review |
| Delete a selected reminder | Recreate it; never delete the Markdown task |
| Create an unrelated reminder | Leave it untouched; no import into Obsidian |
| Edit managed reminder content | Obsidian overwrites it |

- Due dates become all-day deadlines; scheduled dates appear only in notes. Start dates are not synced.
- Priorities map to Reminders high/medium/none/low. Only standard `[ ]` and `[x]`/`[X]` statuses are supported.
- Tasks handles completion dates and recurrence. Recurring successors get separate identities; reopening an old instance doesn't remove its successor. `🏁 delete` retires the completed instance and its reminder.
- Keep managed reminders in their dedicated list and preserve their Obsidian links. Moving them or removing links can create replacements.
- Initial creation follows query order, but EventKit cannot rearrange existing reminders. Use Reminders' due-date or priority sorting.
- Use **one bridge instance on one Mac per vault**. Missing/read-only lists, stale snapshots, invalid queries and identity-data errors pause syncing.

### Task links and review

IDs live in plugin data, **not your Markdown**. Matching uses task text and note context; ambiguous edits, moves or deletions require confirmation rather than a guess.

Click the plugin status bar, **Task links → Review…**, or the Mac app's **Review N Tasks in Obsidian…** action. Choose **Link to this task**, **Choose another…**, or **Task was deleted** (then confirm reminder deletion).

Other confidently linked tasks keep syncing. Unmatched new tasks wait until uncertain links are resolved to avoid duplicates; pending completion changes for uncertain tasks wait too.

**Upgrading from the marker-based version:** update both pieces and keep Obsidian open during migration. Existing IDs are backed up before comments are removed. Duplicate legacy IDs stop migration—remove the copied comment, not the original. Do not downgrade after migration.

## Backups and privacy

Back up `identities.json` and `identities.json.bak` alongside your notes. They live in:

```text
<config>/plugins/obsidian-reminders-companion/bridge/
```

This folder contains private task text, paths and matching context. Pending delete-on-completion edits can temporarily include a full note's before/after text. **Exclude it from public Git repositories and vault cloud sync**, while keeping independent private backups. The automatic backup protects against a missing/corrupt primary, not loss of both copies.

The Mac app reads this mailbox, not Markdown notes, and stores state under `~/Library/Application Support/ObsidianRemindersBridge/`. It is not sandboxed; EventKit grants full Reminders access, though the bridge only modifies managed reminders in its dedicated list.

## Verify and troubleshoot

First test a task due tomorrow: confirm one reminder appears, complete/reopen it in both apps, and check for duplicates. Also test edits, recurrence and task deletion/review before using important notes.

- **No reminders:** check both plugins, sync settings, the query and selected vault. Keep both apps open.
- **Permission denied:** use **Open Privacy Settings…** and enable Reminders access for the app.
- **Task needs review:** use the review dialog above; new unmatched tasks wait until links are resolved.
- **Identity data missing/corrupt:** stop both apps and restore the registry from backup. A valid `.bak` restores the primary on plugin startup. Don't delete both files to reset syncing.
- **Pending completion:** keep Obsidian open and check its status bar for errors; durable commands retry after restart.
- **Missing/read-only list:** restore the list/account rather than creating a replacement.
- **Tasks compatibility error:** use Tasks 8.4.0 or update `obsidian-plugin/src/tasks-adapter.ts`; don't interpret failed queries as empty results.

To uninstall, pause and quit the Mac app, disable the plugin, then remove both. Optionally delete the dedicated list and app state. Preserve the identity registry if you may reinstall.

## Development

```bash
npm ci
npm run typecheck
npm run test:plugin
npm run build:plugin
swift test --package-path mac-app
./scripts/build-app.sh
```

Unit tests cover identity matching/recovery, reconciliation, recurrence, protocol validation, reminder content and sync activity. Menu-bar interactions and launch-at-login require manual verification.

For real Obsidian/EventKit tests:

```bash
./scripts/test-integration.sh
```

The harness downloads pinned Tasks 8.4.0, uses a disposable vault/profile under `dist/`, and creates a disposable Reminders list. Approve its separate permission prompt. Normal cleanup closes the isolated Obsidian process and removes the test list; interruption may leave artifacts. Your existing vault/session is not used. The debugger is loopback-only; set `OBSIDIAN_TEST_PORT` or `OBSIDIAN_EXECUTABLE` if needed.

To sign a build with your development identity:

```bash
SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh
```
