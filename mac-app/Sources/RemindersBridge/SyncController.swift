import AppKit
import BridgeCore
import CryptoKit
import EventKit
import Foundation
import ServiceManagement
import SwiftUI

private struct SavedState: Codable {
    var calendarID: String?
    var mappings: [String: Mapping] = [:]
}
private struct Acknowledgement: Decodable { let id: String; let error: String?; let processedAt: String }

@MainActor
final class SyncController: ObservableObject {
    @Published var status = "Choose your Obsidian vault to begin."
    @Published var vaultPath = ""
    @Published var busy = false
    @Published var paused = false
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    private let store = EKEventStore()
    private var vaultURL: URL?
    private var scopedURL: URL?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var state = SavedState()
    private var stateReady = false
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }()
    private let decoder = JSONDecoder()
    private var bridgeURL: URL? {
        vaultURL?.appendingPathComponent("\(configDirectory)/plugins/obsidian-reminders-companion/bridge", isDirectory: true)
    }
    @Published private(set) var configDirectory: String = UserDefaults.standard.string(forKey: "configDirectory") ?? ".obsidian"
    private var stateURL: URL? {
        guard let vaultURL else { return nil }
        let hash = SHA256.hash(data: Data((vaultURL.path + "/" + configDirectory).utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ObsidianRemindersBridge/\(hash).json")
    }
    init() {
        if let bookmark = UserDefaults.standard.data(forKey: "vaultBookmark") {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
                try useVault(url)
                if stale { try saveBookmark(url) }
            } catch { status = "Reselect your vault: \(error.localizedDescription)" }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
        Task { await sync() }
    }
    func chooseVault() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.message = "Select the root folder of your Obsidian vault."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            do { try saveBookmark(url); try useVault(url); Task { await sync() } }
            catch { status = error.localizedDescription }
        }
    }
    private func saveBookmark(_ url: URL) throws {
        UserDefaults.standard.set(try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "vaultBookmark")
    }
    private func useVault(_ url: URL) throws {
        stateReady = false
        scopedURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() { scopedURL = url } else { scopedURL = nil }
        vaultURL = url; vaultPath = url.path
        state = SavedState()
        if let stateURL, FileManager.default.fileExists(atPath: stateURL.path) {
            state = try decoder.decode(SavedState.self, from: Data(contentsOf: stateURL))
        }
        stateReady = true
        status = "Vault selected. Waiting for Obsidian."
    }
    func saveConfiguration(_ directory: String) {
        guard !busy else { return }
        // Only a single directory name is permitted, never traversal outside the vault.
        guard !directory.isEmpty, !directory.contains("/"), directory != "..", directory != "." else {
            status = "Enter a single configuration folder name, usually .obsidian."; return
        }
        configDirectory = directory
        UserDefaults.standard.set(configDirectory, forKey: "configDirectory")
        if let vaultURL { do { try useVault(vaultURL) } catch { status = error.localizedDescription } }
        Task { await sync() }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
        } catch { status = "Login item: \(error.localizedDescription)"; loginEnabled = false }
    }
    private func persist() throws {
        guard let stateURL else { return }
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }
    private func calendar(vault: String) throws -> EKCalendar {
        if let id = state.calendarID {
            guard let calendar = store.calendar(withIdentifier: id), calendar.allowsContentModifications else {
                throw BridgeError.invalid("The bridge Reminders list is missing or read-only. Restore it before syncing.")
            }
            return calendar
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = "Obsidian — \(vault)"
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw BridgeError.invalid("Create a writable Reminders list first, then try again.")
        }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        state.calendarID = calendar.calendarIdentifier
        try persist()
        return calendar
    }
    private func fetch(_ calendar: EKCalendar) async throws -> [EKReminder] {
        let predicate = store.predicateForReminders(in: [calendar])
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                if let reminders { continuation.resume(returning: reminders) }
                else { continuation.resume(throwing: BridgeError.invalid("Reminders could not be fetched. No changes made.")) }
            }
        }
    }
    private func marker(_ id: String) -> String { "obsidian-reminders-bridge:\(id)" }
    private func managedID(_ reminder: EKReminder) -> String? {
        guard let line = reminder.notes?.components(separatedBy: "\n").first(where: { $0.hasPrefix("obsidian-reminders-bridge:") }) else { return nil }
        let id = String(line.dropFirst("obsidian-reminders-bridge:".count))
        return UUID(uuidString: id) == nil ? nil : id
    }
    private func apply(_ task: BridgeTask, to reminder: EKReminder, snapshot: Snapshot) throws {
        reminder.title = task.title
        reminder.isCompleted = task.completed
        if !task.completed { reminder.completionDate = nil }
        reminder.dueDateComponents = try dateComponents(task.due)
        // Tasks priorities: highest=0, high=1, medium=2, normal=3, low=4, lowest=5.
        reminder.priority = task.priority <= 1 ? 1 : task.priority == 2 ? 5 : task.priority >= 4 ? 9 : 0
        reminder.notes = [marker(task.id), "Obsidian: \(task.path)", task.scheduled.map { "Scheduled: \($0)" }]
            .compactMap { $0 }.joined(separator: "\n")
        var url = URLComponents(); url.scheme = "obsidian"; url.host = "open"
        url.queryItems = [URLQueryItem(name: "vault", value: snapshot.vault), URLQueryItem(name: "file", value: task.path)]
        reminder.url = url.url
        try store.save(reminder, commit: true)
    }
    private func dateComponents(_ value: String?) throws -> DateComponents? {
        guard let value else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else {
            throw BridgeError.invalid("Invalid task date: \(value)")
        }
        return DateComponents(calendar: Calendar.current, year: parts[0], month: parts[1], day: parts[2])
    }
    func sync() async {
        guard !busy, !paused, stateReady, let bridgeURL else { return }
        busy = true; defer { busy = false }
        do {
            let errorURL = bridgeURL.appendingPathComponent("error.json")
            if FileManager.default.fileExists(atPath: errorURL.path) {
                let error = try JSONSerialization.jsonObject(with: Data(contentsOf: errorURL)) as? [String: String]
                throw BridgeError.invalid(error?["message"] ?? "Obsidian reported a sync error.")
            }
            let snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: bridgeURL.appendingPathComponent("snapshot.json")))
            try snapshot.validate()
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .fullAccess: break
            case .notDetermined:
                guard try await store.requestFullAccessToReminders() else { throw BridgeError.invalid("Reminders access was denied.") }
            default: throw BridgeError.invalid("Allow Reminders access in System Settings → Privacy & Security → Reminders.")
            }
            let calendar = try calendar(vault: snapshot.vault)
            let reminders = try await fetch(calendar)
            // Revalidate freshness after an authorization prompt or an asynchronous fetch.
            try snapshot.validate()
            if FileManager.default.fileExists(atPath: errorURL.path) { throw BridgeError.invalid("Obsidian paused syncing. Try again after resolving its error.") }
            var owned: [String: EKReminder] = [:]
            for reminder in reminders {
                guard let id = managedID(reminder) else { continue }
                guard owned[id] == nil else { throw BridgeError.invalid("Duplicate managed reminders found. Remove the duplicate before syncing.") }
                owned[id] = reminder
            }
            let tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
            // Recover identity after a crash between saving a reminder and saving local state.
            for (id, reminder) in owned where state.mappings[id] == nil {
                state.mappings[id] = Mapping(reminderID: reminder.calendarItemIdentifier, lastCompleted: tasks[id]?.completed ?? reminder.isCompleted)
            }
            for id in Set(tasks.keys).union(state.mappings.keys).sorted() {
                let task = tasks[id]
                let reminder = owned[id]
                if let pending = state.mappings[id]?.pending {
                    let commandURL = bridgeURL.appendingPathComponent("commands/\(pending.id).json")
                    let ackURL = bridgeURL.appendingPathComponent("acks/\(pending.id).json")
                    if FileManager.default.fileExists(atPath: ackURL.path) {
                        let ack = try decoder.decode(Acknowledgement.self, from: Data(contentsOf: ackURL))
                        guard ack.id == pending.id else { throw BridgeError.invalid("Invalid completion acknowledgement.") }
                        if let error = ack.error {
                            // Restore Obsidian truth and expose the rejected command rather than retry forever.
                            if let task, let reminder { try apply(task, to: reminder, snapshot: snapshot) }
                            state.mappings[id]?.pending = nil
                            state.mappings[id]?.lastCompleted = task?.completed ?? pending.expectedCompleted
                            try persist()
                            try? FileManager.default.removeItem(at: commandURL); try? FileManager.default.removeItem(at: ackURL)
                            throw BridgeError.invalid("Completion rejected: \(error)")
                        }
                        // Only consume an acknowledgement after a newer cache snapshot.
                        // This also permits deletion or another edit immediately after completion.
                        if snapshot.generatedAt > ack.processedAt {
                            state.mappings[id]?.pending = nil
                            state.mappings[id]?.lastCompleted = pending.completed
                            try persist()
                            try? FileManager.default.removeItem(at: commandURL); try? FileManager.default.removeItem(at: ackURL)
                        }
                    } else {
                        try encoder.encode(pending).write(to: commandURL, options: .atomic)
                    }
                    continue
                }
                switch decide(task: task, mapping: state.mappings[id], reminderCompleted: reminder?.isCompleted) {
                case .ignore, .wait: break
                case .remove:
                    if let reminder { try store.remove(reminder, commit: true) }
                    state.mappings.removeValue(forKey: id)
                case .completeObsidian(let completed):
                    guard let task else { continue }
                    let command = CompletionCommand(taskId: id, completed: completed, expectedCompleted: task.completed)
                    state.mappings[id]?.pending = command
                    try persist() // Durable before publishing; resend on restart if necessary.
                    try encoder.encode(command).write(to: bridgeURL.appendingPathComponent("commands/\(command.id).json"), options: .atomic)
                case .create, .updateFromObsidian:
                    guard let task else { continue }
                    // Completed reminders manually deleted by the user need not be recreated.
                    if reminder == nil && !task.selected && task.completed { continue }
                    let target = reminder ?? EKReminder(eventStore: store)
                    target.calendar = calendar
                    try apply(task, to: target, snapshot: snapshot)
                    state.mappings[id] = Mapping(reminderID: target.calendarItemIdentifier, lastCompleted: task.completed)
                }
                try persist()
            }
            let pending = state.mappings.values.filter { $0.pending != nil }.count
            status = "\(snapshot.tasks.filter(\.selected).count) selected · \(pending) pending · \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            status = "Sync paused: \(error.localizedDescription)"
        }
    }
}
