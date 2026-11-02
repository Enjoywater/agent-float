import Foundation

/// Keep stages aligned with the four sending-status rows (v1.2 design draft 6).
public enum DeliveryStage: Int, CaseIterable, Sendable {
    case sameQuestion, screen, typing, record
}

/// Reasons for stopping before sending any keys.
public enum NotSentReason: Equatable, Sendable {
    case alreadyAnswered, questionChanged, sessionEnded, terminalDraft, unexpectedScreen, unreadableScreen
    case readOnly(ReadOnlyReason)
}

public enum DeliveryOutcome: Equatable, Sendable {
    case delivered(RecordedAnswer)
    case notSent(NotSentReason)
    /// Stopped during input; some keys may already have reached the terminal.
    case stopped(stage: String)
    /// Recorded reply differs from intended input; nil means no record arrived before the deadline.
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

/// Verify four gates in order; stop immediately on any mismatch and never retry delivery (v1.2 design §4.4).
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

        // G1: Same question
        onStage(.sameQuestion)
        guard let current = await currentSessions().first(where: { $0.key == session.key }) else { return .notSent(.sessionEnded) }
        guard current.status == .waiting else { return .notSent(.alreadyAnswered) }
        guard current.prompt?.id == prompt.id, current.waitReason == session.waitReason else { return .notSent(.questionChanged) }

        // G2: Screen
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
        let isCodex = current.key.providerId == "codex"
        var state = isCodex ? CodexScreen.interpret(first) : ClaudeScreen.interpret(first)
        switch ReplyDriver.startCheck(prompt: prompt, screen: state, check: console.promptCheck) {
        case .ready: break
        case .terminalDraft: return .notSent(.terminalDraft)
        case .unexpected: return .notSent(.unexpectedScreen)
        }

        // G3: Send one key and verify its resulting screen before choosing the next.
        onStage(.typing)
        var progress = ReplyProgress()
        var sent = 0
        while true {
            switch ReplyDriver.nextMove(prompt: prompt, draft: draft, progress: &progress, screen: state, check: console.promptCheck, codex: isCodex) {
            case .finished:
                // G4: Transcript
                onStage(.record)
                return await verifyRecord(expected, session: current, promptId: prompt.id)
            case let .stuck(reason):
                return sent == 0 ? .notSent(.unexpectedScreen) : .stopped(stage: reason)
            case .restored:
                return .notSent(.terminalDraft)
            case let .send(input):
                guard sent < timing.maxMoves else { return .stopped(stage: "입력 횟수 상한에 닿음") }
                do {
                    try await console.send(input, to: current)
                } catch {
                    return .stopped(stage: "입력을 보내지 못함")
                }
                sent += 1
                if isCodex, input == .key(.enter), progress.pressedSubmit {
                    // Codex may immediately show an identical-looking new question; verify via history without further input.
                    onStage(.record)
                    return await verifyRecord(expected, session: current, promptId: prompt.id)
                }
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

    /// Wait for a settled screen; unknown or partially rendered frames are not final results.
    /// Retry transient reads within the deadline because Ghostty's osascript/Accessibility path can fail intermittently.
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
            let new = session.key.providerId == "codex" ? CodexScreen.interpret(screen) : ClaudeScreen.interpret(screen)
            if new == old || new == .unrecognized { continue }
            // A probe matching a suggestion prefix can look like hint text; check the expected result first.
            if ReplyDriver.isExpected(after: input, from: old, to: new, check: console.promptCheck) { return .moved(new) }
            if ReplyDriver.isPartial(after: input, from: old, state: new) { continue }
            return .failed("화면이 예상과 다르게 바뀜")
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
