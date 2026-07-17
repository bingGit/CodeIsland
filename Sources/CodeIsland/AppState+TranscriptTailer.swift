import Foundation
import SwiftUI
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
        var shouldInvalidateCompletion = false
        var shouldPresentExternalAction = false
        var shouldEndExternalAction = false

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
                shouldEndExternalAction = codexExternalActionSessionIds.contains(delta.sessionId)
                shouldInvalidateCompletion = true
                session.interrupted = false
                session.status = .processing
                session.currentTool = nil
                session.toolDescription = nil
            case .agentWorking:
                shouldInvalidateCompletion = true
                if session.status != .waitingApproval && session.status != .waitingQuestion {
                    session.status = .running
                    session.currentTool = nil
                    session.toolDescription = nil
                }
            case .agentMessage:
                shouldInvalidateCompletion = true
                shouldEndExternalAction = codexExternalActionSessionIds.contains(delta.sessionId)
                if shouldEndExternalAction {
                    let hasQueuedInteraction = permissionQueue.contains {
                        ($0.event.sessionId ?? "default") == delta.sessionId
                    } || questionQueue.contains {
                        ($0.event.sessionId ?? "default") == delta.sessionId
                    }
                    if !hasQueuedInteraction {
                        session.status = .running
                        session.currentTool = nil
                        session.toolDescription = nil
                    }
                } else if session.status != .waitingApproval && session.status != .waitingQuestion {
                    session.status = .running
                    session.currentTool = nil
                    session.toolDescription = nil
                }
            case .waitingForUser:
                shouldInvalidateCompletion = true
                shouldPresentExternalAction = codexExternalActionSessionIds.insert(delta.sessionId).inserted
                session.status = .waitingQuestion
                session.currentTool = nil
                session.toolDescription = nil
            case .taskCompleted:
                shouldEndExternalAction = codexExternalActionSessionIds.contains(delta.sessionId)
                session.status = .idle
                session.currentTool = nil
                session.toolDescription = nil
                // Discovery may have already observed the same terminal row and
                // set the session idle. This delta is incremental (tailers attach
                // at EOF), so the completion itself remains authoritative.
                shouldEnqueueCompletion = true
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
        if shouldEndExternalAction {
            endCodexExternalActionWait(sessionId: delta.sessionId)
        }
        if shouldInvalidateCompletion {
            invalidateCompletion(for: delta.sessionId)
        }
        if shouldPresentExternalAction {
            presentCodexExternalActionWait(sessionId: delta.sessionId)
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

    private func presentCodexExternalActionWait(sessionId: String) {
        activeSessionId = sessionId
        if surface == .collapsed, shouldAutoOpenPendingSurface(for: sessionId) {
            withAnimation(NotchAnimation.open) {
                surface = .sessionList
            }
            codexExternalActionAutoOpened = true
        }
        SoundManager.shared.handleEvent("PermissionRequest")
    }

    private func endCodexExternalActionWait(sessionId: String) {
        codexExternalActionSessionIds.remove(sessionId)
        guard codexExternalActionSessionIds.isEmpty else { return }
        guard codexExternalActionAutoOpened else { return }
        codexExternalActionAutoOpened = false
        if surface == .sessionList {
            withAnimation(NotchAnimation.close) {
                surface = .collapsed
            }
        }
    }
}
