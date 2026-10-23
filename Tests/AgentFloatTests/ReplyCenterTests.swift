import AgentFloatCore
import Foundation
import Testing
@testable import AgentFloat

@MainActor
struct ReplyCenterTests {
    /// 숫자 키는 커서가 입력 칸에 있으면 글자가 된다. 본문 질문에서 켠 커서가 질문 창까지 남으면 "2⏎"가 선택지 2 대신 글자 "2"로 보내진다 (최종 리뷰 C1)
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

    /// 보내는 중에 화면만 닫혔다 다시 열려도 같은 세션에 두 번째 보내기를 시작하지 않는다 (설계 4.4, 최종 리뷰 I1)
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

    private static func session(_ id: String, prompt: PendingPrompt) -> AgentSession {
        AgentSession(
            key: SessionKey(providerId: "claude", sessionId: id),
            agentName: "claude", title: "시험", cwd: "/tmp/sample", status: .waiting, waitReason: .question,
            statusSince: Date(timeIntervalSince1970: 0), isStale: false, lastActivityAt: nil,
            terminalApp: .unknown, locator: .none, prompt: prompt
        )
    }

    /// 메인 액터에 걸린 Task 들이 한 바퀴 돌 시간을 준다
    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// 보내기를 붙잡아 두었다가 풀어 주는 가짜 전달기. 몇 번 불렸는지 센다
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
