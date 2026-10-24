import Foundation
import Testing
@testable import AgentFloatCore

/// 화면 fixture 는 실측 화면의 줄 모양만 따르고 내용은 가상이다 (rulings "v1.2 답장")
func screenFixture(_ name: String) throws -> ConsoleScreen {
    let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
    let url = try #require(Bundle.module.url(forResource: parts[0], withExtension: parts[1], subdirectory: "Fixtures/screens"))
    let text = try String(contentsOf: url, encoding: .utf8)
    if parts[1] == "ansi" { return ConsoleScreen.ansi(text) }
    return ConsoleScreen(lines: text.components(separatedBy: "\n"), faint: nil, composerDraft: nil)
}

let expiryQuestion = ChoiceQuestion(
    text: "캐시 만료 방식을 어떻게 할까요?",
    header: "만료 방식",
    multiSelect: false,
    options: [
        ChoiceOption(label: "읽은 때부터 다시 세기 (Recommended)", description: "읽을 때마다 만료가 10분 늘어남", hasPreview: false),
        ChoiceOption(label: "고정 10분 유지", description: "바꾼 코드를 되돌림", hasPreview: false),
        ChoiceOption(label: "둘 다 지원", description: "설정 항목이 하나 늘어남", hasPreview: false),
    ]
)

@Suite struct ClaudeScreenTests {
    private func dialog(_ name: String) throws -> ChoiceDialog {
        guard case let .choiceDialog(dialog) = ClaudeScreen.interpret(try screenFixture(name)) else {
            Issue.record("\(name) 이 질문 창으로 읽히지 않음")
            throw CancellationError()
        }
        return dialog
    }

    @Test func singleChoiceDialogIsRead() throws {
        let read = try dialog("choice-single-focus0.txt")
        #expect(read.questionText == "캐시 만료 방식을 어떻게 할까요?")
        #expect(read.rows.map(\.kind) == [.option, .option, .option, .other, .chat])
        #expect(read.rows.prefix(3).map(\.label) == expiryQuestion.options.map(\.label))
        #expect(read.focusedIndex == 0)
        #expect(read.otherDraft == "")
    }

    /// 설명 줄이 "3. …" 처럼 번호로 시작해도 선택지가 아니다. 설명은 다섯 칸 들여 써 있다 (최종 리뷰 M4)
    @Test func numberedDescriptionIsNotAnOption() throws {
        let base = try screenFixture("choice-single-focus0.txt")
        let lines = base.lines.map { $0 == "     바꾼 코드를 되돌림" ? "     3. 단계로 나눠 되돌림" : $0 }
        #expect(lines != base.lines)
        guard case let .choiceDialog(read) = ClaudeScreen.interpret(ConsoleScreen(lines: lines, faint: nil, composerDraft: nil)) else {
            Issue.record("질문 창으로 읽혀야 함")
            return
        }
        #expect(ClaudeScreen.matches(read, question: expiryQuestion))
        #expect(read.rows.count == 5)
    }

    @Test func focusMovesAreRead() throws {
        #expect(try dialog("choice-single-focus1.txt").focusedIndex == 1)
        #expect(try dialog("choice-other-focused-empty.txt").focusedIndex == 3)
        #expect(try dialog("choice-other-focused-empty.txt").otherDraft == "")
    }

    @Test func otherDraftIsRead() throws {
        #expect(try dialog("choice-other-typed.txt").otherDraft == "잠시 대기")
        let unfocused = try dialog("choice-other-typed-unfocused.txt")
        #expect(unfocused.otherDraft == "잠시 대기")
        #expect(unfocused.focusedIndex == 2)
    }

    @Test func checkedRowsAreRead() throws {
        let read = try dialog("choice-multiselect-checked.txt")
        #expect(read.rows.map(\.kind) == [.option, .option, .option, .other, .submit, .chat])
        #expect(read.rows.map(\.isChecked) == [true, false, true, false, false, false])
        #expect(read.rows.prefix(3).map(\.label) == ["제목", "본문", "태그"])
        #expect(read.focusedIndex == 2)
        #expect(try dialog("choice-multiselect-submit-row.txt").focusedIndex == 4)
    }

    @Test func reviewScreenIsRead() throws {
        #expect(ClaudeScreen.interpret(try screenFixture("choice-review.txt")) == .review(focusedOnSubmit: true))
    }

