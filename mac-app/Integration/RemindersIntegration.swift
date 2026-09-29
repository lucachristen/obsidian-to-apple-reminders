// Executed only by scripts/test-reminders.sh in a separately identified, disposable app bundle.
import AppKit
import BridgeCore
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
                    return FileManager.default.fileExists(atPath: stateURL.path) && !c.busy && c.status.hasPrefix("3 selected")
                }
                let state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
                guard let calendarID = state["calendarID"] as? String,
                      let calendar = store.calendar(withIdentifier: calendarID), calendar.title == "Obsidian — integration-vault" else {
                    throw BridgeError.invalid("Native app did not create the isolated test list.")
                }
                testCalendar = calendar
                let initial = try await fetch(store, calendar)
                let managed = initial.filter { $0.notes?.contains("obsidian-reminders-bridge:") == true }
                try check(managed.count == 3, "Expected exactly three selected reminders, got \(managed.count). Status: \(c.status)")
                guard let due = managed.first(where: { $0.title == "Integration due" }),
                      let idLine = due.notes?.components(separatedBy: "\n").first,
                      let scheduled = managed.first(where: { $0.title == "Integration scheduled" }) else {
                    throw BridgeError.invalid("Expected fixture reminders were not found.")
                }
                let taskID = String(idLine.dropFirst("obsidian-reminders-bridge:".count))
                try check(due.dueDateComponents != nil && due.url?.scheme == "obsidian", "Due date/deep link missing")
                try check(scheduled.dueDateComponents == nil && scheduled.notes?.contains("Scheduled:") == true, "Scheduled date must not become a deadline")
                record("PASS native EventKit creation, due/scheduled dates and Obsidian deep link")
                let mailbox = vault.appendingPathComponent(".obsidian/plugins/obsidian-reminders-companion/bridge")
                func snapshot() throws -> Snapshot { try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: mailbox.appendingPathComponent("snapshot.json"))) }
                func hasNoPending() -> Bool {
                    guard let data = try? Data(contentsOf: stateURL),
                          let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let mappings = state["mappings"] as? [String: [String: Any]] else { return false }
                    return mappings.values.allSatisfy { $0["pending"] == nil || $0["pending"] is NSNull }
                }
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
                    line.contains(taskID) ? line.replacingOccurrences(of: "📅 [0-9]{4}-[0-9]{2}-[0-9]{2}", with: "📅 \(newDue)", options: .regularExpression) : line
                }.joined(separator: "\n")
                try note.write(to: noteURL, atomically: true, encoding: .utf8)
                let expectedDay = Calendar.current.component(.day, from: newDate)
                try await until("Obsidian title/date edit") {
                    await c.sync()
                    return try await fetch(store, calendar).contains { $0.title == "Integration due edited" && $0.dueDateComponents?.day == expectedDay }
                }
                record("PASS Obsidian → Reminders title/date update retaining identity")
                note = try String(contentsOf: noteURL, encoding: .utf8)
                note = note.replacingOccurrences(of: "[ ] <!-- reminders:\(taskID) -->", with: "[x] <!-- reminders:\(taskID) -->")
                try note.write(to: noteURL, atomically: true, encoding: .utf8)
                try await until("Obsidian → Reminders completion") {
                    await c.sync()
                    return try await fetch(store, calendar).contains { $0.title == "Integration due edited" && $0.isCompleted }
                }
                record("PASS Obsidian → Reminders completion outside not-done query")
                note = try String(contentsOf: noteURL, encoding: .utf8)
                note = note.replacingOccurrences(of: "[x] <!-- reminders:\(taskID) -->", with: "[ ] <!-- reminders:\(taskID) -->")
                try note.write(to: noteURL, atomically: true, encoding: .utf8)
                try await until("Obsidian → Reminders reopening") {
                    await c.sync()
                    return try await fetch(store, calendar).contains { $0.title == "Integration due edited" && !$0.isCompleted }
                }
                record("PASS Obsidian → Reminders reopening")
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
               let calendar = store.calendar(withIdentifier: id), calendar.title == "Obsidian — integration-vault" {
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
                if let reminders { continuation.resume(returning: reminders) }
                else { continuation.resume(throwing: BridgeError.invalid("EventKit fetch failed")) }
            }
        }
    }
}
