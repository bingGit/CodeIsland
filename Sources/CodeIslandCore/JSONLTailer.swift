import Foundation
import Darwin

/// Lifecycle signals emitted by Codex Desktop's local rollout transcript.
/// These are intentionally separate from generic chat messages because they
/// drive the Dynamic Island state even when no user-visible text is appended.
public enum CodexTranscriptLifecycle: Equatable, Sendable {
    case taskStarted
    case userMessage
    case agentWorking
    case agentMessage
    case waitingForUser
    case taskCompleted
}

/// A delta emitted by `JSONLTailer` whenever the watched transcript grows.
public struct ConversationTailDelta: Equatable, Sendable {
    public let sessionId: String
    public let lastUserPrompt: String?
    public let lastAssistantMessage: String?
    public let codexLifecycle: CodexTranscriptLifecycle?

    public init(
        sessionId: String,
        lastUserPrompt: String?,
        lastAssistantMessage: String?,
        codexLifecycle: CodexTranscriptLifecycle? = nil
    ) {
        self.sessionId = sessionId
        self.lastUserPrompt = lastUserPrompt
        self.lastAssistantMessage = lastAssistantMessage
        self.codexLifecycle = codexLifecycle
    }

    /// A delta only carries signal when at least one field is non-nil.
    public var isEmpty: Bool {
        lastUserPrompt == nil && lastAssistantMessage == nil && codexLifecycle == nil
    }
}

/// Watches one or more Claude-style JSONL transcripts and streams incremental
/// `ConversationTailDelta` events as new lines are appended.
///
/// The tailer attaches at end-of-file so it complements — rather than duplicates —
/// whatever initial backfill the caller already performed via filesystem scanning.
/// When the file's inode changes (e.g. user ran `/clear` or a new session rotated
/// on top of the same path) the watch transparently re-opens from the new file.
///
/// This type is thread-safe. All DispatchSource callbacks run on the tailer's
/// internal queue; the user-supplied `onDelta` closure is invoked there too and
/// must forward to the appropriate actor if it mutates shared state.
public final class JSONLTailer: @unchecked Sendable {
    public typealias DeltaHandler = @Sendable (ConversationTailDelta) -> Void

    private final class Watch {
        let sessionId: String
        var filePath: String
        var fd: Int32
        var offset: off_t
        var inode: ino_t
        var pendingFragment: Data
        var source: DispatchSourceFileSystemObject

        init(sessionId: String, filePath: String, fd: Int32, offset: off_t, inode: ino_t, source: DispatchSourceFileSystemObject) {
            self.sessionId = sessionId
            self.filePath = filePath
            self.fd = fd
            self.offset = offset
            self.inode = inode
            self.pendingFragment = Data()
            self.source = source
        }
    }

    private let queue: DispatchQueue
    private let onDelta: DeltaHandler
    private var watches: [String: Watch] = [:]

    public init(
        queue: DispatchQueue = DispatchQueue(label: "com.codeisland.jsonl-tailer"),
        onDelta: @escaping DeltaHandler
    ) {
        self.queue = queue
        self.onDelta = onDelta
    }

    deinit {
        for watch in watches.values {
            watch.source.cancel()
        }
    }

    // MARK: - Public API

    public func attach(sessionId: String, filePath: String) {
        queue.async { [weak self] in
            self?.detachOnQueue(sessionId: sessionId)
            self?.attachOnQueue(sessionId: sessionId, filePath: filePath, initialOffset: nil)
        }
    }

    public func detach(sessionId: String) {
        queue.async { [weak self] in
            self?.detachOnQueue(sessionId: sessionId)
        }
    }

