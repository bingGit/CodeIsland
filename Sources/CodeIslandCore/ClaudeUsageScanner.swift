import Foundation

public struct ClaudeUsageTotals: Equatable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheCreationTokens = 0
    public var cacheReadTokens = 0
    public var messageCount = 0

    public var isEmpty: Bool { messageCount == 0 }

    public init() {}

    mutating func add(_ other: ClaudeUsageTotals) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheCreationTokens += other.cacheCreationTokens
        cacheReadTokens += other.cacheReadTokens
        messageCount += other.messageCount
    }
}

/// Token-usage aggregation over the local Claude Code transcripts
/// (~/.claude/projects/**/*.jsonl) — local-first, no provider API calls.
/// Every assistant line carries `message.usage`; `message.id` repeats across
/// tool-use continuation lines of the same API response, so totals dedupe on it.
public enum ClaudeUsageScanner {
    /// Sparkline resolution: one bucket per hour, oldest first.
    public static let sparklineHours = 12

    public struct Snapshot: Equatable, Sendable {
        public let last5h: ClaudeUsageTotals
        public let today: ClaudeUsageTotals
        /// Output tokens per hour for the trailing `sparklineHours` hours,
        /// index 0 oldest, last index = the current hour.
        public let hourlyOutputTokens: [Int]
        public let scannedAt: Date

        public init(last5h: ClaudeUsageTotals, today: ClaudeUsageTotals, hourlyOutputTokens: [Int], scannedAt: Date) {
            self.last5h = last5h
            self.today = today
            self.hourlyOutputTokens = hourlyOutputTokens
            self.scannedAt = scannedAt
        }
    }

    public static func scan(
        claudeHome: String = NSHomeDirectory() + "/.claude",
        now: Date = Date()
    ) -> Snapshot {
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let midnight = Calendar.current.startOfDay(for: now)
        let sparklineStart = now.addingTimeInterval(-Double(sparklineHours) * 3600)
        let cutoff = min(fiveHoursAgo, midnight, sparklineStart)

        var last5h = ClaudeUsageTotals()
        var today = ClaudeUsageTotals()
        var hourly = [Int](repeating: 0, count: sparklineHours)
        var seenMessageIds = Set<String>()

        let fm = FileManager.default
        let projectsDir = claudeHome + "/projects"
        for project in (try? fm.contentsOfDirectory(atPath: projectsDir)) ?? [] {
            let projectPath = projectsDir + "/" + project
            for file in (try? fm.contentsOfDirectory(atPath: projectPath)) ?? [] {
                guard file.hasSuffix(".jsonl") else { continue }
                let path = projectPath + "/" + file
                // mtime gate: untouched-since-cutoff transcripts can't contain
                // in-window lines, so the scan stays cheap on big histories.
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date,
                      mtime >= cutoff else { continue }
                guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

                for line in contents.split(separator: "\n") {
                    guard let parsed = parseAssistantUsage(String(line)),
                          parsed.timestamp >= cutoff, parsed.timestamp <= now,
                          !seenMessageIds.contains(parsed.messageId) else { continue }
                    seenMessageIds.insert(parsed.messageId)
                    if parsed.timestamp >= fiveHoursAgo { last5h.add(parsed.usage) }
                    if parsed.timestamp >= midnight { today.add(parsed.usage) }
                    let hoursAgo = Int(now.timeIntervalSince(parsed.timestamp) / 3600)
                    if hoursAgo >= 0 && hoursAgo < sparklineHours {
                        hourly[sparklineHours - 1 - hoursAgo] += parsed.usage.outputTokens
                    }
                }
            }
        }
        return Snapshot(last5h: last5h, today: today, hourlyOutputTokens: hourly, scannedAt: now)
    }

    /// Parse one transcript line into (timestamp, message id, usage) — nil for
    /// non-assistant lines and lines without usage.
    static func parseAssistantUsage(_ line: String) -> (timestamp: Date, messageId: String, usage: ClaudeUsageTotals)? {
        // Cheap pre-filter before full JSON decoding: assistant lines only.
        guard line.contains("\"assistant\""), line.contains("\"usage\"") else { return nil }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "assistant",
              let timestampRaw = obj["timestamp"] as? String,
              let timestamp = parseISO8601(timestampRaw),
              let message = obj["message"] as? [String: Any],
              let messageId = message["id"] as? String,
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        var totals = ClaudeUsageTotals()
        totals.inputTokens = usage["input_tokens"] as? Int ?? 0
        totals.outputTokens = usage["output_tokens"] as? Int ?? 0
        totals.cacheCreationTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
        totals.cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0
        totals.messageCount = 1
        return (timestamp, messageId, totals)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    static func parseISO8601(_ raw: String) -> Date? {
        fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }

    /// Compact human token count: 950, 32.5K, 1.4M.
    public static func formatTokens(_ count: Int) -> String {
        switch count {
        case ..<1000:
            return "\(count)"
        case ..<1_000_000:
            return String(format: "%.1fK", Double(count) / 1000).replacingOccurrences(of: ".0K", with: "K")
        default:
            return String(format: "%.1fM", Double(count) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
    }
}
