import Foundation
import CodeIslandCore

extension AppState {
    /// Start watching a session's transcript file for appended lines. Safe to call
    /// repeatedly with the same (session, path) pair — the tailer reattaches only
    /// when the path actually changed.
    func attachTranscriptTailerIfNeeded(sessionId: String) {
        guard let path = sessions[sessionId]?.transcriptPath, !path.isEmpty else { return }
        if attachedTranscriptPaths[sessionId] == path { return }
        attachedTranscriptPaths[sessionId] = path

        // Backfill messages from the transcript file so recentMessages is populated
        let (_, messages) = Self.readRecentFromTranscript(path: path)
        if !messages.isEmpty, var session = sessions[sessionId] {
            session.recentMessages = messages
            if let lastUser = messages.last(where: { $0.isUser }) {
                session.lastUserPrompt = lastUser.text
            }
            if let lastAssistant = messages.last(where: { !$0.isUser }) {
                session.lastAssistantMessage = lastAssistant.text
            }
            sessions[sessionId] = session
        }

        transcriptTailer.attach(sessionId: sessionId, filePath: path)
    }

    /// Stop watching a session's transcript. Called when the session is removed or
    /// when a new transcript path supersedes an older one.
    func detachTranscriptTailer(sessionId: String) {
        attachedTranscriptPaths.removeValue(forKey: sessionId)
        transcriptTailer.detach(sessionId: sessionId)
    }

    /// Apply an incremental update produced by the tailer. Runs on the main actor.
    func applyTranscriptDelta(_ delta: ConversationTailDelta) {
        guard var session = sessions[delta.sessionId] else { return }
        var mutated = false
        var shouldEnqueueCompletion = false

        if let prompt = delta.lastUserPrompt, session.lastUserPrompt != prompt {
            session.lastUserPrompt = prompt
            if session.recentMessages.last(where: { $0.isUser })?.text != prompt {
                session.addRecentMessage(ChatMessage(isUser: true, text: prompt))
            }
            mutated = true
        }
        if let reply = delta.lastAssistantMessage, session.lastAssistantMessage != reply {
            session.lastAssistantMessage = reply
            if session.recentMessages.last(where: { !$0.isUser })?.text != reply {
                session.addRecentMessage(ChatMessage(isUser: false, text: reply))
            }
            mutated = true
        }

        // Codex Desktop does not emit user-configurable hooks for its GUI
        // threads. Its rollout transcript is the real-time lifecycle source,
        // so map those events onto the same session states Cursor reaches via
        // beforeSubmitPrompt / afterAgentResponse / stop hooks.
        if session.source == "codex", let lifecycle = delta.codexLifecycle {
            switch lifecycle {
            case .taskStarted, .userMessage:
                session.interrupted = false
                session.status = .processing
                session.currentTool = nil
                session.toolDescription = nil
            case .agentWorking:
                if session.status != .waitingApproval && session.status != .waitingQuestion {
                    session.status = .running
                    session.currentTool = nil
                    session.toolDescription = nil
                }
            case .taskCompleted:
                let wasActive = session.status != .idle
                session.status = .idle
                session.currentTool = nil
                session.toolDescription = nil
                shouldEnqueueCompletion = wasActive
            }
            session.lastActivity = Date()
            mutated = true
        }

        if mutated {
            if delta.codexLifecycle == nil {
                session.lastActivity = Date()
            }
            sessions[delta.sessionId] = session
        }
        if shouldEnqueueCompletion {
            enqueueCompletion(delta.sessionId)
        }
        if mutated {
            scheduleSave()
            startRotationIfNeeded()
            refreshDerivedState()
        }
    }
}
