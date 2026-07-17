import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

@MainActor
final class AppStateCompletionValidityTests: XCTestCase {
    func testRunningCodexSessionCannotPresentCompletion() {
        withExpandedCompletions {
            let appState = AppState()
            var session = SessionSnapshot()
            session.source = "codex"
            session.status = .running
            appState.sessions["codex"] = session

            appState.enqueueCompletion("codex")

            XCTAssertEqual(appState.surface, .collapsed)
        }
    }

    func testNewCodexTranscriptActivityDismissesVisibleCompletion() {
        withExpandedCompletions {
            let appState = AppState()
            var session = SessionSnapshot()
            session.source = "codex"
            session.status = .idle
            appState.sessions["codex"] = session
            appState.enqueueCompletion("codex")
            XCTAssertEqual(appState.surface, .completionCard(sessionId: "codex"))

            appState.applyTranscriptDelta(ConversationTailDelta(
                sessionId: "codex",
                lastUserPrompt: "Continue working",
                lastAssistantMessage: nil,
                codexLifecycle: .taskStarted
            ))

            XCTAssertEqual(appState.sessions["codex"]?.status, .processing)
            XCTAssertEqual(appState.surface, .collapsed)
        }
    }

    func testCodexCompletionStillNotifiesWhenDiscoveryAlreadySetSessionIdle() {
        withExpandedCompletions {
            let appState = AppState()
            var session = SessionSnapshot()
            session.source = "codex"
            session.status = .idle
            appState.sessions["codex"] = session

            appState.applyTranscriptDelta(ConversationTailDelta(
                sessionId: "codex",
                lastUserPrompt: nil,
                lastAssistantMessage: "Finished",
                codexLifecycle: .taskCompleted
            ))

            XCTAssertEqual(appState.sessions["codex"]?.status, .idle)
            XCTAssertEqual(appState.surface, .completionCard(sessionId: "codex"))
        }
    }

    func testLastIdleCompletionStaysVisibleWhenInactiveIslandWouldHide() {
        let defaults = UserDefaults.standard
        let previousHideWhenNoSession = defaults.object(forKey: SettingsKey.hideWhenNoSession)
        defaults.set(true, forKey: SettingsKey.hideWhenNoSession)
        defer {
            restore(previousHideWhenNoSession, forKey: SettingsKey.hideWhenNoSession, in: defaults)
        }

        let appState = AppState()
        var completed = SessionSnapshot()
        completed.source = "codex"
        completed.status = .idle
        appState.sessions["completed"] = completed

        XCTAssertTrue(appState.shouldKeepLastCompletionVisible(for: "completed"))

        var active = SessionSnapshot()
        active.source = "codex"
        active.status = .running
        appState.sessions["active"] = active

        XCTAssertFalse(appState.shouldKeepLastCompletionVisible(for: "completed"))
    }

    func testExpandedCompletionPreventsInactivePanelFromHiding() {
        XCTAssertFalse(AppState.shouldHideInactivePanel(
            hideWhenNoSession: true,
            activeSessionCount: 0,
            surface: .completionCard(sessionId: "completed")
        ))
        XCTAssertTrue(AppState.shouldHideInactivePanel(
            hideWhenNoSession: true,
            activeSessionCount: 0,
            surface: .collapsed
        ))
    }

    func testQueuedCodexCompletionIsSkippedAfterSessionBecomesActive() {
        withExpandedCompletions {
            let appState = AppState()
            var first = SessionSnapshot()
            first.source = "codex"
            first.status = .idle
            appState.sessions["first"] = first

            var second = SessionSnapshot()
            second.source = "codex"
            second.status = .idle
            appState.sessions["second"] = second

            appState.enqueueCompletion("first")
            appState.enqueueCompletion("second")
            appState.sessions["second"]?.status = .running

            XCTAssertFalse(appState.showNextPending())
            XCTAssertEqual(appState.surface, .completionCard(sessionId: "first"))
        }
    }

    func testNewHookPromptDismissesVisibleCompletion() throws {
        try withExpandedCompletions {
            let appState = AppState()
            var session = SessionSnapshot()
            session.source = "cursor"
            session.status = .idle
            appState.sessions["cursor"] = session
            appState.enqueueCompletion("cursor")
            XCTAssertEqual(appState.surface, .completionCard(sessionId: "cursor"))

            let data = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"cursor","_source":"cursor","prompt":"Next turn"}"#.utf8)
            let event = try XCTUnwrap(HookEvent(from: data))
            appState.handleEvent(event)

            XCTAssertEqual(appState.sessions["cursor"]?.status, .processing)
            XCTAssertEqual(appState.surface, .collapsed)
        }
    }

    private func withExpandedCompletions(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previousStyle = defaults.object(forKey: SettingsKey.completionNotificationStyle)
        let previousSmartSuppress = defaults.object(forKey: SettingsKey.smartSuppress)
        defaults.set(AppState.CompletionStyle.expand.rawValue, forKey: SettingsKey.completionNotificationStyle)
        defaults.set(false, forKey: SettingsKey.smartSuppress)
        defer {
            restore(previousStyle, forKey: SettingsKey.completionNotificationStyle, in: defaults)
            restore(previousSmartSuppress, forKey: SettingsKey.smartSuppress, in: defaults)
        }
        try body()
    }

    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
