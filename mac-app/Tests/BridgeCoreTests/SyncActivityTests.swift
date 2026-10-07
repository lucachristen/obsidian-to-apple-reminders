import XCTest
@testable import BridgeCore

final class SyncActivityTests: XCTestCase {
    func testFastBackgroundChecksNeverShowActivity() {
        var activity = SyncActivity()
        for time in [0.0, 10.0, 20.0] {
            activity.begin(at: time, userInitiated: false)
            XCTAssertFalse(activity.isVisible)
            activity.finish(at: time + 0.05)
            activity.advance(to: time + 1)
            XCTAssertFalse(activity.isVisible)
            XCTAssertNil(activity.nextTransition)
        }
    }
    func testSlowBackgroundWorkShowsAfterDelayAndDoesNotBlinkOnCompletion() {
        var activity = SyncActivity()
        activity.begin(at: 0, userInitiated: false)
        activity.advance(to: 0.39)
        XCTAssertFalse(activity.isVisible)
        activity.advance(to: 0.4)
        XCTAssertTrue(activity.isVisible)
        activity.finish(at: 0.45)
        activity.advance(to: 0.89)
        XCTAssertTrue(activity.isVisible)
        activity.advance(to: 0.91)
        XCTAssertFalse(activity.isVisible)
    }
    func testManualSyncShowsImmediatelyEvenWhenFast() {
        var activity = SyncActivity()
        activity.begin(at: 0, userInitiated: true)
        XCTAssertTrue(activity.isVisible)
        activity.finish(at: 0.01)
        XCTAssertTrue(activity.isVisible)
        activity.advance(to: 0.5)
        XCTAssertFalse(activity.isVisible)
    }
    func testManualRequestPromotesInFlightBackgroundWork() {
        var activity = SyncActivity()
        activity.begin(at: 0, userInitiated: false)
        activity.begin(at: 0.1, userInitiated: true)
        XCTAssertTrue(activity.isVisible)
        XCTAssertNil(activity.nextTransition)
        activity.finish(at: 0.2)
        activity.advance(to: 0.61)
        XCTAssertFalse(activity.isVisible)
    }
    func testNextPassCancelsPendingHideWithoutBlinking() {
        var activity = SyncActivity()
        activity.begin(at: 0, userInitiated: true)
        activity.finish(at: 0.1)
        activity.begin(at: 0.2, userInitiated: false)
        activity.advance(to: 0.5)
        XCTAssertTrue(activity.isVisible)
        activity.finish(at: 1)
        XCTAssertFalse(activity.isVisible)
    }
}
