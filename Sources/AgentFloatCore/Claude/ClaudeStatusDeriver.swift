import Foundation

public struct DerivedStatus: Equatable, Sendable {
    public let status: AgentStatus
    public let waitReason: WaitReason?
    public let isStale: Bool

    public init(status: AgentStatus, waitReason: WaitReason?, isStale: Bool) {
        self.status = status
        self.waitReason = waitReason
        self.isStale = isStale
    }
}

public enum ClaudeStatusDeriver {
    /// A busy session silent beyond this interval is suspected to be stalled.
    public static let staleAfter: TimeInterval = 600

    public static func derive(file: ClaudeSessionFile, tail: TranscriptTail?, now: Date) -> DerivedStatus {
        switch file.status {
        case "waiting":
            return DerivedStatus(status: .waiting, waitReason: waitReason(from: file.waitingFor), isStale: false)
        case "busy":
            return DerivedStatus(status: .running, waitReason: nil, isStale: isStale(tail, now: now))
        case "idle":
            return deriveIdle(tail: tail, now: now, backgroundShellRunning: false)
        case "shell":
            // A finished turn with a remaining background shell uses this state instead of idle (2.1.301); it survives tail-window truncation.
            return deriveIdle(tail: tail, now: now, backgroundShellRunning: true)
        default:
            // Keep unknown values gray rather than incorrectly implying active work.
            return DerivedStatus(status: .unknown, waitReason: nil, isStale: false)
        }
    }

    public static func waitReason(from waitingFor: String?) -> WaitReason {
        guard let raw = waitingFor, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .other("대기")
        }
        if raw == "input needed" { return .question }
        if raw.lowercased().contains("permission") { return .permission }
        if raw == "worker request" { return .worker }
        if raw == "sandbox request" { return .sandbox }
        if raw == "dialog open" { return .dialog }
        return .other(raw)
    }

    /// Attach prompts only when their type matches the wait reason, avoiding replies to the wrong question.
    public static func prompt(for reason: WaitReason?, tail: TranscriptTail?) -> PendingPrompt? {
        guard let tail else { return nil }
        switch reason {
        case .question?:
            return tail.openQuestion
        case .bodyQuestion?:
            guard let id = tail.lastAssistantId, let text = tail.lastAssistantText else { return nil }
            return .text(id: id, message: text)
        case .permission?:
            return tail.openToolUse.map { .permission(id: $0.id, tool: $0.name, summary: $0.summary) }
        case .worker?, .sandbox?, .dialog?, .other?, nil:
            return nil
        }
    }

    // Check questions before automatic continuation: missing real user waits is the worst outcome.
    private static func deriveIdle(tail: TranscriptTail?, now: Date, backgroundShellRunning: Bool) -> DerivedStatus {
        if let tail, asksUser(tail) {
            return DerivedStatus(status: .waiting, waitReason: .bodyQuestion, isStale: false)
        }
        // Silence is expected while pending work will resume automatically; do not mark it stalled.
        if backgroundShellRunning || tail.map({ hasPendingWork($0, now: now) }) == true {
            return DerivedStatus(status: .running, waitReason: nil, isStale: false)
        }
        return DerivedStatus(status: .done, waitReason: nil, isStale: false)
    }

    private static func hasPendingWork(_ tail: TranscriptTail, now: Date) -> Bool {
        !tail.pendingBackgroundTaskIds.isEmpty || tail.pendingWake || tail.hasLiveCron(at: now)
    }

    private static func asksUser(_ tail: TranscriptTail) -> Bool {
        guard !tail.userPromptAfterLastAssistant, let text = tail.lastAssistantText else { return false }
        return QuestionHeuristic.endsWithQuestion(text)
    }

    private static func isStale(_ tail: TranscriptTail?, now: Date) -> Bool {
        guard let tail else { return false }
        return now.timeIntervalSince(tail.modifiedAt) > staleAfter
    }
}
