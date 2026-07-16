import XCTest
@testable import CodeIsland

final class AppStateCleanupTests: XCTestCase {
    func testRunningNativeAppSessionIgnoresDefaultNoMonitorTimeout() {
        XCTAssertFalse(AppState.shouldRemoveIdleSession(
            idleMinutes: 30,
            userTimeout: 0,
            hasMonitor: false,
            nativeAppIsRunning: true
        ))
    }

    func testStoppedNativeAppSessionCanUseDefaultNoMonitorTimeout() {
        XCTAssertTrue(AppState.shouldRemoveIdleSession(
            idleMinutes: 10,
            userTimeout: 0,
            hasMonitor: false,
            nativeAppIsRunning: false
        ))
    }

    func testUserTimeoutStillAppliesToRunningNativeAppSession() {
        XCTAssertTrue(AppState.shouldRemoveIdleSession(
            idleMinutes: 5,
            userTimeout: 5,
            hasMonitor: false,
            nativeAppIsRunning: true
        ))
    }
}