    public func detachAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for key in Array(self.watches.keys) {
                self.detachOnQueue(sessionId: key)
            }
        }
    }

    public var activeSessionCount: Int {
        queue.sync { watches.count }
    }

    // MARK: - Watch lifecycle

    private func attachOnQueue(sessionId: String, filePath: String, initialOffset: off_t?) {
        let fd = open(filePath, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return }
        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0 else {
            close(fd)
            return
        }

        let offset = initialOffset ?? fileStat.st_size
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.extend, .write, .delete, .rename, .revoke],
            queue: queue
        )
        let watch = Watch(
            sessionId: sessionId,
            filePath: filePath,
            fd: fd,
            offset: offset,
            inode: fileStat.st_ino,
            source: source
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            self.handleEvents(events, watch: watch)
        }
        source.setCancelHandler {
            close(fd)
        }

        watches[sessionId] = watch
        source.resume()
    }

    private func detachOnQueue(sessionId: String) {
        guard let watch = watches.removeValue(forKey: sessionId) else { return }
        watch.source.cancel()
    }

    // MARK: - Event handling

    private func handleEvents(_ events: DispatchSource.FileSystemEvent, watch: Watch) {
        // A rotate or delete means the file has been replaced underneath us (e.g. /clear).
        // Re-attach from a fresh fd so future writes reach our handler.
        if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
            let path = watch.filePath
            let sid = watch.sessionId
            detachOnQueue(sessionId: sid)
            // Give the writer a moment to finish writing the new file before we reopen.
            queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.attachOnQueue(sessionId: sid, filePath: path, initialOffset: 0)
            }
            return
        }

        var fileStat = stat()
        if stat(watch.filePath, &fileStat) == 0 {
            if fileStat.st_ino != watch.inode {
                // Inode swap without a delete/rename event — reopen from scratch.
                let path = watch.filePath
                let sid = watch.sessionId
                detachOnQueue(sessionId: sid)
                attachOnQueue(sessionId: sid, filePath: path, initialOffset: 0)
                return
            }
            if fileStat.st_size < watch.offset {
                // Truncation — rewind so we don't miss the new prefix.
                watch.offset = 0
                watch.pendingFragment.removeAll(keepingCapacity: true)
            }
        }

        guard let appended = readFromOffset(watch: watch) else { return }
        let combined = watch.pendingFragment + appended

        let scan = JSONLTailer.scanLines(combined)
        watch.pendingFragment = scan.trailingFragment
        watch.offset += off_t(combined.count - scan.trailingFragment.count)

        for scannedDelta in scan.deltas {
            let delta = ConversationTailDelta(
                sessionId: watch.sessionId,
                lastUserPrompt: scannedDelta.lastUserPrompt,
                lastAssistantMessage: scannedDelta.lastAssistantMessage,
                codexLifecycle: scannedDelta.codexLifecycle
            )
            onDelta(delta)
        }
    }

    private func readFromOffset(watch: Watch) -> Data? {
        guard lseek(watch.fd, watch.offset, SEEK_SET) >= 0 else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { ptr in
                read(watch.fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                data.append(buffer, count: n)
            } else if n == 0 {
                break
            } else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                return nil
            }
        }
        return data
    }

    // MARK: - Pure parsing (exposed for tests)

    public struct ScanResult: Equatable {
        public struct Delta: Equatable {
            public var lastUserPrompt: String?
            public var lastAssistantMessage: String?
            public var codexLifecycle: CodexTranscriptLifecycle?
            public var isEmpty: Bool {
                lastUserPrompt == nil && lastAssistantMessage == nil && codexLifecycle == nil
            }
        }
        public let delta: Delta
        /// Per-line signals in source order. The aggregate `delta` remains for
        /// callers that only need the latest user/assistant text.
        public let deltas: [Delta]
        public let trailingFragment: Data
    }

    /// Split the given byte blob on newline boundaries and surface the latest user /
    /// assistant text observed. Bytes after the final newline are returned as a
    /// fragment that the caller should prepend on the next call.
    public static func scanLines(_ data: Data) -> ScanResult {
        var delta = ScanResult.Delta()
        var deltas: [ScanResult.Delta] = []
        var lineStart = data.startIndex
        var cursor = data.startIndex
        let newline: UInt8 = 0x0A

        while cursor < data.endIndex {
            if data[cursor] == newline {
                let line = data[lineStart..<cursor]
                if !line.isEmpty {
                    var lineDelta = ScanResult.Delta()
                    apply(line: line, into: &lineDelta)
                    if !lineDelta.isEmpty {
                        deltas.append(lineDelta)
                        merge(lineDelta, into: &delta)
                    }
                }
                lineStart = data.index(after: cursor)
            }
            cursor = data.index(after: cursor)
        }

        let fragment = Data(data[lineStart..<data.endIndex])
        return ScanResult(delta: delta, deltas: deltas, trailingFragment: fragment)
    }

    private static func merge(_ source: ScanResult.Delta, into destination: inout ScanResult.Delta) {
        if let prompt = source.lastUserPrompt { destination.lastUserPrompt = prompt }
        if let reply = source.lastAssistantMessage { destination.lastAssistantMessage = reply }
        if let lifecycle = source.codexLifecycle { destination.codexLifecycle = lifecycle }
    }

    private static func apply(line: Data.SubSequence, into delta: inout ScanResult.Delta) {
        // Materialize the slice once so the byte probe and the JSON parser share a
        // single allocation. Going through `Data(line)` also sidesteps a Foundation
        // quirk where `Data.SubSequence.withUnsafeBytes` occasionally surfaces the
        // parent's full buffer rather than the slice's view.
        let lineData = Data(line)

        // Fast path: realistic Claude transcripts are ~75% tool_use / tool_result /
        // meta rows we don't care about. Skipping the JSON parse for those saves a
        // measurable chunk of CPU per byte during streaming bursts.
        let kind = quickTypeProbe(lineBytes: lineData)
        guard kind != .irrelevant else { return }

        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return }
        if json["isMeta"] as? Bool == true { return }

        // Re-verify the type after a real parse — the byte probe can be fooled by
        // nested content that happens to contain the literal `"type":"assistant"`.
        let type = json["type"] as? String
        let message = (json["message"] as? [String: Any]) ?? json

        switch type {
        case "user", "USER_INPUT":
            if let text = extractText(from: message["content"]) {
                delta.lastUserPrompt = text
            }
        case "assistant", "PLANNER_RESPONSE":
            if let text = extractText(from: message["content"]) {
                delta.lastAssistantMessage = text
            } else if let thinking = message["thinking"] as? String {
                let trimmed = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    delta.lastAssistantMessage = trimmed
                }
            }
        case "event_msg":
            guard let payload = json["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else { return }
            switch eventType {
            case "task_started":
                delta.codexLifecycle = .taskStarted
            case "user_message":
                delta.codexLifecycle = .userMessage
                if let text = extractText(from: payload["message"]) {
                    delta.lastUserPrompt = text
                }
            case "agent_reasoning":
                delta.codexLifecycle = .agentWorking
            case "agent_message":
                if let text = extractText(from: payload["message"]) {
                    delta.lastAssistantMessage = text
                    if indicatesExternalUserAction(
                        message: text,
                        phase: payload["phase"] as? String
                    ) {
                        delta.codexLifecycle = .waitingForUser
                    } else {
                        delta.codexLifecycle = .agentMessage
                    }
                } else {
                    delta.codexLifecycle = .agentMessage
                }
            case "task_complete":
                delta.codexLifecycle = .taskCompleted
            default:
                break
            }
        default:
            break
        }
    }

    /// Codex has no dedicated lifecycle event for external browser/device flows.
    /// Recognize only commentary that both directs the user to act and says the
    /// task is waiting or will continue afterwards. Keeping the predicate narrow
    /// avoids treating ordinary progress narration as an actionable wait.
    static func indicatesExternalUserAction(message: String, phase: String?) -> Bool {
        guard phase == "commentary" else { return false }
        let text = message.lowercased()

        let directActionSignals = [
            "请打开", "请前往", "请访问", "请在", "请输入", "请完成", "请确认", "请授权", "请登录",
            "需要你", "需要您", "你需要", "您需要", "麻烦你", "麻烦您",
            "please open", "please visit", "please enter", "please complete", "please confirm",
            "please approve", "please authorize", "please sign in", "you need to",
        ]
        let continuationSignals = [
            "等待", "等你", "完成后", "操作后", "确认后", "授权后", "登录后", "告诉我",
            "wait", "waiting", "once you", "after you", "when you", "let me know", "then i will",
        ]
        let externalFlowSignals = [
            "设备码", "验证码", "授权页面", "浏览器", "网页", "github.com/login/device",
            "device code", "verification code", "authorization page", "browser", "web page",
            "captcha", "oauth", "2fa",
        ]

        let directsUser = directActionSignals.contains { text.contains($0) }
        let waitsForContinuation = continuationSignals.contains { text.contains($0) }
        let namesExternalFlow = externalFlowSignals.contains { text.contains($0) }
        return waitsForContinuation && (directsUser || namesExternalFlow)
    }

    /// Types we care about for the panel: `"user"` and `"assistant"`. Anything
    /// else — including unknown types and absent-type lines — can be skipped
    /// without bothering the JSON parser.
    enum QuickTypeKind: Equatable {
        case user
        case assistant
        case eventMessage
        case irrelevant
    }

    /// Byte-scan the line for the first `"type":"` occurrence and peek at the
    /// character that follows the opening quote. A single pass that gives up
    /// as soon as it sees something that isn't `u`, `a`, or an escape. Returns
    /// `.irrelevant` when neither `"user"` nor `"assistant"` appears as a
    /// `type` value, letting the caller skip the JSON parser entirely.
    ///
    /// Limitations: does not tolerate whitespace between the colon and the
    /// opening quote (e.g. `"type" : "user"`). Claude's JSONL writer never
    /// emits that shape, so lines which do fall through to the parser via the
    /// `.irrelevant` path get a correct — if slightly more expensive — answer
    /// by returning nothing, which is safe (we just miss those updates).
    static func quickTypeProbe(lineBytes: Data) -> QuickTypeKind {
        guard lineBytes.count >= typeMarker.count + 2 else { return .irrelevant }

        return lineBytes.withUnsafeBytes { rawBuffer -> QuickTypeKind in
            guard let base = rawBuffer.baseAddress else { return .irrelevant }
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            let total = rawBuffer.count
            let markerLen = typeMarker.count
            var index = 0
            // Every `"type":"..."` occurrence in the line gets checked, not only the
            // first — JSONSerialization is free to reorder top-level keys so the
            // outer type we care about may sit behind nested `"type":"text"` rows.
            while index <= total - markerLen {
                var matched = true
                for offset in 0..<markerLen where ptr[index + offset] != typeMarker[offset] {
                    matched = false
                    break
                }
                if matched {
                    let valueStart = index + markerLen
                    if valueStart < total {
                        switch ptr[valueStart] {
                        case 0x75:  // 'u'
                            if hasExactValue(ptr, at: valueStart, total: total, expect: userBytes) {
                                return .user
                            }
                        case 0x55:  // 'U'
                            if hasExactValue(ptr, at: valueStart, total: total, expect: userInputBytes) {
                                return .user
                            }
                        case 0x61:  // 'a'
                            if hasExactValue(ptr, at: valueStart, total: total, expect: assistantBytes) {
                                return .assistant
                            }
                        case 0x50:  // 'P'
                            if hasExactValue(ptr, at: valueStart, total: total, expect: plannerResponseBytes) {
                                return .assistant
                            }
                        case 0x65:  // 'e'
                            if hasExactValue(ptr, at: valueStart, total: total, expect: eventMessageBytes) {
                                return .eventMessage
                            }
                        default:
                            break
                        }
                    }
                    // Skip past this marker and keep looking — nested objects
                    // often carry their own `type` key we don't care about.
                    index = valueStart + 1
                } else {
                    index += 1
                }
            }
            return .irrelevant
        }
    }

    /// The `"type":"` prefix before the type value. Placed in the header so
    /// the scanner can bail early on typical tool/meta lines.
    private static let typeMarker: [UInt8] = Array(#""type":""#.utf8)
    private static let userBytes: [UInt8] = Array(#"user""#.utf8)
    private static let assistantBytes: [UInt8] = Array(#"assistant""#.utf8)
    private static let userInputBytes: [UInt8] = Array(#"USER_INPUT""#.utf8)
    private static let plannerResponseBytes: [UInt8] = Array(#"PLANNER_RESPONSE""#.utf8)
    private static let eventMessageBytes: [UInt8] = Array(#"event_msg""#.utf8)

    private static func hasExactValue(
        _ ptr: UnsafePointer<UInt8>,
        at start: Int,
        total: Int,
        expect: [UInt8]
    ) -> Bool {
        guard start + expect.count <= total else { return false }
        for offset in 0..<expect.count where ptr[start + offset] != expect[expect.startIndex + offset] {
            return false
        }
        return true
    }

    /// Concatenate every `text` block from a Claude-style `content` value. Accepts
    /// either a bare string or an array of content blocks.
    public static func extractText(from content: Any?) -> String? {
        if let raw = content as? String {
            var text = raw
            if let startRange = text.range(of: "<USER_REQUEST>"),
               let endRange = text.range(of: "</USER_REQUEST>", range: startRange.upperBound..<text.endIndex) {
                text = String(text[startRange.upperBound..<endRange.lowerBound])
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let blocks = content as? [[String: Any]] {
            var parts: [String] = []
            for block in blocks {
                guard (block["type"] as? String) == "text" else { continue }
                if let text = block["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { parts.append(trimmed) }
                }
            }
            if parts.isEmpty { return nil }
            return parts.joined(separator: "\n")
        }
        return nil
    }
}
