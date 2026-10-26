import Foundation
import Testing
@testable import AgentFloatCore

private let socket = "/private/tmp/tmux-501/default"
private let tmuxExe = "/opt/homebrew/bin/tmux"
private let handle = "term_00000000-0000-4000-8000-000000000002"
private let choicePrompt = PendingPrompt.choices(id: "toolu_01", questions: [expiryQuestion])
private let bodyPrompt = PendingPrompt.text(id: "a-2", message: "다음 작업을 진행할까요?")

private func waiting(
    _ locator: TerminalLocator,
    app: TerminalApp = .unknown,
    prompt: PendingPrompt? = choicePrompt
) -> AgentSession {
    AgentSession(
        key: SessionKey(providerId: "claude-code", sessionId: "s1"),
        agentName: "Claude",
        title: "캐시 만료 정책 정리",
        cwd: "/Users/me/work",
        status: .waiting,
        waitReason: .question,
        statusSince: Date(timeIntervalSince1970: 1_800_000_000),
        isStale: false,
        lastActivityAt: nil,
        terminalApp: app,
        locator: locator,
        prompt: prompt
    )
}

private func fixtureData(_ name: String, _ ext: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/screens"))
    return try Data(contentsOf: url)
}

/// Orca `read --screen --json` 응답. 실측 S5: 입력 칸의 실제 글은 `tail` 에서 빠지고 `draft` 로만 온다
func orcaScreenJSON(_ tail: [String], draft: String? = nil) -> String {
    var terminal: [String: Any] = ["tail": tail, "source": "screen"]
    if let draft { terminal["draft"] = draft }
    let data = try! JSONSerialization.data(withJSONObject: ["ok": true, "result": ["terminal": terminal]])
    return String(decoding: data, as: UTF8.self)
}

/// 빈 칸이면 흐린 안내 문구가 일반 글자로 보이고, 글이 있으면 `❯` 만 남는다 (실측 S5 ④)
func orcaPromptTail(_ promptLine: String) -> [String] {
    ["⏺ 이전 답변을 정리했습니다.", "", "✻ Brewed for 3s", "", String(repeating: "─", count: 40), promptLine, String(repeating: "─", count: 40), "  ◆ Haiku │ 0%"]
}

/// 판정 결과만 정해 두고 호출 여부를 남긴다
private struct StubConsole: TerminalConsole {
    let promptCheck: PromptCheck
    let verdict: ConsoleAvailability
    let calls: CallLog<String>

    func handles(_ session: AgentSession) -> Bool { true }
    func availability(of session: AgentSession) async -> ConsoleAvailability {
        calls.append("availability")
        return verdict
    }
    func readScreen(of session: AgentSession) async throws -> ConsoleScreen {
        ConsoleScreen(lines: [], faint: nil, composerDraft: nil)
    }
    func send(_ input: ConsoleInput, to session: AgentSession) async throws {}
}

@Suite struct TerminalConsoleTests {
    private let tmuxSession = waiting(.tmux(socket: socket, paneId: "%7", pid: 4242), app: .other("tmux"))
    private let orcaSession = waiting(.orca(tabId: "t1", leafId: "l1", handle: handle), app: .orca)

    // MARK: tmux

    @Test func tmuxSendsLiteralText() async throws {
        let runner = FakeCommandRunner { _ in "" }
        try await TmuxConsole(runner: runner, executable: tmuxExe).send(.text("잠시 대기"), to: tmuxSession)
        #expect(await runner.calls == [.init(executable: tmuxExe, arguments: ["-S", socket, "send-keys", "-t", "%7", "-l", "--", "잠시 대기"])])
    }

    @Test func tmuxSendsNamedKeys() async throws {
        let runner = FakeCommandRunner { _ in "" }
        let console = TmuxConsole(runner: runner, executable: tmuxExe)
        for key in ConsoleKey.allCases where key != .backspace { try await console.send(.key(key), to: tmuxSession) }
        let names = await runner.calls.map { $0.arguments.last }
        #expect(names == ["Enter", "Up", "Down", "Left", "Right", "Tab", "Space"])
        #expect(await runner.calls.allSatisfy { $0.arguments.prefix(5) == ["-S", socket, "send-keys", "-t", "%7"] })
    }

