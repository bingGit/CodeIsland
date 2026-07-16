import XCTest
@testable import CodeIsland

final class AppStateCleanupTests: XCTestCase {
    func testDismissedSessionRequiresNewerActivityToReturn() {
        let dismissedAt = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(AppState.shouldRediscoverDismissedSession(
            dismissedAt: dismissedAt,
            modifiedAt: dismissedAt
        ))
        XCTAssertTrue(AppState.shouldRediscoverDismissedSession(
            dismissedAt: dismissedAt,
            modifiedAt: dismissedAt.addingTimeInterval(0.001)
        ))
        XCTAssertTrue(AppState.shouldRediscoverDismissedSession(
            dismissedAt: nil,
            modifiedAt: dismissedAt
        ))
    }

    func testNoCleanupPreservesIdleSession() {
        XCTAssertFalse(AppState.shouldRemoveIdleSession(
            idleMinutes: 30,
            userTimeout: 0
        ))
    }

    func testConfiguredTimeoutKeepsRecentlyIdleSession() {
        XCTAssertFalse(AppState.shouldRemoveIdleSession(
            idleMinutes: 29,
            userTimeout: 30
        ))
    }

    func testConfiguredTimeoutRemovesExpiredIdleSession() {
        XCTAssertTrue(AppState.shouldRemoveIdleSession(
            idleMinutes: 30,
            userTimeout: 30
        ))
    }
}
