import Foundation
import Testing
@testable import AgentFloatCore

struct CodexBehaviorTests {
    @Test func synchronousQueriesFinishAndCaptureFailure() throws {
        #expect(try SyncCommand.run("/bin/echo", ["ready"]) == "ready\n")
        #expect(throws: NavigationError.commandFailed("failure\n")) {
            try SyncCommand.run("/bin/sh", ["-c", "echo failure >&2; exit 1"])
        }
    }

    @Test func synchronousQueriesHonorDeadline() {
        let started = ProcessInfo.processInfo.systemUptime
        #expect(throws: CodexRPCError.self) { try SyncCommand.run("/bin/sleep", ["5"], timeout: 0.05) }
        #expect(ProcessInfo.processInfo.systemUptime - started < 1)
    }

    private static let cwd = "/project"
    private static func inventory(processes: [CodexProcess], titles: [String]) -> CodexTerminalInventory {
        CodexTerminalInventory(processes: processes, ghostty: titles.enumerated().map {
            GhosttyTerminal(id: "surface-\($0.offset)", title: $0.element, cwd: cwd)
        }, titlesByTTY: [:], tmuxTitles: [:], orcaTitles: [:])
    }
    private static let process = CodexProcess(pid: 42, cwd: cwd, environment: ["TERM_PROGRAM": "ghostty"], tty: "/dev/ttys001")

    @Test func excludesLoadedThreadWithoutLiveTerminal() {
        let live = Self.inventory(processes: [Self.process], titles: ["⠹ Current | project"])
        #expect(live.placement(title: "Old", cwd: Self.cwd) == nil)
        #expect(live.placement(title: nil, cwd: Self.cwd) == nil)
        #expect(live.placement(title: "Current", cwd: Self.cwd)?.locator == .ghostty(title: "Current | project", cwd: Self.cwd))
        let dead = Self.inventory(processes: [], titles: ["Current | project"])
        #expect(dead.placement(title: "Current", cwd: Self.cwd) == nil)
        let ambiguous = Self.inventory(processes: [Self.process], titles: ["Current | project", "Current | project"])
        #expect(ambiguous.placement(title: "Current", cwd: Self.cwd) == nil)
    }

    @Test func matchesSpinnerChangesWithoutMatchingArbitrarySubstrings() {
        for spinner in ["⠋ ", "⠹ ", "⠴ ", ""] {
            #expect(CodexTerminalInventory.matches(spinner + "Current | project", title: "Current", cwd: Self.cwd))
        }
        #expect(!CodexTerminalInventory.matches("Different Current | project", title: "Current", cwd: Self.cwd))
        #expect(!CodexTerminalInventory.matches("Current | another-project", title: "Current", cwd: Self.cwd))
    }

    private static func line(_ payload: String, type: String = "response_item", timestamp: String = "t") -> String {
        "{\"timestamp\":\"\(timestamp)\",\"type\":\"\(type)\",\"payload\":\(payload)}\n"
    }

    @Test func detectsQuestionAndVerifiesExactBodyReplyAcrossNewTurn() throws {
        let question = Self.line(#"{"type":"message","id":"answer1","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"어떤 색상을 원하시나요?"}]}"#)
        let before = CodexTranscript.parse(Data(question.utf8), sessionID: "s")
        #expect(before.lastMessage?.id == "codex:s:answer1")
        #expect(QuestionHeuristic.endsWithQuestion(try #require(before.lastMessage?.text)))
        let next = Self.line(#"{"type":"task_started","turn_id":"next"}"#, type: "event_msg")
        let reply = Self.line(#"{"type":"message","role":"user","content":[{"type":"input_text","text":"파란색"}]}"#)
        let after = CodexTranscript.parse(Data((question + next + reply).utf8), sessionID: "s")
        #expect(after.records["codex:s:answer1"] == .text("파란색"))
        #expect(after.lastMessage == nil)
    }

    private static let request = #"{"type":"function_call","name":"request_user_input","call_id":"call1","arguments":"{\"questions\":[{\"id\":\"color\",\"header\":\"Color\",\"question\":\"Which color should we use?\",\"options\":[{\"label\":\"Blue (Recommended)\",\"description\":\"Blue theme.\"},{\"label\":\"Green\",\"description\":\"Green theme.\"}]}]}"}"#

    @Test func detectsStructuredQuestionAndNormalizesNativeNotesRecord() throws {
        let data = Self.line(Self.request)
        let before = CodexTranscript.parse(Data(data.utf8), sessionID: "s")
        guard case let .choices(id, questions)? = before.pendingChoice else { Issue.record("missing choices"); return }
        #expect(id == "codex:s:call1")
        #expect(questions.first?.options.map(\.label) == ["Blue (Recommended)", "Green"])
        let output = Self.line(#"{"type":"function_call_output","call_id":"call1","output":"{\"answers\":{\"color\":{\"answers\":[\"None of the above\",\"user_note: Purple\"]}}}"}"#)
        let after = CodexTranscript.parse(Data((data + output).utf8), sessionID: "s")
        #expect(after.pendingChoice == nil)
        #expect(after.records[id] == .choices(["Which color should we use?": "Purple"]))
        // 기록 중인 출력으로는 답변 완료로 판정하지 않는다.
        let incomplete = CodexTranscript.parse(Data((data + output.dropLast()).utf8), sessionID: "s")
        #expect(incomplete.records[id] == nil)
        #expect(incomplete.pendingChoice != nil)
    }

    private static let screen = """
    › previous input

      Question 1/1 (1 unanswered)
      Which color should we use?

      › 1. Blue (Recommended)  Blue theme.
        2. Green               Green theme.
        3. None of the above   Optionally, add details in notes (tab)

      tab to add notes | enter to submit answer | esc to interrupt
    """

    @Test func interpretsActualCodexDialogAndDrivesChoice() throws {
        let state = CodexScreen.interpret(ConsoleScreen(lines: Self.screen.components(separatedBy: "\n"), faint: nil, composerDraft: nil))
        let tail = CodexTranscript.parse(Data(Self.line(Self.request).utf8), sessionID: "s")
        let prompt = try #require(tail.pendingChoice)
        #expect(ReplyDriver.startCheck(prompt: prompt, screen: state) == .ready)
        var progress = ReplyProgress()
        #expect(ReplyDriver.nextMove(prompt: prompt, draft: .choices([.option(1)]), progress: &progress, screen: state, codex: true) == .send(.key(.down)))
        let selected = Self.screen.replacingOccurrences(of: "› 1.", with: "  1.").replacingOccurrences(of: "  2.", with: "› 2.")
        let next = CodexScreen.interpret(ConsoleScreen(lines: selected.components(separatedBy: "\n"), faint: nil, composerDraft: nil))
        #expect(ReplyDriver.isExpected(after: .key(.down), from: state, to: next))
        #expect(ReplyDriver.nextMove(prompt: prompt, draft: .choices([.option(1)]), progress: &progress, screen: next, codex: true) == .send(.key(.enter)))
        #expect(progress.pressedSubmit)
    }

    @Test func readsNativeNotesAndRefusesExistingDraft() throws {
        let notes = Self.screen.replacingOccurrences(of: "› 1.", with: "  1.")
            .replacingOccurrences(of: "  3.", with: "› 3.")
            .replacingOccurrences(of: "tab to add notes | enter to submit answer | esc to interrupt", with: "› Purple\n\n  tab or esc to clear notes | enter to submit answer")
        let state = CodexScreen.interpret(ConsoleScreen(lines: notes.components(separatedBy: "\n"), faint: nil, composerDraft: nil))
        guard case let .choiceDialog(dialog) = state else { Issue.record("missing dialog"); return }
        #expect(dialog.notesActive)
        #expect(dialog.otherDraft == "Purple")
        let prompt = try #require(CodexTranscript.parse(Data(Self.line(Self.request).utf8), sessionID: "s").pendingChoice)
        #expect(ReplyDriver.startCheck(prompt: prompt, screen: state) == .terminalDraft)
    }

    @Test func readsBodyComposerAndFaintPlaceholder() {
        let raw = ConsoleScreen.ansi("› \u{1b}[2mAsk Codex to do anything\u{1b}[0m\n\n  model default")
        #expect(CodexScreen.interpret(raw) == .prompt(draft: ""))
        let typed = ConsoleScreen(lines: ["› Purple", "", "  model default"], faint: nil, composerDraft: nil)
        #expect(CodexScreen.interpret(typed) == .prompt(draft: "Purple"))
    }

    @Test func finalQuestionUsesSubmitAllFooter() {
        let final = Self.screen.replacingOccurrences(of: "Question 1/1", with: "Question 2/2")
            .replacingOccurrences(of: "enter to submit answer", with: "enter to submit all")
        let state = CodexScreen.interpret(ConsoleScreen(lines: final.components(separatedBy: "\n"), faint: nil, composerDraft: nil))
        guard case .choiceDialog = state else { Issue.record("final question was mistaken for body composer"); return }
    }
}