    /// 넣기 전에 판정하는 콘솔은 지울 일이 없다. 지우기 키는 넣어 보고 확인하는 콘솔에만 열어 둔다 (R78)
    @Test func beforeTypingConsolesNeverErase() async {
        let runner = FakeCommandRunner { _ in #"{"ok":true,"result":{"send":{"accepted":true}}}"# }
        await #expect(throws: NavigationError.self) {
            try await TmuxConsole(runner: runner, executable: tmuxExe).send(.key(.backspace), to: tmuxSession)
        }
        await #expect(throws: NavigationError.self) {
            try await OrcaConsole(runner: runner).send(.key(.backspace), to: orcaSession)
        }
        #expect(await runner.calls.isEmpty)
    }

    @Test func tmuxReadsPaneWithStyles() async throws {
        let ansi = String(decoding: try fixtureData("prompt-suggestion", "ansi"), as: UTF8.self)
        let runner = FakeCommandRunner { _ in ansi }
        let screen = try await TmuxConsole(runner: runner, executable: tmuxExe).readScreen(of: tmuxSession)
        #expect(await runner.calls == [.init(executable: tmuxExe, arguments: ["-S", socket, "capture-pane", "-p", "-e", "-t", "%7"])])
        #expect(ClaudeScreen.interpret(screen) == .prompt(draft: ""))
    }

    @Test func tmuxRejectsUnsafeLocator() async throws {
        let runner = FakeCommandRunner { _ in "" }
        let console = TmuxConsole(runner: runner, executable: tmuxExe)
        for session in [
            waiting(.tmux(socket: "/tmp/with space", paneId: "%7", pid: 1), app: .other("tmux")),
            waiting(.tmux(socket: socket, paneId: "7", pid: 1), app: .other("tmux")),
        ] {
            #expect(await console.availability(of: session) == .readOnly(.unsupportedTerminal("tmux")))
            await #expect(throws: NavigationError.terminalNotFound) { try await console.send(.key(.enter), to: session) }
        }
        #expect(await TmuxConsole(runner: runner, executable: nil).availability(of: tmuxSession) == .readOnly(.unsupportedTerminal("tmux")))
        #expect(await runner.calls.isEmpty)
    }

    @Test func tmuxRefusesControlCharacters() async throws {
        let runner = FakeCommandRunner { _ in "" }
        let console = TmuxConsole(runner: runner, executable: tmuxExe)
        await #expect(throws: NavigationError.commandFailed("unsafe text")) { try await console.send(.text("a\nb"), to: tmuxSession) }
        #expect(await runner.calls.isEmpty)
    }

    // MARK: Orca

    @Test func orcaSendsTextAndEnter() async throws {
        let runner = FakeCommandRunner { _ in #"{"ok":true,"result":{"send":{"accepted":true}}}"# }
        let console = OrcaConsole(runner: runner)
        try await console.send(.text("잠시 대기"), to: orcaSession)
        try await console.send(.key(.enter), to: orcaSession)
        #expect(await runner.calls.map(\.arguments) == [
            ["terminal", "send", "--terminal", handle, "--text", "잠시 대기", "--json"],
            ["terminal", "send", "--terminal", handle, "--enter", "--json"],
        ])
    }

    /// `--text --dry-run` 은 Orca 가 "값 없음"으로 거절한다(실측). `--text=<글>` 로 붙이면 값으로 받는다 (최종 리뷰 M3)
    @Test func orcaSendsDashLedTextAsOneArgument() async throws {
        let runner = FakeCommandRunner { _ in #"{"ok":true,"result":{"send":{"accepted":true}}}"# }
        try await OrcaConsole(runner: runner).send(.text("--dry-run 으로 먼저"), to: orcaSession)
        #expect(await runner.calls.map(\.arguments) == [["terminal", "send", "--terminal", handle, "--text=--dry-run 으로 먼저", "--json"]])
    }

    @Test func orcaSendsArrowsAsSequences() async throws {
        let runner = FakeCommandRunner { _ in #"{"ok":true,"result":{"send":{"accepted":true}}}"# }
        let console = OrcaConsole(runner: runner)
        for key in [ConsoleKey.up, .down, .right, .left, .tab, .space] { try await console.send(.key(key), to: orcaSession) }
        let texts = await runner.calls.map { $0.arguments[5] }
        #expect(texts == ["\u{1b}[A", "\u{1b}[B", "\u{1b}[C", "\u{1b}[D", "\t", " "])
    }

    @Test func orcaRejectedSendFails() async throws {
        let runner = FakeCommandRunner { _ in #"{"ok":true,"result":{"send":{"accepted":false}}}"# }
        await #expect(throws: NavigationError.self) { try await OrcaConsole(runner: runner).send(.key(.enter), to: orcaSession) }
    }

    @Test func orcaReadsScreenAndDraft() async throws {
        let plain = try fixtureData("orca-read-screen", "json")
        let drafted = try fixtureData("orca-read-screen-draft", "json")
        let screen = try OrcaCLI.parseScreen(plain)
        #expect(screen.faint == nil)
        #expect(screen.composerDraft == nil)
        guard case .choiceDialog = ClaudeScreen.interpret(screen) else {
            Issue.record("질문 창으로 읽혀야 함")
            return
        }
        #expect(try OrcaCLI.parseScreen(drafted).composerDraft == "오르카 입력창 글")

        let runner = FakeCommandRunner { _ in String(decoding: plain, as: UTF8.self) }
        _ = try await OrcaConsole(runner: runner).readScreen(of: orcaSession)
        #expect(await runner.calls.map(\.arguments) == [["terminal", "read", "--terminal", handle, "--screen", "--json"]])
    }

    /// `screen-unavailable` 은 렌더된 화면이 아니라 겹쳐 쓴 조각이 쌓인 누적 출력이다. 없으면 그 구분을 모르는 옛 Orca 다. 둘 다 화면으로 믿지 않는다 (최종 리뷰 I2)
    @Test func orcaReadsOnlyARenderedScreen() throws {
        let plain = String(decoding: try fixtureData("orca-read-screen", "json"), as: UTF8.self)
        let unavailable = plain.replacingOccurrences(of: "\"source\": \"screen\"", with: "\"source\": \"screen-unavailable\"")
        let absent = plain.replacingOccurrences(of: #",\s*"source": "screen""#, with: "", options: .regularExpression)
        #expect(unavailable != plain && absent != plain)
        #expect(throws: NavigationError.self) { try OrcaCLI.parseScreen(Data(unavailable.utf8)) }
        #expect(throws: NavigationError.self) { try OrcaCLI.parseScreen(Data(absent.utf8)) }
    }

    // MARK: Orca 입력 칸 (실측 S5)

    @Test func orcaPlaceholderReadsAsAnEmptyPrompt() async throws {
        let runner = FakeCommandRunner { _ in orcaScreenJSON(orcaPromptTail("❯\u{a0}Try \"create a util logging.py that...\"")) }
        let screen = try await OrcaConsole(runner: runner).readScreen(of: orcaSession)
        #expect(ClaudeScreen.interpret(screen) == .prompt(draft: ""))
        #expect(screen.composerDraft == nil)
    }

    @Test func orcaDraftIsThePromptInput() async throws {
        let runner = FakeCommandRunner { _ in orcaScreenJSON(orcaPromptTail("❯"), draft: "응, 진행해 줘") }
        let screen = try await OrcaConsole(runner: runner).readScreen(of: orcaSession)
        #expect(ClaudeScreen.interpret(screen) == .prompt(draft: "응, 진행해 줘"))
        #expect(screen.composerDraft == nil)
    }

    /// 질문 창이 떠 있을 때의 `draft` 는 어디에 쓰인 글인지 화면으로 확인할 수 없어, 지금처럼 쓰던 글로 보고 보내지 않는다
    @Test func orcaDraftUnderADialogStillBlocks() async throws {
        let dialog = try JSONSerialization.jsonObject(with: try fixtureData("orca-read-screen", "json")) as? [String: Any]
        let tail = try #require(((dialog?["result"] as? [String: Any])?["terminal"] as? [String: Any])?["tail"] as? [String])
        let runner = FakeCommandRunner { _ in orcaScreenJSON(tail, draft: "쓰던 글") }
        let screen = try await OrcaConsole(runner: runner).readScreen(of: orcaSession)
        guard case .choiceDialog = ClaudeScreen.interpret(screen) else {
            Issue.record("질문 창으로 읽혀야 함")
            return
        }
        #expect(screen.composerDraft == "쓰던 글")
    }

    @Test func orcaAnswersBodyQuestions() async {
        let registry = ConsoleRegistry([OrcaConsole(runner: FakeCommandRunner { _ in "" })])
        #expect(await registry.availability(of: waiting(.orca(tabId: "t1", leafId: "l1", handle: handle), app: .orca, prompt: bodyPrompt)) == .ready)
    }

    @Test func orcaWithoutHandleIsReadOnly() async {
        let runner = FakeCommandRunner { _ in "" }
        let session = waiting(.orca(tabId: "t1", leafId: "l1", handle: nil), app: .orca)
        #expect(await OrcaConsole(runner: runner).availability(of: session) == .readOnly(.unsupportedTerminal("Orca")))
    }

    // MARK: registry

    @Test func registryPrefersPromptReasons() async {
        let calls = CallLog<String>()
        let registry = ConsoleRegistry([StubConsole(promptCheck: .beforeTyping, verdict: .ready, calls: calls)])
        let permission = waiting(.none, prompt: .permission(id: "toolu_02", tool: "Bash", summary: "swift test"))
        #expect(await registry.availability(of: permission) == .readOnly(.permissionPrompt))
        let preview = ChoiceQuestion(text: "어느 배치가 좋을까요?", header: nil, multiSelect: false, options: [
            ChoiceOption(label: "가", description: nil, hasPreview: true),
        ])
        #expect(await registry.availability(of: waiting(.none, prompt: .choices(id: "toolu_03", questions: [preview]))) == .readOnly(.previewQuestion))
        #expect(calls.entries.isEmpty)
        #expect(await registry.availability(of: waiting(.none)) == .ready)
    }

    /// 흐림을 읽지 못하는 콘솔도 넣어 보고 확인해 답한다 (R78)
    @Test func bodyQuestionIsAnsweredWithEitherCheck() async {
        let calls = CallLog<String>()
        let probing = ConsoleRegistry([StubConsole(promptCheck: .afterTyping, verdict: .ready, calls: calls)])
        #expect(await probing.availability(of: waiting(.none, prompt: bodyPrompt)) == .ready)
        let sighted = ConsoleRegistry([StubConsole(promptCheck: .beforeTyping, verdict: .ready, calls: calls)])
        #expect(await sighted.availability(of: waiting(.none, prompt: bodyPrompt)) == .ready)
    }

    @Test func orcaTeamTmuxSessionUsesTmux() {
        let runner = FakeCommandRunner { _ in "" }
        let registry = ConsoleRegistry([OrcaConsole(runner: runner), TmuxConsole(runner: runner, executable: tmuxExe)])
        let session = waiting(.tmux(socket: socket, paneId: "%1", pid: 9), app: .orca)
        #expect(registry.console(for: session) is TmuxConsole)
    }

    @Test func unsupportedTerminalNamesApp() async {
        let runner = FakeCommandRunner { _ in "" }
        let registry = ConsoleRegistry([OrcaConsole(runner: runner), TmuxConsole(runner: runner, executable: tmuxExe)])
        #expect(await registry.availability(of: waiting(.appleTerminal(tty: "/dev/ttys004"), app: .other("Apple_Terminal")))
            == .readOnly(.unsupportedTerminal("Terminal")))
        #expect(await registry.availability(of: waiting(.iTerm(tty: "/dev/ttys005"), app: .other("iTerm.app")))
            == .readOnly(.unsupportedTerminal("iTerm2")))
        #expect(await registry.availability(of: waiting(.application(pid: 4012), app: .other("Cursor")))
            == .readOnly(.unsupportedTerminal("Cursor")))
        #expect(await registry.availability(of: waiting(.background(jobId: "job1"), app: .unknown))
            == .readOnly(.unsupportedTerminal("이")))
    }
}
