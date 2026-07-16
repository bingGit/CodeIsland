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

    func testRunningNativeAppSessionIgnoresDefaultNoMonitorTimeout() {
        XCTAssertFalse(AppState.shouldRemoveIdleSession(
            idleMinutes: 30,
            userTimeout: 0,
            hasMonitor: false,
            hostAppIsRunning: true
        ))
    }

    func testStoppedNativeAppSessionCanUseDefaultNoMonitorTimeout() {
        XCTAssertTrue(AppState.shouldRemoveIdleSession(
            idleMinutes: 10,
            userTimeout: 0,
            hasMonitor: false,
            hostAppIsRunning: false
        ))
    }

    func testUserTimeoutStillAppliesToRunningNativeAppSession() {
        XCTAssertTrue(AppState.shouldRemoveIdleSession(
            idleMinutes: 5,
            userTimeout: 5,
            hasMonitor: false,
            hostAppIsRunning: true
        ))
    }
}
