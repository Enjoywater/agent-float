import Foundation
import Synchronization
import Testing
@testable import AgentFloatCore

/// 보낸 입력 수에 따라 정해 둔 화면을 돌려주고, 보낸 입력을 남긴다
private final class ScriptedConsole: TerminalConsole, Sendable {
    let readsPromptInput = true
    private let verdict: ConsoleAvailability
    private let screens: @Sendable (Int) throws -> ConsoleScreen
    private let sent = Mutex<[ConsoleInput]>([])

    init(verdict: ConsoleAvailability = .ready, screens: @escaping @Sendable (Int) throws -> ConsoleScreen) {
        self.verdict = verdict
        self.screens = screens
    }

    var inputs: [ConsoleInput] { sent.withLock { $0 } }

    func handles(_ session: AgentSession) -> Bool { true }
    func availability(of session: AgentSession) async -> ConsoleAvailability { verdict }
    func readScreen(of session: AgentSession) async throws -> ConsoleScreen {
        try screens(sent.withLock { $0.count })
    }
    func send(_ input: ConsoleInput, to session: AgentSession) async throws {
        sent.withLock { $0.append(input) }
    }
}

private struct ReadFailure: Error {}

private let promptId = "toolu_01"
private let choicePrompt = PendingPrompt.choices(id: promptId, questions: [expiryQuestion])
private let timing = DeliveryTiming(stepTimeout: .milliseconds(50), pollInterval: .milliseconds(5), recordTimeout: .milliseconds(100))

private func waitingSession(prompt: PendingPrompt = choicePrompt, status: AgentStatus = .waiting) -> AgentSession {
    AgentSession(
        key: SessionKey(providerId: "claude-code", sessionId: "s1"),
        agentName: "Claude",
        title: "캐시 만료 정책 정리",
        cwd: "/Users/me/work",
        status: status,
        waitReason: status == .waiting ? .question : nil,
        statusSince: Date(timeIntervalSince1970: 1_800_000_000),
        isStale: false,
        lastActivityAt: nil,
        terminalApp: .other("tmux"),
        locator: .tmux(socket: "/private/tmp/tmux-501/default", paneId: "%7", pid: 4242),
        prompt: status == .waiting ? prompt : nil
    )
}

private func sequence(_ names: [String]) throws -> @Sendable (Int) throws -> ConsoleScreen {
    let screens = try names.map(screenFixture)
    return { screens[min($0, screens.count - 1)] }
}

/// 선택지 n 개짜리 질문 창에서 포커스만 다른 화면
private func manyOptionScreen(count: Int, focus: Int) -> ConsoleScreen {
    var lines = [String(repeating: "─", count: 40), " ☐ 고르기", "", "열 개 중 고르세요", ""]
    for index in 0..<count {
        lines.append((index == focus ? "❯ " : "  ") + "\(index + 1). 선택지 \(index + 1)")
    }
    lines += ["  \(count + 1). Type something.", String(repeating: "─", count: 40), "  \(count + 2). Chat about this", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]
    return ConsoleScreen(lines: lines, faint: nil, composerDraft: nil)
}

