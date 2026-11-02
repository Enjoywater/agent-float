import AgentFloatCore
import Foundation
import Testing
@testable import AgentFloat

@MainActor
struct ReplyCenterTests {
    /// Stale composer focus makes number keys text, sending a literal number instead of selecting the option (final review C1).
    @Test func choiceDialogAfterBodyQuestionLeavesFieldUnfocused() {
        let center = ReplyCenter(backend: DeliveryGate().backend)
        center.open(Self.session("a", prompt: Self.bodyQuestion))
        #expect(center.fieldFocus.wanted)
        center.close()
        center.open(Self.session("b", prompt: Self.dialog(id: "q-b")))
        #expect(!center.fieldFocus.wanted)
    }

    @Test func tabFocusDoesNotCarryToTheNextQuestion() {
        let center = ReplyCenter(backend: DeliveryGate().backend)
        center.open(Self.session("a", prompt: Self.twoQuestions))
        center.requestFieldFocus()
        #expect(center.fieldFocus.wanted)
        center.choose(0)
        center.primary()
        #expect(center.editor?.step == 1)
        #expect(!center.fieldFocus.wanted)
    }

    /// Closing/reopening while sending must not start a second delivery to the same session (design §4.4, final review I1).
    @Test func reopeningWhileSendingDoesNotSendAgain() async {
        let gate = DeliveryGate()
        let center = ReplyCenter(backend: gate.backend)
        let session = Self.session("a", prompt: Self.dialog(id: "q-a"))
        center.open(session)
        center.choose(0)
        center.send()
        await gate.waitForCalls(1)
        center.close()
        center.open(session)
        center.send()
        await Self.settle()
        #expect(await gate.calls == 1)
        if case .sending = center.phase {} else { Issue.record("다시 연 화면이 보내는 중으로 보이지 않음: \(center.phase)") }
        await gate.releaseAll(.notSent(.alreadyAnswered))
        await Self.settle()
        #expect(center.phase == .result(.notSent(.alreadyAnswered)))
    }

    /// If answered in the terminal while viewing an unsent result, replace the old reason with already-answered guidance (final review M5).
    @Test func notSentScreenTellsWhenTheTerminalAnswered() async {
        let gate = DeliveryGate()
        let center = ReplyCenter(backend: gate.backend)
        let session = Self.session("a", prompt: Self.dialog(id: "q-a"))
        center.open(session)
        center.choose(0)
        center.send()
        await gate.waitForCalls(1)
        await gate.releaseAll(.notSent(.terminalDraft))
        await Self.settle()
        #expect(center.phase == .result(.notSent(.terminalDraft)))
        center.sync(with: [Self.session("a", prompt: nil, status: .running)])
        #expect(center.phase == .result(.notSent(.alreadyAnswered)))
        center.sync(with: [])
        #expect(center.phase == .result(.notSent(.sessionEnded)))
    }

    private static let bodyQuestion = PendingPrompt.text(id: "q-text", message: "어느 쪽으로 할까요?")

    private static func dialog(id: String) -> PendingPrompt {
        .choices(id: id, questions: [question("만료 방식을 어떻게 할까요?")])
    }

    private static let twoQuestions = PendingPrompt.choices(
        id: "q-two", questions: [question("첫 질문입니다"), question("둘째 질문입니다")]
    )

    private static func question(_ text: String) -> ChoiceQuestion {
        ChoiceQuestion(text: text, header: "머리", multiSelect: false, options: [
            ChoiceOption(label: "첫째", description: nil, hasPreview: false),
            ChoiceOption(label: "둘째", description: nil, hasPreview: false),
        ])
    }

    private static func session(_ id: String, prompt: PendingPrompt?, status: AgentStatus = .waiting) -> AgentSession {
        AgentSession(
            key: SessionKey(providerId: "claude", sessionId: id),
            agentName: "claude", title: "시험", cwd: "/tmp/sample", status: status, waitReason: status == .waiting ? .question : nil,
            statusSince: Date(timeIntervalSince1970: 0), isStale: false, lastActivityAt: nil,
            terminalApp: .unknown, locator: .none, prompt: prompt
        )
    }

    /// Allow queued MainActor tasks to advance once.
    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// Fake delivery that pauses until released and counts invocations.
actor DeliveryGate {
    private(set) var calls = 0
    private var waiters: [CheckedContinuation<DeliveryOutcome, Never>] = []

    nonisolated var backend: ReplyBackend {
        ReplyBackend(availability: { _ in .ready }, deliver: { _, _, _, _ in await self.enter() })
    }

    func enter() async -> DeliveryOutcome {
        calls += 1
        return await withCheckedContinuation { waiters.append($0) }
    }

    func releaseAll(_ outcome: DeliveryOutcome) {
        waiters.forEach { $0.resume(returning: outcome) }
        waiters = []
    }

    func waitForCalls(_ count: Int) async {
        for _ in 0..<200 where calls < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
