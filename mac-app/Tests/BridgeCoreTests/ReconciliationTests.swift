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
    func testUncertainIdentityFreezesDeletionCreationAndCompletion() {
        XCTAssertEqual(decide(task: nil, mapping: mapping(), reminderCompleted: true, identityPaused: true), .wait)
        XCTAssertEqual(decide(task: task(), mapping: nil, reminderCompleted: nil, identityPaused: true), .wait)
        XCTAssertEqual(decide(task: task(), mapping: mapping(), reminderCompleted: true, identityPaused: true), .wait)
    }
    func testV2PausedIdentityValidationAndDecoding() throws {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        func decode(_ fields: String) throws -> Snapshot {
            let json = "{\"version\":2,\"generatedAt\":\"\(timestamp)\",\"vault\":\"Test\",\"tasks\":[],\(fields)}"
            return try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        }
        let paused = try decode("\"pausedTaskIDs\":[\"\(id)\"]")
        XCTAssertEqual(paused.pausedTaskIDs, [id])
        XCTAssertNoThrow(try paused.validate())
        XCTAssertThrowsError(try decode("\"pausedTaskIDs\":null").validate())
        XCTAssertThrowsError(try decode("\"pausedTaskIDs\":[\"invalid\"]").validate())
        XCTAssertThrowsError(try decode("\"pausedTaskIDs\":[\"\(id)\",\"\(id)\"]").validate())
        var overlap = Snapshot(version: 2, generatedAt: timestamp, vault: "Test", tasks: [task()])
        overlap.pausedTaskIDs = [id]
        XCTAssertThrowsError(try overlap.validate())
        var detailed = paused
        detailed.pausedTasks = [PausedTask(id: id, path: "Tasks.md", title: "Call Alex")]
        XCTAssertNoThrow(try detailed.validate())
        detailed.pausedTasks = [PausedTask(id: "22222222-2222-4222-a222-222222222222", path: "Tasks.md", title: "Wrong task")]
        XCTAssertThrowsError(try detailed.validate())
    }
    func testV3RequiresActionableReviewDetailsAndRejectsUnknownVersions() throws {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var snapshot = Snapshot(version: 3, generatedAt: formatter.string(from: Date()), vault: "Test", tasks: [task()], pausedTaskIDs: [])
        XCTAssertThrowsError(try snapshot.validate())
        snapshot.pausedTasks = []
        XCTAssertNoThrow(try snapshot.validate())
        let future = Snapshot(version: 4, generatedAt: snapshot.generatedAt, vault: "Test", tasks: [])
        XCTAssertThrowsError(try future.validate())
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
