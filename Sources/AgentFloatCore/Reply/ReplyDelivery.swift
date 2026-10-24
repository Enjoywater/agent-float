import Foundation

/// 답장 화면의 "보내는 중" 네 줄과 같은 순서 (v1.2 설계 시안 6)
public enum DeliveryStage: Int, CaseIterable, Sendable {
    case sameQuestion, screen, typing, record
}

/// 키를 하나도 보내지 않고 멈춘 이유
public enum NotSentReason: Equatable, Sendable {
    case alreadyAnswered, questionChanged, sessionEnded, terminalDraft, unexpectedScreen, unreadableScreen
    case readOnly(ReadOnlyReason)
}

public enum DeliveryOutcome: Equatable, Sendable {
    case delivered(RecordedAnswer)
    case notSent(NotSentReason)
    /// 키를 보내는 도중 멈춤. 일부 키가 들어갔을 수 있다
    case stopped(stage: String)
    /// 기록된 답이 보낸 답과 다름. `recorded == nil` 은 정해진 시간 안에 기록이 없었던 것
    case mismatched(sent: RecordedAnswer, recorded: RecordedAnswer?)
}

public struct DeliveryTiming: Sendable {
    public var stepTimeout: Duration
    public var pollInterval: Duration
    public var recordTimeout: Duration
    public var maxMoves: Int

    public init(
        stepTimeout: Duration = .milliseconds(1500),
        pollInterval: Duration = .milliseconds(100),
        recordTimeout: Duration = .seconds(5),
        maxMoves: Int = 60
    ) {
        self.stepTimeout = stepTimeout
        self.pollInterval = pollInterval
        self.recordTimeout = recordTimeout
        self.maxMoves = maxMoves
    }

    public static let standard = DeliveryTiming()
}

/// 의도와 다른 답이 들어가지 않도록 네 단계를 차례로 확인하며 보낸다 (v1.2 설계 4.4). 하나라도 어긋나면 그 자리에서 멈추고 다시 시도하지 않는다
public struct ReplyDelivery: Sendable {
    private let currentSessions: @Sendable () async -> [AgentSession]
    private let consoles: ConsoleRegistry
    private let answers: @Sendable (SessionKey, String) -> RecordedAnswer?
    private let timing: DeliveryTiming

    public init(
        currentSessions: @escaping @Sendable () async -> [AgentSession],
        consoles: ConsoleRegistry,
        answers: @escaping @Sendable (SessionKey, String) -> RecordedAnswer?,
        timing: DeliveryTiming = .standard
    ) {
        self.currentSessions = currentSessions
        self.consoles = consoles
        self.answers = answers
        self.timing = timing
    }

    public func deliver(
        _ draft: ReplyDraft,
        prompt: PendingPrompt,
        session: AgentSession,
        onStage: @escaping @Sendable (DeliveryStage) -> Void
    ) async -> DeliveryOutcome {
        guard let expected = ReplyDriver.expectedRecord(prompt: prompt, draft: draft) else { return .notSent(.questionChanged) }

        // G1 같은 질문
        onStage(.sameQuestion)
        guard let current = await currentSessions().first(where: { $0.key == session.key }) else { return .notSent(.sessionEnded) }
        guard current.status == .waiting else { return .notSent(.alreadyAnswered) }
        guard current.prompt?.id == prompt.id, current.waitReason == session.waitReason else { return .notSent(.questionChanged) }

        // G2 화면
        onStage(.screen)
        if case let .readOnly(reason) = await consoles.availability(of: current) { return .notSent(.readOnly(reason)) }
        guard let console = consoles.console(for: current) else { return .notSent(.unreadableScreen) }
        let first: ConsoleScreen
        do {
            first = try await console.readScreen(of: current)
        } catch {
            return .notSent(.unreadableScreen)
        }
        if Self.hasText(first.composerDraft) { return .notSent(.terminalDraft) }
        var state = ClaudeScreen.interpret(first)
        switch ReplyDriver.startCheck(prompt: prompt, screen: state) {
        case .ready: break
        case .terminalDraft: return .notSent(.terminalDraft)
        case .unexpected: return .notSent(.unexpectedScreen)
        }

        // G3 입력: 키 하나 보내고 화면이 그 키에 맞게 바뀌었는지 본 뒤에야 다음 키를 정한다
        onStage(.typing)
        var progress = ReplyProgress()
        var sent = 0
        while true {
            switch ReplyDriver.nextMove(prompt: prompt, draft: draft, progress: &progress, screen: state) {
            case .finished:
                // G4 기록
                onStage(.record)
                return await verifyRecord(expected, session: current, promptId: prompt.id)
            case let .stuck(reason):
                return sent == 0 ? .notSent(.unexpectedScreen) : .stopped(stage: reason)
            case let .send(input):
                guard sent < timing.maxMoves else { return .stopped(stage: "입력 횟수 상한에 닿음") }
                do {
                    try await console.send(input, to: current)
                } catch {
                    return .stopped(stage: "입력을 보내지 못함")
                }
                sent += 1
                switch await settle(after: input, from: state, console: console, session: current) {
                case let .moved(next): state = next
                case let .failed(reason): return .stopped(stage: reason)
                }
            }
        }
    }

    private enum Settle {
        case moved(ScreenState)
        case failed(String)
    }

    /// 화면이 바뀔 때까지 기다린다. 다시 그리는 도중의 화면(알 수 없음, 글이 덜 그려짐)은 결과로 보지 않는다.
    /// 화면 읽기가 한 번 실패해도 시간 제한 안에서는 다시 읽는다 — Ghostty 는 읽을 때마다 osascript·손쉬운 사용을 거쳐 가끔 실패한다
    private func settle(after input: ConsoleInput, from old: ScreenState, console: any TerminalConsole, session: AgentSession) async -> Settle {
        let deadline = ContinuousClock.now + timing.stepTimeout
        var readFailed = false
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: timing.pollInterval)
            guard let screen = try? await console.readScreen(of: session) else {
                readFailed = true
                continue
            }
            readFailed = false
            if Self.hasText(screen.composerDraft) { return .failed("터미널 입력창에 글이 생김") }
            let new = ClaudeScreen.interpret(screen)
            if new == old || new == .unrecognized || ReplyDriver.isPartial(after: input, state: new) { continue }
            return ReplyDriver.isExpected(after: input, from: old, to: new) ? .moved(new) : .failed("화면이 예상과 다르게 바뀜")
        }
        return .failed(readFailed ? "화면을 다시 읽지 못함" : "화면이 바뀌지 않음")
    }

    private func verifyRecord(_ expected: RecordedAnswer, session: AgentSession, promptId: String) async -> DeliveryOutcome {
        let deadline = ContinuousClock.now + timing.recordTimeout
        while true {
            if let recorded = answers(session.key, promptId) {
                return recorded == expected ? .delivered(recorded) : .mismatched(sent: expected, recorded: recorded)
            }
            guard ContinuousClock.now < deadline else { return .mismatched(sent: expected, recorded: nil) }
            try? await Task.sleep(for: timing.pollInterval)
        }
    }

    private static func hasText(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
