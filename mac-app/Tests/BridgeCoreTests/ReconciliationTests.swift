import XCTest
@testable import BridgeCore

final class ReconciliationTests: XCTestCase {
    private let id = "11111111-1111-4111-a111-111111111111"
    private func task(_ done: Bool = false, selected: Bool = true) -> BridgeTask {
        BridgeTask(id: id, completed: done, selected: selected)
    }
    private func mapping(_ done: Bool = false) -> Mapping { Mapping(reminderID: "reminder", lastCompleted: done) }
    func testCreatesOnlySelectedTasks() {
        XCTAssertEqual(decide(task: task(), mapping: nil, reminderCompleted: nil), .create)
        XCTAssertEqual(decide(task: task(selected: false), mapping: nil, reminderCompleted: nil), .ignore)
    }
    func testReminderCompletionWritesBackBeforeQueryRemoval() {
        XCTAssertEqual(decide(task: task(), mapping: mapping(), reminderCompleted: true), .completeObsidian(true))
        XCTAssertEqual(decide(task: task(selected: false), mapping: mapping(), reminderCompleted: true), .completeObsidian(true))
    }
    func testCompletedTasksRemainLinkedOutsideNotDoneQuery() {
        XCTAssertEqual(decide(task: task(true, selected: false), mapping: mapping(), reminderCompleted: false), .updateFromObsidian)
    }
    func testReopeningReminderWritesBack() {
        XCTAssertEqual(decide(task: task(true, selected: false), mapping: mapping(true), reminderCompleted: false), .completeObsidian(false))
    }
    func testObsidianReopeningWins() {
        XCTAssertEqual(decide(task: task(), mapping: mapping(true), reminderCompleted: true), .updateFromObsidian)
    }
    func testNonmatchingOpenTasksAreRemoved() {
        XCTAssertEqual(decide(task: task(selected: false), mapping: mapping(), reminderCompleted: false), .remove)
    }
    func testDeletedTasksRemoveOnlyMappedReminders() {
        XCTAssertEqual(decide(task: nil, mapping: mapping(), reminderCompleted: true), .remove)
        XCTAssertEqual(decide(task: nil, mapping: nil, reminderCompleted: true), .ignore)
    }
    func testDeletedSelectedRemindersAreRecreated() {
        XCTAssertEqual(decide(task: task(), mapping: mapping(), reminderCompleted: nil), .create)
    }
    func testPendingCommandsPreventStaleSnapshotOverwrite() {
        var linked = mapping()
        linked.pending = CompletionCommand(taskId: id, completed: true, expectedCompleted: false)
        XCTAssertEqual(decide(task: task(), mapping: linked, reminderCompleted: true), .wait)
        XCTAssertEqual(decide(task: nil, mapping: linked, reminderCompleted: nil), .wait)
    }
    func testSnapshotFreshnessAndDuplicateValidation() throws {
        let now = Date()
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fresh = Snapshot(version: 1, generatedAt: formatter.string(from: now), vault: "Test", tasks: [task()])
        XCTAssertNoThrow(try fresh.validate(now: now))
        XCTAssertThrowsError(try fresh.validate(now: now.addingTimeInterval(100)))
        let duplicate = Snapshot(version: 1, generatedAt: fresh.generatedAt, vault: "Test", tasks: [task(), task()])
        XCTAssertThrowsError(try duplicate.validate(now: now))
        let future = Snapshot(version: 1, generatedAt: formatter.string(from: now.addingTimeInterval(60)), vault: "Test", tasks: [])
        XCTAssertThrowsError(try future.validate(now: now))
    }
}