/// 번호가 붙은 줄 중 그 번호 줄만 포커스로 바꾼 화면
private func refocus(_ screen: ConsoleScreen, toRow number: Int) -> ConsoleScreen {
    let lines = screen.lines.map { line -> String in
        guard let marker = line.first, marker == "❯" || marker == " ",
              let match = line.dropFirst().drop(while: { $0 == " " }).prefixMatch(of: #/(\d+)\. /#) else { return line }
        let rest = line.dropFirst().drop(while: { $0 == " " })
        return (Int(match.output.1) == number ? "❯ " : "  ") + rest
    }
    return ConsoleScreen(lines: lines, faint: nil, composerDraft: nil)
}

private final class Stages: Sendable {
    private let log = Mutex<[DeliveryStage]>([])
    func append(_ stage: DeliveryStage) { log.withLock { $0.append(stage) } }
    var all: [DeliveryStage] { log.withLock { $0 } }
}

private func deliver(
    _ draft: ReplyDraft,
    console: ScriptedConsole,
    sessions: [AgentSession] = [waitingSession()],
    record: RecordedAnswer? = nil,
    prompt: PendingPrompt = choicePrompt,
    timing: DeliveryTiming = timing,
    stages: Stages = Stages()
) async -> DeliveryOutcome {
    let delivery = ReplyDelivery(
        currentSessions: { sessions },
        consoles: ConsoleRegistry([console]),
        answers: { key, id in key.sessionId == "s1" && id == prompt.id ? record : nil },
        timing: timing
    )
    return await delivery.deliver(draft, prompt: prompt, session: waitingSession(prompt: prompt)) { stages.append($0) }
}

@Suite struct ReplyDeliveryTests {
    private let question = expiryQuestion.text

    @Test func deliversSingleChoice() async throws {
        let console = ScriptedConsole(screens: try sequence(["choice-single-focus0.txt", "choice-single-focus1.txt", "prompt-busy.txt"]))
        let stages = Stages()
        let outcome = await deliver(.choices([.option(1)]), console: console, record: .choices([question: "고정 10분 유지"]), stages: stages)
        #expect(outcome == .delivered(.choices([question: "고정 10분 유지"])))
        #expect(console.inputs == [.key(.down), .key(.enter)])
        #expect(stages.all == [.sameQuestion, .screen, .typing, .record])
    }

    @Test func deliversOtherText() async throws {
        let start = try screenFixture("choice-single-focus0.txt")
        let screens = [
            start, refocus(start, toRow: 2), refocus(start, toRow: 3),
            try screenFixture("choice-other-focused-empty.txt"), try screenFixture("choice-other-typed.txt"), try screenFixture("prompt-busy.txt"),
        ]
        let console = ScriptedConsole { screens[min($0, screens.count - 1)] }
        let outcome = await deliver(.choices([.other("잠시 대기")]), console: console, record: .choices([question: "잠시 대기"]))
        #expect(outcome == .delivered(.choices([question: "잠시 대기"])))
        #expect(console.inputs == [.key(.down), .key(.down), .key(.down), .text("잠시 대기"), .key(.enter)])
    }

    @Test func answeredMeanwhileSendsNothing() async throws {
        let console = ScriptedConsole(screens: try sequence(["choice-single-focus0.txt"]))
        let outcome = await deliver(.choices([.option(1)]), console: console, sessions: [waitingSession(status: .running)])
        #expect(outcome == .notSent(.alreadyAnswered))
        #expect(console.inputs.isEmpty)
    }

    @Test func changedQuestionSendsNothing() async throws {
        let console = ScriptedConsole(screens: try sequence(["choice-single-focus0.txt"]))
        let newer = PendingPrompt.choices(id: "toolu_99", questions: [expiryQuestion])
        let outcome = await deliver(.choices([.option(1)]), console: console, sessions: [waitingSession(prompt: newer)])
        #expect(outcome == .notSent(.questionChanged))
        #expect(console.inputs.isEmpty)
    }

    @Test func endedSessionSendsNothing() async throws {
        let console = ScriptedConsole(screens: try sequence(["choice-single-focus0.txt"]))
        #expect(await deliver(.choices([.option(1)]), console: console, sessions: []) == .notSent(.sessionEnded))
        #expect(console.inputs.isEmpty)
    }

    @Test func terminalDraftSendsNothing() async throws {
        let console = ScriptedConsole(screens: try sequence(["choice-other-typed.txt"]))
        #expect(await deliver(.choices([.option(1)]), console: console) == .notSent(.terminalDraft))
        #expect(console.inputs.isEmpty)
    }

    @Test func orcaComposerDraftSendsNothing() async throws {
        let base = try screenFixture("choice-single-focus0.txt")
        let console = ScriptedConsole { _ in ConsoleScreen(lines: base.lines, faint: nil, composerDraft: "x") }
        #expect(await deliver(.choices([.option(1)]), console: console) == .notSent(.terminalDraft))
        #expect(console.inputs.isEmpty)
    }

    @Test func unreadableScreenSendsNothing() async {
        let console = ScriptedConsole { _ in throw ReadFailure() }
        #expect(await deliver(.choices([.option(1)]), console: console) == .notSent(.unreadableScreen))
        #expect(console.inputs.isEmpty)
    }

    @Test func readOnlySendsNothing() async throws {
        let console = ScriptedConsole(verdict: .readOnly(.hiddenTab), screens: try sequence(["choice-single-focus0.txt"]))
        #expect(await deliver(.choices([.option(1)]), console: console) == .notSent(.readOnly(.hiddenTab)))
        #expect(console.inputs.isEmpty)
    }

    @Test func unexpectedFirstScreenSendsNothing() async throws {
        let console = ScriptedConsole(screens: try sequence(["prompt-empty.txt"]))
        #expect(await deliver(.choices([.option(1)]), console: console) == .notSent(.unexpectedScreen))
        #expect(console.inputs.isEmpty)
    }

    @Test func typingInTerminalMidwayStops() async throws {
        let console = ScriptedConsole(screens: try sequence(["choice-single-focus0.txt", "choice-other-typed-unfocused.txt"]))
        guard case .stopped = await deliver(.choices([.option(1)]), console: console) else {
            Issue.record("사용자가 터미널에 쓰기 시작하면 멈춰야 함")
            return
        }
        #expect(console.inputs == [.key(.down)])
    }

    /// Ghostty 는 읽을 때마다 osascript·손쉬운 사용을 거쳐 한 번씩 실패할 수 있다. 시간 제한 안에서는 다시 읽는다 (최종 리뷰 M2)
    @Test func oneFailedReadAfterAKeyIsRetried() async throws {
        let start = try screenFixture("choice-single-focus0.txt")
        let busy = try screenFixture("prompt-busy.txt")
        let failedOnce = Mutex(false)
        let console = ScriptedConsole { sent in
            guard sent > 0 else { return start }
            let fails = failedOnce.withLock { failed in
                defer { failed = true }
                return !failed
            }
            if fails { throw ReadFailure() }
            return busy
        }
        let answer = "읽은 때부터 다시 세기 (Recommended)"
        // 여러 테스트가 함께 돌면 50ms 안에 다시 읽을 차례가 오지 않을 수 있어 넉넉히 준다. 성공하면 바로 끝난다
        let roomy = DeliveryTiming(stepTimeout: .seconds(2), pollInterval: .milliseconds(5), recordTimeout: .seconds(2))
        let outcome = await deliver(.choices([.option(0)]), console: console, record: .choices([question: answer]), timing: roomy)
        #expect(outcome == .delivered(.choices([question: answer])))
    }

    @Test func screenThatStaysUnreadableStops() async throws {
        let start = try screenFixture("choice-single-focus0.txt")
        let console = ScriptedConsole { sent in
            guard sent > 0 else { return start }
            throw ReadFailure()
        }
        #expect(await deliver(.choices([.option(0)]), console: console) == .stopped(stage: "화면을 다시 읽지 못함"))
    }

    @Test func unchangedScreenAfterKeyStops() async throws {
        let console = ScriptedConsole(screens: try sequence(["choice-single-focus0.txt"]))
        guard case .stopped = await deliver(.choices([.option(1)]), console: console) else {
            Issue.record("키가 먹지 않으면 멈춰야 함")
            return
        }
        #expect(console.inputs == [.key(.down)])
    }

    @Test func wrongRecordIsMismatch() async throws {
        let console = ScriptedConsole(screens: try sequence(["choice-single-focus0.txt", "prompt-busy.txt"]))
        let outcome = await deliver(.choices([.option(0)]), console: console, record: .choices([question: "고정 10분 유지"]))
        #expect(outcome == .mismatched(
            sent: .choices([question: "읽은 때부터 다시 세기 (Recommended)"]),
            recorded: .choices([question: "고정 10분 유지"])
        ))
    }

    @Test func missingRecordTimesOut() async throws {
        let console = ScriptedConsole(screens: try sequence(["choice-single-focus0.txt", "prompt-busy.txt"]))
        let outcome = await deliver(.choices([.option(0)]), console: console, record: nil)
        #expect(outcome == .mismatched(sent: .choices([question: "읽은 때부터 다시 세기 (Recommended)"]), recorded: nil))
    }

    @Test func moveLimitStops() async {
        let options = (1...10).map { ChoiceOption(label: "선택지 \($0)", description: nil, hasPreview: false) }
        let prompt = PendingPrompt.choices(id: promptId, questions: [ChoiceQuestion(text: "열 개 중 고르세요", header: nil, multiSelect: false, options: options)])
        let console = ScriptedConsole { manyOptionScreen(count: 10, focus: min($0, 9)) }
        var limited = timing
        limited.maxMoves = 3
        guard case .stopped = await deliver(.choices([.option(9)]), console: console, sessions: [waitingSession(prompt: prompt)], prompt: prompt, timing: limited) else {
            Issue.record("횟수 상한에서 멈춰야 함")
            return
        }
        #expect(console.inputs.count == 3)
    }

    @Test func neverRetriesAfterStop() async throws {
        let console = ScriptedConsole(screens: try sequence(["choice-single-focus0.txt"]))
        _ = await deliver(.choices([.option(1)]), console: console)
        let afterReturn = console.inputs.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(console.inputs.count == afterReturn)
    }

    /// Orca 에서 본문 질문에 답하는 전체 흐름: 안내 문구만 있는 빈 칸 → 넣은 글이 `draft` 로 보임 → Enter 뒤 `draft` 없음 (실측 S5 ④)
    @Test func deliversBodyReplyThroughOrcaDraft() async {
        let sends = Mutex(0)
        let runner = FakeCommandRunner { call in
            if call.arguments.contains("send") {
                sends.withLock { $0 += 1 }
                return #"{"ok":true,"result":{"send":{"accepted":true}}}"#
            }
            switch sends.withLock({ $0 }) {
            case 0: return orcaScreenJSON(orcaPromptTail("❯\u{a0}Try \"create a util logging.py that...\""))
            case 1: return orcaScreenJSON(orcaPromptTail("❯"), draft: "응, 진행해 줘")
            default: return orcaScreenJSON(orcaPromptTail("❯"))
            }
        }
        let session = AgentSession(
            key: SessionKey(providerId: "claude-code", sessionId: "s1"), agentName: "Claude", title: "캐시 만료 정책 정리", cwd: "/Users/me/work",
            status: .waiting, waitReason: .bodyQuestion, statusSince: Date(timeIntervalSince1970: 1_800_000_000), isStale: false, lastActivityAt: nil,
            terminalApp: .orca, locator: .orca(tabId: "t1", leafId: "l1", handle: "term_00000000-0000-4000-8000-000000000002"), prompt: Self.bodyPrompt
        )
        let delivery = ReplyDelivery(
            currentSessions: { [session] },
            consoles: ConsoleRegistry([OrcaConsole(runner: runner)]),
            answers: { _, _ in .text("응, 진행해 줘") },
            timing: timing
        )
        let outcome = await delivery.deliver(.text("응, 진행해 줘"), prompt: Self.bodyPrompt, session: session) { _ in }
        #expect(outcome == .delivered(.text("응, 진행해 줘")))
        #expect(sends.withLock { $0 } == 2)
    }

    private static let bodyPrompt = PendingPrompt.text(id: "a-9", message: "다음 작업을 진행할까요?")

    @Test func deliversBodyReply() async throws {
        let body = PendingPrompt.text(id: "a-2", message: "다음 작업을 진행할까요?")
        let typed = ConsoleScreen(lines: try screenFixture("prompt-draft.txt").lines.map {
            $0.hasPrefix("❯\u{a0}") ? "❯\u{a0}응, 진행해 줘" : $0
        }, faint: nil, composerDraft: nil)
        let empty = try screenFixture("prompt-empty.ansi")
        let console = ScriptedConsole { [empty, typed, empty][min($0, 2)] }
        let outcome = await deliver(.text("응, 진행해 줘"), console: console, sessions: [waitingSession(prompt: body)], record: .text("응, 진행해 줘"), prompt: body)
        #expect(outcome == .delivered(.text("응, 진행해 줘")))
        #expect(console.inputs == [.text("응, 진행해 줘"), .key(.enter)])
    }
}
