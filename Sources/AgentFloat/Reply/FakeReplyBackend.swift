import AgentFloatCore
import Foundation

/// `AGENT_FLOAT_FAKE_SESSIONS` 일 때 실제 터미널 대신 쓰는 보내기 경로. 상태별 화면(보내는 중·보냄·보내지 않음·실패)을 사람 손 없이 찍기 위함이다.
/// `AGENT_FLOAT_FAKE_REPLY`: delivered(기본)·hidden·accessibility·draft·stopped·mismatch, `AGENT_FLOAT_FAKE_REPLY_STAGE_DELAY`: 단계마다 머무는 초
enum FakeReplyBackend {
    static func make(_ environment: [String: String]) -> ReplyBackend {
        let mode = environment["AGENT_FLOAT_FAKE_REPLY"] ?? "delivered"
        let delay = Double(environment["AGENT_FLOAT_FAKE_REPLY_STAGE_DELAY"] ?? "") ?? 0.4
        return ReplyBackend(
            availability: { session in availability(of: session, mode: mode) },
            deliver: { draft, prompt, _, onStage in
                for stage in DeliveryStage.allCases {
                    onStage(stage)
                    try? await Task.sleep(for: .seconds(delay))
                    if mode == "draft", stage == .screen { return .notSent(.terminalDraft) }
                    if mode == "stopped", stage == .typing { return .stopped(stage: "화면이 예상과 다르게 바뀜") }
                }
                return outcome(draft: draft, prompt: prompt, mode: mode)
            }
        )
    }

    /// 실제 판정처럼 질문 쪽 이유를 먼저 본다
    private static func availability(of session: AgentSession, mode: String) -> ConsoleAvailability {
        if case .permission? = session.prompt { return .readOnly(.permissionPrompt) }
        switch mode {
        case "hidden": return .readOnly(.hiddenTab)
        case "accessibility": return .readOnly(.accessibilityNeeded)
        default: return .ready
        }
    }

    private static func outcome(draft: ReplyDraft, prompt: PendingPrompt, mode: String) -> DeliveryOutcome {
        guard let expected = ReplyDriver.expectedRecord(prompt: prompt, draft: draft) else { return .notSent(.questionChanged) }
        guard mode == "mismatch" else { return .delivered(expected) }
        switch expected {
        case .text:
            return .mismatched(sent: expected, recorded: .text("다른 글"))
        case let .choices(values):
            return .mismatched(sent: expected, recorded: .choices(values.mapValues { _ in "고정 10분 유지" }))
        }
    }
}
