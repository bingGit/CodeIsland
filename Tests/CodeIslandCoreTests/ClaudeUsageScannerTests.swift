import XCTest
@testable import CodeIslandCore

final class ClaudeUsageScannerTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "usage-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: home + "/projects/p1", withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
        super.tearDown()
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func assistantLine(id: String, at date: Date, input: Int, output: Int, cacheWrite: Int = 0, cacheRead: Int = 0) -> String {
        """
        {"type":"assistant","timestamp":"\(iso(date))","message":{"id":"\(id)","role":"assistant","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheWrite),"cache_read_input_tokens":\(cacheRead)}}}
        """
    }

    /// Noon local time keeps "1h ago" and "8h ago" unambiguously on today's
    /// date regardless of when the test runs.
    private var noon: Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    func testParseAssistantUsageLine() {
        let parsed = ClaudeUsageScanner.parseAssistantUsage(
            assistantLine(id: "m1", at: noon, input: 10, output: 20, cacheWrite: 5, cacheRead: 100))
        XCTAssertEqual(parsed?.messageId, "m1")
        XCTAssertEqual(parsed?.usage.inputTokens, 10)
        XCTAssertEqual(parsed?.usage.outputTokens, 20)
        XCTAssertEqual(parsed?.usage.cacheCreationTokens, 5)
        XCTAssertEqual(parsed?.usage.cacheReadTokens, 100)

        XCTAssertNil(ClaudeUsageScanner.parseAssistantUsage(#"{"type":"user","timestamp":"2026-07-10T01:00:00Z"}"#))
        XCTAssertNil(ClaudeUsageScanner.parseAssistantUsage("not json"))
    }

    func testScanAggregatesWindowsAndDedupes() throws {
        let now = noon
        let lines = [
            // In both windows.
            assistantLine(id: "recent", at: now.addingTimeInterval(-3600), input: 100, output: 10),
            // Duplicate message id (tool-use continuation) — counted once.
            assistantLine(id: "recent", at: now.addingTimeInterval(-3600), input: 100, output: 10),
            // Today but outside the 5h window (04:00 local).
            assistantLine(id: "morning", at: now.addingTimeInterval(-8 * 3600), input: 1000, output: 50),
            // Yesterday — in neither window.
            assistantLine(id: "old", at: now.addingTimeInterval(-30 * 3600), input: 7777, output: 999),
        ]
        try lines.joined(separator: "\n")
            .write(toFile: home + "/projects/p1/s.jsonl", atomically: true, encoding: .utf8)

        let snap = ClaudeUsageScanner.scan(claudeHome: home, now: now)

        XCTAssertEqual(snap.last5h.inputTokens, 100)
        XCTAssertEqual(snap.last5h.outputTokens, 10)
        XCTAssertEqual(snap.last5h.messageCount, 1)
        XCTAssertEqual(snap.today.inputTokens, 1100)
        XCTAssertEqual(snap.today.outputTokens, 60)
        XCTAssertEqual(snap.today.messageCount, 2)
    }

    func testScanEmptyHome() {
        let snap = ClaudeUsageScanner.scan(claudeHome: home + "/nonexistent", now: noon)
        XCTAssertTrue(snap.last5h.isEmpty)
        XCTAssertTrue(snap.today.isEmpty)
    }

    func testFormatTokens() {
        XCTAssertEqual(ClaudeUsageScanner.formatTokens(950), "950")
        XCTAssertEqual(ClaudeUsageScanner.formatTokens(32_500), "32.5K")
        XCTAssertEqual(ClaudeUsageScanner.formatTokens(1_400_000), "1.4M")
        XCTAssertEqual(ClaudeUsageScanner.formatTokens(2_000_000), "2M")
        XCTAssertEqual(ClaudeUsageScanner.formatTokens(1000), "1K")
    }
}
