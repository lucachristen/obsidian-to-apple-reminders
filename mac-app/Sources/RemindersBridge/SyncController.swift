import AppKit
import BridgeCore
import CryptoKit
import EventKit
import Darwin
import Foundation
import ServiceManagement
import SwiftUI

private struct SavedState: Codable {
    var calendarID: String?
    var listName: String?
    var mappings: [String: Mapping] = [:]
}
private struct Acknowledgement: Decodable { let id: String; let error: String?; let processedAt: String }

/// The one action that resolves the current error, offered next to it in the menu.
enum SyncFix { case openObsidian, allowRemindersAccess, chooseVault }

@MainActor
final class SyncController: ObservableObject {
    @Published private(set) var status = "Choose a vault"
    @Published private(set) var lastSuccessfulSync: Date?
    @Published private(set) var taskCount = 0
    @Published private(set) var pendingCount = 0
    @Published private(set) var uncertainCount = 0
    @Published private(set) var tasksNeedingReview: [PausedTask] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var errorFix: SyncFix?
    /// Obsidian is closed or not sending updates. Expected, so never shown as an error.
    @Published private(set) var waitingForObsidian = false
    @Published private(set) var listName = "Obsidian"
    @Published var vaultPath = ""
    private(set) var busy = false
    @Published private(set) var syncing = false
    private var syncActivity = SyncActivity()
    private var activityTransition: Task<Void, Never>?
    @Published var paused = UserDefaults.standard.bool(forKey: "syncPaused") {
        didSet { UserDefaults.standard.set(paused, forKey: "syncPaused") }
    }
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    private let store = EKEventStore()
    private var vaultURL: URL?
    private var scopedURL: URL?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var mailboxWatcher: DispatchSourceFileSystemObject?
    private var scheduledSync: Task<Void, Never>?
    private var resyncRequested = false
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
            } catch { reportError("Can't open your vault. Choose it again.", fix: .chooseVault) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
        Task { await sync() }
    }
    var vaultName: String { vaultURL?.lastPathComponent ?? "No vault selected" }
    private func reportError(_ message: String, fix: SyncFix? = nil) {
        errorMessage = message; errorFix = fix; waitingForObsidian = false; status = "Needs attention"
    }
    private func clearError() {
        if errorMessage != nil { errorMessage = nil; errorFix = nil }
    }
    private func scheduleSync() {
        scheduledSync?.cancel()
        scheduledSync = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            await self?.sync()
        }
    }
    private func startWatchingMailbox() {
        guard mailboxWatcher == nil, let bridgeURL else { return }
        let descriptor = open(bridgeURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return } // Retry on the next periodic pass.
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleSync() }
        }
        source.setCancelHandler { close(descriptor) }
        mailboxWatcher = source
        source.resume()
    }
    func chooseVault() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.message = "Select the root folder of your Obsidian vault."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            do { try saveBookmark(url); try useVault(url); Task { await sync() } }
            catch { reportError(error.localizedDescription) }
        }
    }
    private func saveBookmark(_ url: URL) throws {
        UserDefaults.standard.set(try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "vaultBookmark")
    }
    private func useVault(_ url: URL) throws {
        stateReady = false
        mailboxWatcher?.cancel(); mailboxWatcher = nil
        scheduledSync?.cancel()
        lastSuccessfulSync = nil; taskCount = 0; pendingCount = 0; uncertainCount = 0; tasksNeedingReview = []
        clearError(); waitingForObsidian = false
        scopedURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() { scopedURL = url } else { scopedURL = nil }
        vaultURL = url; vaultPath = url.path
        detectConfigDirectory()
        state = SavedState()
        if let stateURL, FileManager.default.fileExists(atPath: stateURL.path) {
            state = try decoder.decode(SavedState.self, from: Data(contentsOf: stateURL))
        }
        listName = state.listName ?? "Obsidian"
        stateReady = true
        status = "Waiting for Obsidian"
        startWatchingMailbox()
    }
    /// Obsidian lets a vault rename its `.obsidian` folder. Find whichever
    /// hidden folder holds the Reminders Bridge plugin instead of asking the user.
    private func detectConfigDirectory() {
        guard let vaultURL else { return }
        let fileManager = FileManager.default
        func hasPlugin(_ folder: String) -> Bool {
            fileManager.fileExists(atPath: vaultURL.appendingPathComponent("\(folder)/plugins/obsidian-reminders-companion").path)
        }
        guard !hasPlugin(configDirectory) else { return }
        let folders = ((try? fileManager.contentsOfDirectory(atPath: vaultURL.path)) ?? []).filter { $0.hasPrefix(".") }.sorted()
        guard let found = folders.first(where: hasPlugin) else { return }
        configDirectory = found
        UserDefaults.standard.set(found, forKey: "configDirectory")
    }
    func saveConfiguration(_ directory: String) {
        guard !busy else { return }
        // Only a single directory name is permitted, never traversal outside the vault.
        guard !directory.isEmpty, !directory.contains("/"), directory != "..", directory != "." else {
            reportError("Enter a single configuration folder name, usually .obsidian."); return
        }
        configDirectory = directory
        UserDefaults.standard.set(configDirectory, forKey: "configDirectory")
        if let vaultURL { do { try useVault(vaultURL) } catch { reportError(error.localizedDescription) } }
        Task { await sync() }
    }
    func saveListName(_ value: String) async {
        guard !busy, stateReady else { return }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { reportError("Give your Reminders list a name."); return }
        listName = name; state.listName = name
        do { try persist(); await sync() } catch { reportError(error.localizedDescription) }
    }
    func openVault() {
        guard let vaultURL else { return }
        var link = URLComponents(); link.scheme = "obsidian"; link.host = "open"
        link.queryItems = [URLQueryItem(name: "vault", value: vaultURL.lastPathComponent)]
        if let url = link.url { NSWorkspace.shared.open(url) }
    }
    func openReviewLinks() {
        guard let vaultURL else { return }
        var link = URLComponents(); link.scheme = "obsidian"; link.host = "reminders-review-links"
        link.queryItems = [URLQueryItem(name: "vault", value: vaultURL.lastPathComponent)]
        if let url = link.url { NSWorkspace.shared.open(url) }
    }
    func openRemindersPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
        } catch { reportError("Login item: \(error.localizedDescription)"); loginEnabled = false }
    }
    private func persist() throws {
        guard let stateURL else { return }
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }
    private func calendar() throws -> EKCalendar {
        if let id = state.calendarID {
            guard let calendar = store.calendar(withIdentifier: id), calendar.allowsContentModifications else {
                throw BridgeError.invalid("The bridge Reminders list is missing or read-only. Restore it before syncing.")
            }
            if state.listName == nil {
                // Migrate our generated names; preserve an existing user-chosen name.
                if !calendar.title.hasPrefix("Obsidian — ") { listName = calendar.title }
                state.listName = listName
                try persist()
            }
            if calendar.title != listName {
                calendar.title = listName
                try store.saveCalendar(calendar, commit: true)
            }
            return calendar
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = listName
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw BridgeError.invalid("Create a writable Reminders list first, then try again.")
        }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        state.calendarID = calendar.calendarIdentifier
        state.listName = listName
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
    private func apply(_ task: BridgeTask, to reminder: EKReminder, snapshot: Snapshot) throws {
        let due = try dateComponents(task.due)
        let oldDue = reminder.dueDateComponents
        let sameDue = (due == nil && oldDue == nil) || (due != nil && oldDue != nil
            && due?.year == oldDue?.year && due?.month == oldDue?.month && due?.day == oldDue?.day
            && oldDue?.hour == nil && oldDue?.minute == nil)
        // Tasks priorities: highest=0, high=1, medium=2, normal=3, low=4, lowest=5.
        let priority = task.priority <= 1 ? 1 : task.priority == 2 ? 5 : task.priority >= 4 ? 9 : 0
        let content = ReminderContent(task: task, vault: snapshot.vault)
        guard reminder.title != content.title || reminder.isCompleted != task.completed || !sameDue
                || reminder.priority != priority || (reminder.notes ?? "") != (content.notes ?? "") || reminder.url != content.url else { return }
        reminder.title = content.title
        reminder.isCompleted = task.completed
        if !task.completed { reminder.completionDate = nil }
        reminder.dueDateComponents = due
        reminder.priority = priority
        reminder.notes = content.notes
        reminder.url = content.url
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
    private func publishActivity() {
        activityTransition?.cancel()
        if syncing != syncActivity.isVisible { syncing = syncActivity.isVisible }
        guard let deadline = syncActivity.nextTransition else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        activityTransition = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self else { return }
            syncActivity.advance(to: ProcessInfo.processInfo.systemUptime)
            publishActivity()
        }
    }
    func sync(userInitiated: Bool = false) async {
        guard !paused, stateReady, let bridgeURL else { return }
        if busy {
            resyncRequested = true
            if userInitiated {
                syncActivity.begin(at: ProcessInfo.processInfo.systemUptime, userInitiated: true)
                publishActivity()
            }
            return
        }
        busy = true
        syncActivity.begin(at: ProcessInfo.processInfo.systemUptime, userInitiated: userInitiated)
        publishActivity()
        defer {
            busy = false
            syncActivity.finish(at: ProcessInfo.processInfo.systemUptime)
            publishActivity()
            if resyncRequested { resyncRequested = false; scheduleSync() }
        }
        startWatchingMailbox()
        do {
            let errorURL = bridgeURL.appendingPathComponent("error.json")
            if FileManager.default.fileExists(atPath: errorURL.path) {
                let error = try JSONSerialization.jsonObject(with: Data(contentsOf: errorURL)) as? [String: String]
                throw ObsidianReported(message: error?["message"] ?? "Obsidian reported a sync error.")
            }
            let snapshotURL = bridgeURL.appendingPathComponent("snapshot.json")
            guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
                // The plugin may have been installed into a custom config folder since the vault was chosen.
                let previous = configDirectory
                detectConfigDirectory()
                if configDirectory != previous, let vaultURL { try useVault(vaultURL); resyncRequested = true }
                throw BridgeError.obsidianUnavailable
            }
            let snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: snapshotURL))
            try snapshot.validate()
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .fullAccess: break
            case .notDetermined:
                guard try await store.requestFullAccessToReminders() else { throw RemindersAccessDenied() }
            default: throw RemindersAccessDenied()
            }
            let calendar = try calendar()
            let reminders = try await fetch(calendar)
            // EventKit can return cached instances after another process changes them.
            // Reload their saved properties before interpreting completion or ownership.
            guard reminders.allSatisfy({ $0.refresh() }) else {
                throw BridgeError.retry
            }
            // Revalidate freshness after an authorization prompt or an asynchronous fetch.
            try snapshot.validate()
            if FileManager.default.fileExists(atPath: errorURL.path) { throw BridgeError.retry }
            var owned: [String: EKReminder] = [:]
            for reminder in reminders {
                guard let id = try managedTaskID(url: reminder.url, notes: reminder.notes) else { continue }
                guard owned[id] == nil else { throw BridgeError.invalid("Duplicate managed reminders found. Remove the duplicate before syncing.") }
                owned[id] = reminder
            }
            // Ownership-only migration is safe even when task matching is paused.
            // Do not alter titles, dates or completion until reconciliation allows it.
            for (id, reminder) in owned {
                if let migrated = migrateLegacyReminder(url: reminder.url, notes: reminder.notes, id: id, vault: snapshot.vault) {
                    reminder.url = migrated.url; reminder.notes = migrated.notes
                    try store.save(reminder, commit: true)
                }
            }
            let tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
            // Recover identity after a crash between saving a reminder and saving local state.
            for (id, reminder) in owned where state.mappings[id] == nil {
                state.mappings[id] = Mapping(reminderID: reminder.calendarItemIdentifier, lastCompleted: tasks[id]?.completed ?? reminder.isCompleted)
            }
            let pausedIDs = Set(snapshot.pausedTaskIDs ?? [])
            for id in reconciliationOrder(tasks: snapshot.tasks, mappedIDs: Array(state.mappings.keys)) {
                // Uncertain identities are not deletions. Freeze every operation,
                // including acknowledgement consumption and pending command retries.
                if pausedIDs.contains(id) { continue }
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
            let selectedCount = snapshot.tasks.filter(\.selected).count
            let updatingCount = state.mappings.values.filter { $0.pending != nil }.count
            if taskCount != selectedCount { taskCount = selectedCount }
            if pendingCount != updatingCount { pendingCount = updatingCount }
            if uncertainCount != pausedIDs.count { uncertainCount = pausedIDs.count }
            let reviewTasks = snapshot.pausedTasks ?? []
            if tasksNeedingReview != reviewTasks { tasksNeedingReview = reviewTasks }
            lastSuccessfulSync = Date()
            clearError()
            if waitingForObsidian { waitingForObsidian = false }
            let summary = uncertainCount > 0 ? "Some tasks need review" : pendingCount > 0 ? "Finishing changes" : "Up to date"
            if status != summary { status = summary }
        } catch BridgeError.obsidianUnavailable {
            clearError()
            if !waitingForObsidian { waitingForObsidian = true }
        } catch BridgeError.retry {
            // Keep showing the last state; the next timer or Reminders change retries.
        } catch is RemindersAccessDenied {
            reportError("Reminders access is turned off.", fix: .allowRemindersAccess)
        } catch let error as ObsidianReported {
            reportError(error.message, fix: .openObsidian)
        } catch {
            reportError(error.localizedDescription)
        }
    }
}

private struct RemindersAccessDenied: Error { }
private struct ObsidianReported: Error { let message: String }