    @Test func emptyPromptIsEmptyDraft() throws {
        #expect(ClaudeScreen.interpret(try screenFixture("prompt-empty.txt")) == .prompt(draft: ""))
        #expect(ClaudeScreen.interpret(try screenFixture("prompt-empty.ansi")) == .prompt(draft: ""))
    }

    @Test func faintSuggestionAndPlaceholderAreEmpty() throws {
        #expect(ClaudeScreen.interpret(try screenFixture("prompt-suggestion.ansi")) == .prompt(draft: ""))
        #expect(ClaudeScreen.interpret(try screenFixture("prompt-placeholder.ansi")) == .prompt(draft: ""))
    }

    @Test func suggestionWithoutStyleCountsAsDraft() throws {
        #expect(ClaudeScreen.interpret(try screenFixture("prompt-suggestion.txt")) == .prompt(draft: "계속 진행"))
    }

    @Test func promptDraftIsRead() throws {
        #expect(ClaudeScreen.interpret(try screenFixture("prompt-draft.txt")) == .prompt(draft: "쓰다 만 글"))
        #expect(ClaudeScreen.interpret(try screenFixture("prompt-draft.ansi")) == .prompt(draft: "쓰다 만 글"))
        #expect(ClaudeScreen.interpret(try screenFixture("prompt-draft-then-suggestion.ansi")) == .prompt(draft: "계속"))
    }

    @Test func busyScreenShowsEmptyPrompt() throws {
        #expect(ClaudeScreen.interpret(try screenFixture("prompt-busy.txt")) == .prompt(draft: ""))
    }

    @Test func unknownTextIsUnrecognized() {
        #expect(ClaudeScreen.interpret(ConsoleScreen(lines: ["hello"], faint: nil, composerDraft: nil)) == .unrecognized)
    }

    @Test func numberedListInConversationIsNotADialog() {
        let lines = ["⏺ 할 일:", "  1. 첫째", "  2. 둘째", "", String(repeating: "─", count: 40), "❯\u{a0}", String(repeating: "─", count: 40)]
        #expect(ClaudeScreen.interpret(ConsoleScreen(lines: lines, faint: nil, composerDraft: nil)) == .prompt(draft: ""))
    }

    @Test func wrappedQuestionIsRecognized() throws {
        let read = try dialog("choice-wrapped.txt")
        let question = ChoiceQuestion(
            text: "동기화가 세 번 실패하면 사용자에게 어떤 안내를 보여 주고 다음 재시도까지 얼마나 기다릴까요?",
            header: "재시도",
            multiSelect: false,
            options: [
                ChoiceOption(label: "1분 뒤 다시", description: nil, hasPreview: false),
                ChoiceOption(label: "수동으로만", description: nil, hasPreview: false),
            ]
        )
        #expect(ClaudeScreen.matches(read, question: question))
    }

    @Test func differentLabelsDoNotMatch() throws {
        var options = expiryQuestion.options
        options[1] = ChoiceOption(label: "고정 5분 유지", description: nil, hasPreview: false)
        let other = ChoiceQuestion(text: expiryQuestion.text, header: nil, multiSelect: false, options: options)
        let read = try dialog("choice-single-focus0.txt")
        #expect(ClaudeScreen.matches(read, question: expiryQuestion))
        #expect(!ClaudeScreen.matches(read, question: other))
    }

    @Test func differentQuestionDoesNotMatch() throws {
        let other = ChoiceQuestion(text: "색인을 얼마나 자주 다시 만들까요?", header: nil, multiSelect: false, options: expiryQuestion.options)
        #expect(!ClaudeScreen.matches(try dialog("choice-single-focus0.txt"), question: other))
    }

    // MARK: 흐림 읽기

    @Test func faintRangesAreTracked() {
        let screen = ConsoleScreen.ansi("a\u{1b}[2mbc\u{1b}[0md\n\u{1b}[2mx\u{1b}[22my")
        #expect(screen.lines == ["abcd", "xy"])
        #expect(screen.faint == [[1, 2], [0]])
    }

    @Test func colorParametersAreNotFaint() {
        let screen = ConsoleScreen.ansi("\u{1b}[38;2;2;2;2ma\u{1b}[38;5;2mb\u{1b}[48;5;237;2mc")
        #expect(screen.lines == ["abc"])
        #expect(screen.faint == [[2]])
    }

    @Test func faintCarriesAcrossLinesUntilReset() {
        let screen = ConsoleScreen.ansi("\u{1b}[2mab\ncd\u{1b}[mef")
        #expect(screen.faint == [[0, 1], [0, 1]])
    }
}
