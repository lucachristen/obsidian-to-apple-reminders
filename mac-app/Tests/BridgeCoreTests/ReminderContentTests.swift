import XCTest
@testable import BridgeCore

final class ReminderContentTests: XCTestCase {
    private let id = "11111111-1111-4111-a111-111111111111"
    func testHumanReadableTitlesAndNotesKeepMachineIdentityOutOfTheList() throws {
        let task = BridgeTask(id: id, path: "2 Areas/life.md", title: "Arrange [[Medical checkup plan]] and [[folder/Note|my alias]]", completed: false, selected: true)
        let content = ReminderContent(task: task, vault: "My vault")
        XCTAssertEqual(content.title, "Arrange Medical checkup plan and my alias")
        XCTAssertNil(content.notes)
        XCTAssertEqual(try managedTaskID(url: content.url, notes: content.notes), id)
        let items = URLComponents(url: content.url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "file" })?.value, task.path)
        XCTAssertEqual(items?.first(where: { $0.name == "vault" })?.value, "My vault")
    }
    func testOnlyUsefulSchedulingInformationIsKeptInNotes() {
        let task = BridgeTask(id: id, title: "Read [the docs](https://example.org)", completed: false, selected: true, scheduled: "2026-10-08")
        let content = ReminderContent(task: task, vault: "Vault")
        XCTAssertEqual(content.title, "Read the docs")
        XCTAssertEqual(content.notes, "Scheduled: 2026-10-08")
        XCTAssertFalse(content.notes!.contains(id))
    }
    func testLegacyNotesMigrateWithoutChangingIdentity() throws {
        let legacy = "obsidian-reminders-bridge:\(id)\nObsidian: Tasks.md"
        XCTAssertEqual(try managedTaskID(url: nil, notes: legacy), id)
        let task = BridgeTask(id: id, completed: false, selected: true)
        let migrated = ReminderContent(task: task, vault: "Vault")
        XCTAssertEqual(try managedTaskID(url: migrated.url, notes: legacy), id)
        XCTAssertNil(migrated.notes)
        XCTAssertNil(try managedTaskID(url: URL(string: "https://example.org?bridgeTask=\(id)"), notes: "A personal reminder"))
        XCTAssertThrowsError(try managedTaskID(url: migrated.url, notes: "obsidian-reminders-bridge:22222222-2222-4222-a222-222222222222"))
        XCTAssertThrowsError(try managedTaskID(url: nil, notes: "obsidian-reminders-bridge:broken"))
    }
    func testOwnershipOnlyMigrationKeepsUsefulNotesAndRequiresALegacyMarker() throws {
        let notes = "obsidian-reminders-bridge:\(id)\nObsidian: 2 Areas/life.md\nScheduled: 2026-10-08\nPersonal note"
        let migrated = migrateLegacyReminder(url: nil, notes: notes, id: id, vault: "Vault")
        XCTAssertEqual(migrated?.notes, "Scheduled: 2026-10-08\nPersonal note")
        XCTAssertEqual(try managedTaskID(url: migrated?.url, notes: migrated?.notes), id)
        XCTAssertEqual(URLComponents(url: migrated!.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "file" })?.value, "2 Areas/life.md")
        XCTAssertNil(migrateLegacyReminder(url: nil, notes: "A normal reminder", id: id, vault: "Vault"))
    }
    func testCreationOrderIsTheQueryOrderNotUUIDOrder() {
        let ids = ["cccccccc-cccc-4ccc-accc-cccccccccccc", "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa", id]
        let tasks = ids.map { BridgeTask(id: $0, completed: false, selected: true) }
        XCTAssertEqual(reconciliationOrder(tasks: tasks, mappedIDs: [id, "stale", ids[0]]), ids + ["stale"])
    }
}
