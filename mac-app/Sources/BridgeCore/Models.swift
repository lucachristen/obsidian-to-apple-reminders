import Foundation

public struct BridgeTask: Codable, Equatable {
    public let id: String
    public let path: String
    public let title: String
    public let completed: Bool
    public let selected: Bool
    public let due: String?
    public let scheduled: String?
    public let priority: Int
    public init(id: String, path: String = "Tasks.md", title: String = "Task", completed: Bool, selected: Bool, due: String? = nil, scheduled: String? = nil, priority: Int = 3) {
        self.id = id; self.path = path; self.title = title; self.completed = completed
        self.selected = selected; self.due = due; self.scheduled = scheduled; self.priority = priority
    }
}
public struct PausedTask: Codable, Equatable {
    public let id: String
    public let path: String
    public let title: String
}
public struct Snapshot: Codable {
    public let version: Int
    public let generatedAt: String
    public let vault: String
    public let tasks: [BridgeTask]
    public var pausedTaskIDs: [String]? = nil
    public var pausedTasks: [PausedTask]? = nil
    public init(version: Int, generatedAt: String, vault: String, tasks: [BridgeTask], pausedTaskIDs: [String]? = nil, pausedTasks: [PausedTask]? = nil) {
        self.version = version; self.generatedAt = generatedAt; self.vault = vault
        self.tasks = tasks; self.pausedTaskIDs = pausedTaskIDs; self.pausedTasks = pausedTasks
    }
    public func validate(now: Date = Date()) throws {
        guard version == 1 || version == 2 || version == 3 else { throw BridgeError.invalid("Unsupported bridge protocol. Update both the plugin and Mac app.") }
        if version >= 2 && pausedTaskIDs == nil { throw BridgeError.invalid("Missing paused identity list. Sync paused.") }
        if version == 3 && pausedTasks == nil { throw BridgeError.invalid("Missing task review details. Update the Reminders Bridge plugin in Obsidian.") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: generatedAt), now.timeIntervalSince(date) < 90,
              now.timeIntervalSince(date) > -30 else {
            throw BridgeError.obsidianUnavailable
        }
        guard Set(tasks.map(\.id)).count == tasks.count, tasks.allSatisfy({ UUID(uuidString: $0.id) != nil }) else {
            throw BridgeError.invalid("Invalid or duplicate task IDs. Sync paused.")
        }
        let paused = pausedTaskIDs ?? []
        guard Set(paused).count == paused.count, paused.allSatisfy({ UUID(uuidString: $0) != nil }),
              Set(paused).isDisjoint(with: Set(tasks.map(\.id))) else {
            throw BridgeError.invalid("Invalid paused task IDs. Sync paused.")
        }
        if let details = pausedTasks {
            guard details.count == paused.count, Set(details.map(\.id)) == Set(paused) else {
                throw BridgeError.invalid("Invalid task review details. Sync paused.")
            }
        }
    }
}
public enum BridgeError: LocalizedError {
    /// A real problem the user has to look at.
    case invalid(String)
    /// Obsidian isn't running or hasn't written a fresh snapshot. Not a fault.
    case obsidianUnavailable
    /// Something moved underneath us mid-sync; the next pass will succeed.
    case retry
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .obsidianUnavailable: return "Open your vault in Obsidian to sync."
        case .retry: return "Sync will retry shortly."
        }
    }
}
public struct CompletionCommand: Codable {
    public let version: Int
    public let id: String
    public let taskId: String
    public let completed: Bool
    public let expectedCompleted: Bool
    public init(taskId: String, completed: Bool, expectedCompleted: Bool) {
        version = 1; id = UUID().uuidString.lowercased(); self.taskId = taskId
        self.completed = completed; self.expectedCompleted = expectedCompleted
    }
}
public struct Mapping: Codable {
    public var reminderID: String
    public var lastCompleted: Bool
    public var pending: CompletionCommand?
    public init(reminderID: String, lastCompleted: Bool, pending: CompletionCommand? = nil) {
        self.reminderID = reminderID; self.lastCompleted = lastCompleted; self.pending = pending
    }
}
public enum SyncDecision: Equatable {
    case create, updateFromObsidian, completeObsidian(Bool), remove, wait, ignore
}

/// Three-way completion reconciliation. Metadata always belongs to Obsidian.
public func decide(task: BridgeTask?, mapping: Mapping?, reminderCompleted: Bool?, identityPaused: Bool = false) -> SyncDecision {
    if identityPaused { return .wait }
    if mapping?.pending != nil { return .wait }
    guard let task else { return mapping == nil ? .ignore : .remove }
    guard let mapping else { return task.selected ? .create : .ignore }
    if let completed = reminderCompleted,
       completed != mapping.lastCompleted, task.completed == mapping.lastCompleted {
        return .completeObsidian(completed)
    }
    // Complete first even though `not done` now excludes the task.
    if task.completed { return .updateFromObsidian }
    if !task.selected { return .remove }
    // Deleting an app-managed reminder recreates it while its task is selected.
    return reminderCompleted == nil ? .create : .updateFromObsidian
}
