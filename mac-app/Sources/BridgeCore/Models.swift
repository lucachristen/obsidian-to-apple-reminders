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
public struct Snapshot: Codable {
    public let version: Int
    public let generatedAt: String
    public let vault: String
    public let tasks: [BridgeTask]
    public func validate(now: Date = Date()) throws {
        guard version == 1 else { throw BridgeError.invalid("Unsupported bridge protocol.") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: generatedAt), now.timeIntervalSince(date) < 90,
              now.timeIntervalSince(date) > -30 else {
            throw BridgeError.invalid("Obsidian snapshot is stale. Keep Obsidian and its companion plugin running.")
        }
        guard Set(tasks.map(\.id)).count == tasks.count, tasks.allSatisfy({ UUID(uuidString: $0.id) != nil }) else {
            throw BridgeError.invalid("Invalid or duplicate task IDs. Sync paused.")
        }
    }
}
public enum BridgeError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
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
public func decide(task: BridgeTask?, mapping: Mapping?, reminderCompleted: Bool?) -> SyncDecision {
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
