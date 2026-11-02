import AgentFloatCore
import Foundation

/// Fake delivery path for unattended captures of sending, delivered, stopped, and failed states.
/// AGENT_FLOAT_FAKE_REPLY: delivered (default), hidden, accessibility, draft, stopped, mismatch; STAGE_DELAY sets seconds per stage.
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

    /// Like real availability checks, assess prompt-specific restrictions first.
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
            let questions: [ChoiceQuestion]
            if case let .choices(_, items) = prompt { questions = items } else { questions = [] }
            let different = values.map { key, value in
                let options = questions.first { $0.text == key }?.options.map(\.label) ?? []
                return (key, options.first { $0 != value } ?? "다른 답")
            }
            return .mismatched(sent: expected, recorded: .choices(Dictionary(uniqueKeysWithValues: different)))
        }
    }
}
