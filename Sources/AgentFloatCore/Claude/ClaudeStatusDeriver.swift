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
    /// busy 인데 트랜스크립트가 이 시간보다 오래 조용하면 멈춘 것으로 의심한다
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
            // 턴이 끝났는데 백그라운드 셸이 남아 있으면 idle 대신 이 값을 쓴다 (2.1.301 실측). 트랜스크립트 꼬리에서 시작 기록이 밀려나도 이 값으로 알 수 있다
            return deriveIdle(tail: tail, now: now, backgroundShellRunning: true)
        default:
            // 모르는 값을 실행으로 추정하면 멈춘 세션이 일하는 것처럼 보이므로 회색으로 둔다
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

    /// 대기 사유가 무엇을 기다리는지와 transcript 꼬리가 맞을 때만 질문을 붙인다. 사유와 다른 종류를 보여 주면 엉뚱한 것에 답하게 된다
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

    // 대기를 놓치는 쪽이 최악이라 질문 판정을 자동 재개(백그라운드 작업·예약)보다 먼저 본다
    private static func deriveIdle(tail: TranscriptTail?, now: Date, backgroundShellRunning: Bool) -> DerivedStatus {
        if let tail, asksUser(tail) {
            return DerivedStatus(status: .waiting, waitReason: .bodyQuestion, isStale: false)
        }
        // 남은 일이 스스로 이어질 예정이라 조용한 것이 정상이므로 정체로 보지 않는다
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
