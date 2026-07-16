import XCTest
@testable import CodeIsland
import SQLite3

final class AppStateCodexTranscriptTests: XCTestCase {
    func testCodexDesktopThreadsInSameWorkspaceRemainDistinct() {
        XCTAssertFalse(AppState.shouldDeduplicateDiscoveredSession(
            existingSource: "codex",
            existingCwd: "/repo",
            existingTermBundleId: "com.openai.codex",
            discoveredSource: "codex",
            discoveredCwd: "/repo",
            discoveredTermBundleId: "com.openai.codex"
        ))

        XCTAssertTrue(AppState.shouldDeduplicateDiscoveredSession(
            existingSource: "codex",
            existingCwd: "/repo",
            existingTermBundleId: nil,
            discoveredSource: "codex",
            discoveredCwd: "/repo",
            discoveredTermBundleId: nil
        ))
    }

    func testRecentCodexTranscriptPathsFindsResumedThreadInOldDateDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-resumed-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions")
        let oldDirectory = sessions.appendingPathComponent("2026/07/04")
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = "019f2c8e-4fbe-77a2-b306-5fb942b2df2b"
        let transcript = oldDirectory.appendingPathComponent(
            "rollout-2026-07-04T17-55-51-\(sessionId).jsonl"
        )
        try "{}\n".write(to: transcript, atomically: true, encoding: .utf8)

        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: transcript.path)
        let statePath = root.appendingPathComponent("state_5.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(statePath, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads (rollout_path TEXT, updated_at INTEGER);", nil, nil, nil), SQLITE_OK)

        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO threads VALUES (?, ?);", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = transcript.path.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        sqlite3_bind_int64(statement, 2, sqlite3_int64(now.timeIntervalSince1970))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)

        let paths = AppState.recentCodexTranscriptPaths(
            base: sessions.path,
            modifiedAfter: now.addingTimeInterval(-600),
            fm: .default,
            statePath: statePath,
            now: now
        )

        XCTAssertEqual(paths, [transcript.path])
    }

    func testCodexLatestTerminalTurnTimestampPrefersNewestTerminalEvent() throws {
        let transcript = [
            #"{"timestamp":"2026-04-09T03:17:16.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#,
            #"{"timestamp":"2026-04-09T03:17:18.000Z","type":"event_msg","payload":{"type":"agent_message","message":"still working"}}"#,
            #"{"timestamp":"2026-04-09T03:17:20.500Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-2"}}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.codexLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, try timestampFrom("2026-04-09T03:17:20.500Z"))
    }

    func testCodexLatestTerminalTurnTimestampTreatsAbortedAndFailedTurnsAsTerminal() throws {
        let transcript = [
            #"{"timestamp":"2026-04-09T03:17:16.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#,
            #"{"timestamp":"2026-04-09T03:17:21Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#,
            #"{"timestamp":"2026-04-09T03:17:19.000Z","type":"event_msg","payload":{"type":"turn_failed","reason":"tool_error"}}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.codexLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, try timestampFrom("2026-04-09T03:17:21Z"))
    }

    func testCodexLatestTerminalTurnTimestampIgnoresMalformedAndNonTerminalEvents() {
        let transcript = [
            "not-json",
            #"{"timestamp":"2026-04-09T03:17:16.000Z","type":"event_msg","payload":{"type":"agent_message","message":"done"}}"#,
            #"{"timestamp":"2026-04-09T03:17:17.000Z","type":"response_item","payload":{"type":"message"}}"#
        ].joined(separator: "\n")

        XCTAssertNil(AppState.codexLatestTerminalTurnTimestamp(in: transcript))
    }

    func testQoderLatestTerminalTurnTimestampPrefersExplicitStopEvent() throws {
        let transcript = [
            #"{"type":"assistant","timestamp":"2026-04-09T03:59:31.309452Z","message":{"role":"assistant","content":[{"text":"hello","type":"text"}]}}"#,
            #"{"type":"progress","timestamp":"2026-04-09T03:59:31.332585Z","data":{"hookEvent":"Stop","hookName":"Stop","type":"hook_progress"}}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.qoderLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, try timestampFrom("2026-04-09T03:59:31.332585Z"))
    }

    func testQoderLatestTerminalTurnTimestampFallsBackToAssistantTextWhenStopMissing() throws {
        let transcript = [
            #"{"type":"assistant","timestamp":"2026-04-09T03:59:30.000000Z","message":{"role":"assistant","content":[{"thinking":"let me think","type":"thinking"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-04-09T03:59:31.309452Z","message":{"role":"assistant","content":[{"text":"hello","type":"text"}]}}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.qoderLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, try timestampFrom("2026-04-09T03:59:31.309452Z"))
    }

    func testCodeBuddyLatestTerminalTurnTimestampUsesCompletedAssistantMessage() throws {
        let transcript = [
            #"{"timestamp":1775408759547,"type":"function_call","status":"completed","role":"assistant","content":[{"type":"output_text","text":"tool"}]}"#,
            #"{"timestamp":1775408774216,"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"final"}]}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.codeBuddyLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, Date(timeIntervalSince1970: 1775408774.216))
    }

    func testCodeBuddyLatestTerminalTurnTimestampIgnoresNonCompletedAssistantEntries() {
        let transcript = [
            #"{"timestamp":1775408759547,"type":"message","role":"assistant","status":"streaming","content":[{"type":"output_text","text":"partial"}]}"#,
            #"{"timestamp":1775408774216,"type":"message","role":"user","status":"completed","content":[{"type":"input_text","text":"next"}]}"#
        ].joined(separator: "\n")

        XCTAssertNil(AppState.codeBuddyLatestTerminalTurnTimestamp(in: transcript))
    }

    private func timestampFrom(_ raw: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let timestamp = fractional.date(from: raw) {
            return timestamp
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(plain.date(from: raw))
    }
}
