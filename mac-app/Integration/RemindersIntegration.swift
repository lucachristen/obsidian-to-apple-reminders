// Executed only by scripts/test-reminders.sh in a separately identified, disposable app bundle.
import AppKit
import BridgeCore
import Combine
import CryptoKit
import EventKit
import Foundation

@main
@MainActor
enum RemindersIntegration {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            guard CommandLine.arguments.count == 2 else { exit(2) }
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let reportURL = root.appendingPathComponent("dist/reminders-integration-report.txt")
            var report: [String] = []
            func record(_ text: String) {
                report.append(text)
                try? report.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)
            }
            let vault = root.appendingPathComponent("dist/integration-vault", isDirectory: true)
            let hash = SHA256.hash(data: Data((vault.path + "/.obsidian").utf8)).map { String(format: "%02x", $0) }.joined()
            let stateURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ObsidianRemindersBridge/\(hash).json")
            let store = EKEventStore()
            var controller: SyncController?
            var testCalendar: EKCalendar?
            var succeeded = false
            var ownsTestState = false
            do {
                guard Bundle.main.bundleIdentifier == "ch.lucachristen.obsidian-reminders-bridge.integration",
                      FileManager.default.fileExists(atPath: vault.appendingPathComponent("Project.md").path),
                      !FileManager.default.fileExists(atPath: stateURL.path) else {
                    throw BridgeError.invalid("Requires the isolated integration bundle/vault and no existing test-vault app state.")
                }
                ownsTestState = true
                UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
                UserDefaults.standard.set(try vault.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "vaultBookmark")
                record("RUNNING: awaiting Reminders permission and first native sync")
                let c = SyncController(); controller = c
                try await until("first native sync", timeout: 120) {
                    await c.sync()
                    return FileManager.default.fileExists(atPath: stateURL.path) && !c.busy && c.taskCount == 3 && c.lastSuccessfulSync != nil
                }
                let state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
                guard let calendarID = state["calendarID"] as? String,
                      let calendar = store.calendar(withIdentifier: calendarID), calendar.title == "Obsidian" else {
                    throw BridgeError.invalid("Native app did not create the isolated test list.")
                }
                testCalendar = calendar
                let initial = try await fetch(store, calendar)
                let managed = try initial.filter { try managedTaskID(url: $0.url, notes: $0.notes) != nil }
                try check(managed.count == 3, "Expected exactly three selected reminders, got \(managed.count). Status: \(c.status)")
                guard let due = managed.first(where: { $0.title == "Integration due" }),
                      let taskID = try managedTaskID(url: due.url, notes: due.notes),
                      let scheduled = managed.first(where: { $0.title == "Integration scheduled" }) else {
                    throw BridgeError.invalid("Expected fixture reminders were not found.")
                }
                try check((due.notes ?? "").isEmpty, "Reminder notes must not contain UUIDs or technical paths")
                try check(due.dueDateComponents != nil && due.url?.scheme == "obsidian", "Due date/deep link missing")
                try check(scheduled.dueDateComponents == nil && scheduled.notes?.contains("Scheduled:") == true, "Scheduled date must not become a deadline")
                record("PASS native EventKit creation, clean notes, due/scheduled dates and Obsidian deep link")
                let mailbox = vault.appendingPathComponent(".obsidian/plugins/obsidian-reminders-companion/bridge")
                func snapshot() throws -> Snapshot { try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: mailbox.appendingPathComponent("snapshot.json"))) }
                func hasNoPending() -> Bool {
                    guard let data = try? Data(contentsOf: stateURL),
                          let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let mappings = state["mappings"] as? [String: [String: Any]] else { return false }
                    return mappings.values.allSatisfy { $0["pending"] == nil || $0["pending"] is NSNull }
                }
                c.paused = true
                try await until("idle before list rename") { !c.busy }
                await c.saveListName("Obsidian Test List")
                c.paused = false
                try await until("list rename in place") {
                    await c.sync()
                    return store.calendar(withIdentifier: calendarID)?.title == "Obsidian Test List"
                }
                let renamedState = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
                try check(renamedState["calendarID"] as? String == calendarID, "Renaming must not create another list")
                c.paused = true
                try await until("idle before restoring list name") { !c.busy }
                await c.saveListName("Obsidian")
                c.paused = false
                try await until("restore list name") { await c.sync(); return store.calendar(withIdentifier: calendarID)?.title == "Obsidian" }
                record("PASS configurable list name renames the same managed list")
                // Exercise production controller protection for an unresolved identity.
                c.paused = true
                try await until("native controller idle before paused-identity test") { !c.busy }
                let snapshotURL = mailbox.appendingPathComponent("snapshot.json")
                let originalSnapshot = try Data(contentsOf: snapshotURL)
                let original = try snapshot()
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var uncertain = Snapshot(version: 2, generatedAt: formatter.string(from: Date()), vault: original.vault, tasks: original.tasks.filter { $0.id != taskID })
                uncertain.pausedTaskIDs = [taskID]
                // Simulate an old version's technical notes during a paused link.
                due.notes = "obsidian-reminders-bridge:\(taskID)\nObsidian: Project.md"
                var legacyURL = URLComponents(url: due.url!, resolvingAgainstBaseURL: false)!
                legacyURL.queryItems = legacyURL.queryItems?.filter { $0.name != "bridgeTask" }
                due.url = legacyURL.url
                due.isCompleted = true; try store.save(due, commit: true)
                try JSONEncoder().encode(uncertain).write(to: snapshotURL, options: .atomic)
                c.paused = false
                await c.sync()
                c.paused = true
                try check(c.uncertainCount == 1, "Controller did not accept paused identity snapshot: \(c.status)")
                try check(try await fetch(store, calendar).contains { $0.calendarItemIdentifier == due.calendarItemIdentifier && $0.isCompleted }, "Uncertain reminder was deleted or overwritten")
                try check(hasNoPending(), "Uncertain identity must not create a completion command")
                let cleaned = try await fetch(store, calendar).first { $0.calendarItemIdentifier == due.calendarItemIdentifier }
                let cleanedID = try managedTaskID(url: cleaned?.url, notes: cleaned?.notes)
                try check((cleaned?.notes ?? "").isEmpty && cleanedID == taskID, "Legacy identity must migrate without losing the reminder or changing completion")
                due.isCompleted = false; due.completionDate = nil; try store.save(due, commit: true)
                try originalSnapshot.write(to: snapshotURL, options: .atomic)
                c.paused = false
                record("PASS uncertain identity freezes native deletion/completion while legacy technical notes migrate safely")
                due.isCompleted = true; try store.save(due, commit: true)
                try await until("Reminders → Obsidian completion") {
                    await c.sync()
                    return (try? snapshot().tasks.first(where: { $0.id == taskID })?.completed) == true && hasNoPending()
                }
                record("PASS Reminders → Obsidian completion and durable acknowledgement")
                due.isCompleted = false; due.completionDate = nil; try store.save(due, commit: true)
                try await until("Reminders → Obsidian reopening") {
                    await c.sync()
                    return (try? snapshot().tasks.first(where: { $0.id == taskID })?.completed) == false && hasNoPending()
                }
                record("PASS Reminders → Obsidian reopening without duplicate")
                let noteURL = vault.appendingPathComponent("Project.md")
                var note = try String(contentsOf: noteURL, encoding: .utf8)
                note = note.replacingOccurrences(of: "Integration due", with: "Integration due edited")
                let newDate = Calendar.current.date(byAdding: .day, value: 3, to: Date())!
                let dateFormatter = DateFormatter(); dateFormatter.dateFormat = "yyyy-MM-dd"
                let newDue = dateFormatter.string(from: newDate)
                note = note.components(separatedBy: "\n").map { line in
                    line.contains("Integration due edited") ? line.replacingOccurrences(of: "📅 [0-9]{4}-[0-9]{2}-[0-9]{2}", with: "📅 \(newDue)", options: .regularExpression) : line
                }.joined(separator: "\n")
                try note.write(to: noteURL, atomically: true, encoding: .utf8)
                let expectedDay = Calendar.current.component(.day, from: newDate)
                try await until("automatic Obsidian title/date edit") {
                    return try await fetch(store, calendar).contains { $0.title == "Integration due edited" && $0.dueDateComponents?.day == expectedDay }
                }
                record("PASS Obsidian → Reminders title/date update retaining identity")
                note = try String(contentsOf: noteURL, encoding: .utf8)
                note = note.replacingOccurrences(of: "- [ ] Integration due edited", with: "- [x] Integration due edited")
                try note.write(to: noteURL, atomically: true, encoding: .utf8)
                try await until("Obsidian → Reminders completion") {
                    await c.sync()
                    return try await fetch(store, calendar).contains { $0.title == "Integration due edited" && $0.isCompleted }
                }
                record("PASS Obsidian → Reminders completion outside not-done query")
                note = try String(contentsOf: noteURL, encoding: .utf8)
                note = note.replacingOccurrences(of: "- [x] Integration due edited", with: "- [ ] Integration due edited")
                try note.write(to: noteURL, atomically: true, encoding: .utf8)
                try await until("Obsidian → Reminders reopening") {
                    await c.sync()
                    return try await fetch(store, calendar).contains { $0.title == "Integration due edited" && !$0.isCompleted }
                }
                record("PASS Obsidian → Reminders reopening")
                c.paused = true
                try await until("idle before no-op sync") { !c.busy }
                guard let beforeNoOp = try await fetch(store, calendar).first(where: { $0.calendarItemIdentifier == due.calendarItemIdentifier })?.lastModifiedDate else {
                    throw BridgeError.invalid("Expected reminder modification timestamp")
                }
                try await Task.sleep(nanoseconds: 1_100_000_000)
                var activityStates: [Bool] = []
                let activityObserver = c.$syncing.sink { activityStates.append($0) }
                var summaryChanges = 0
                let summaryObserver = c.$status.dropFirst().sink { _ in summaryChanges += 1 }
                c.paused = false
                await c.sync()
                c.paused = true
                activityObserver.cancel()
                summaryObserver.cancel()
                try check(!activityStates.contains(true), "Fast background refresh must not flash the Syncing indicator: \(activityStates)")
                try check(summaryChanges == 0, "No-op refresh must not republish an unchanged summary")
                try await until("idle after no-op sync") { !c.busy }
                let afterNoOp = try await fetch(store, calendar).first(where: { $0.calendarItemIdentifier == due.calendarItemIdentifier })?.lastModifiedDate
                try check(afterNoOp == beforeNoOp, "Unchanged reminders must not be repeatedly saved when EventKit normalizes empty notes")
                c.paused = false
                record("PASS no-op sync leaves reminder modification dates untouched and does not flash activity")
                await c.sync(userInitiated: true)
                try check(c.syncing, "Manual sync must show immediate activity feedback")
                try await Task.sleep(nanoseconds: 600_000_000)
                try check(!c.syncing, "Manual activity must settle after completion")
                record("PASS manual sync shows activity without a transient blink")
                let unmanaged = EKReminder(eventStore: store)
                unmanaged.calendar = calendar; unmanaged.title = "Unmanaged integration fixture"
                try store.save(unmanaged, commit: true)
                note = try String(contentsOf: noteURL, encoding: .utf8)
                note = note.replacingOccurrences(of: "type: project", with: "type: excluded")
                try note.write(to: noteURL, atomically: true, encoding: .utf8)
                try await until("query departure removes only managed reminders") {
                    await c.sync()
                    let remaining = try await fetch(store, calendar)
                    return remaining.count == 1 && remaining[0].calendarItemIdentifier == unmanaged.calendarItemIdentifier
                }
                record("PASS query departure cleanup; unrelated reminder untouched")
                succeeded = true
            } catch { record("FAIL: \(error.localizedDescription)\nNative status: \(controller?.status ?? "not started")") }
            controller?.paused = true
            // Recover cleanup identity if the first sync failed after creating its list.
            if ownsTestState && testCalendar == nil,
               let data = try? Data(contentsOf: stateURL),
               let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = state["calendarID"] as? String,
               let calendar = store.calendar(withIdentifier: id), calendar.title == "Obsidian" {
                testCalendar = calendar
            }
            // Only remove the list whose identity was read from the isolated vault's own state.
            if let calendar = testCalendar {
                do { try store.removeCalendar(calendar, commit: true); record("CLEANUP: removed disposable test list") }
                catch { record("CLEANUP FAILED: \(error.localizedDescription)"); succeeded = false }
            }
            if ownsTestState && testCalendar != nil { try? FileManager.default.removeItem(at: stateURL) }
            UserDefaults.standard.removePersistentDomain(forName: "ch.lucachristen.obsidian-reminders-bridge.integration")
            record(succeeded ? "RESULT: PASS" : "RESULT: FAIL")
            exit(succeeded ? 0 : 1)
        }
        app.run()
    }
    static func check(_ condition: Bool, _ message: String) throws { if !condition { throw BridgeError.invalid(message) } }
    static func until(_ message: String, timeout: TimeInterval = 45, predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try await predicate() { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        } while Date() < deadline
        throw BridgeError.invalid("Timed out: \(message)")
    }
    static func fetch(_ store: EKEventStore, _ calendar: EKCalendar) async throws -> [EKReminder] {
        try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: [calendar])) { reminders in
                if let reminders { continuation.resume(returning: reminders.filter { $0.refresh() }) }
                else { continuation.resume(throwing: BridgeError.invalid("EventKit fetch failed")) }
            }
        }
    }
}
