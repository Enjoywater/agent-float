import Foundation
import Testing
@testable import AgentFloatCore

@Suite struct ReplyDriverTests {
    private static let single = PendingPrompt.choices(id: "toolu_01", questions: [expiryQuestion])
    private static let fieldsQuestion = ChoiceQuestion(
        text: "색인에 넣을 필드를 고르세요",
        header: "색인 필드",
        multiSelect: true,
        options: ["제목", "본문", "태그"].map { ChoiceOption(label: $0, description: nil, hasPreview: false) }
    )
    private static let deployQuestion = ChoiceQuestion(
        text: "어느 쪽을 먼저 배포할까요?",
        header: "배포 순서",
        multiSelect: false,
        options: ["서버 먼저", "동시에"].map { ChoiceOption(label: $0, description: nil, hasPreview: false) }
    )
    private static let cadenceQuestion = ChoiceQuestion(
        text: "색인을 얼마나 자주 다시 만들까요?",
        header: "색인 주기",
        multiSelect: false,
        options: ["매일", "매주"].map { ChoiceOption(label: $0, description: nil, hasPreview: false) }
    )
    private static let twoQuestions = PendingPrompt.choices(id: "toolu_02", questions: [deployQuestion, cadenceQuestion])
    private static let body = PendingPrompt.text(id: "a-2", message: "다음 작업을 진행할까요?")

    private static func yesNo(_ text: String) -> ChoiceQuestion {
        ChoiceQuestion(text: text, header: "확인", multiSelect: false, options: ["예", "아니오"].map {
            ChoiceOption(label: $0, description: nil, hasPreview: false)
        })
    }

    private static func dialog(_ question: ChoiceQuestion, focus: Int) -> ScreenState {
        var rows = question.options.enumerated().map { index, option in
            ChoiceRow(label: option.label, isFocused: index == focus, isChecked: false, kind: .option)
        }
        rows.append(ChoiceRow(label: "Type something.", isFocused: focus == rows.count, isChecked: false, kind: .other))
        return .choiceDialog(ChoiceDialog(questionText: question.text, rows: rows, otherDraft: ""))
    }

    private func state(_ name: String) throws -> ScreenState {
        ClaudeScreen.interpret(try screenFixture(name))
    }

    private func move(
        _ prompt: PendingPrompt, _ draft: ReplyDraft, _ progress: inout ReplyProgress, _ screen: ScreenState
    ) -> ReplyMove {
        ReplyDriver.nextMove(prompt: prompt, draft: draft, progress: &progress, screen: screen)
    }

    /// 화면 하나를 포커스만 바꿔 다시 쓰기 위한 도우미
    private func focused(_ screen: ScreenState, at index: Int) -> ScreenState {
        guard case let .choiceDialog(dialog) = screen else { return screen }
        let rows = dialog.rows.enumerated().map { offset, row in
            ChoiceRow(label: row.label, isFocused: offset == index, isChecked: row.isChecked, kind: row.kind)
        }
        return .choiceDialog(ChoiceDialog(questionText: dialog.questionText, rows: rows, otherDraft: dialog.otherDraft))
    }

    // MARK: 시작 확인 (G2)

    @Test func startRequiresFirstQuestionAndEmptyFields() throws {
        #expect(ReplyDriver.startCheck(prompt: Self.single, screen: try state("choice-single-focus0.txt")) == .ready)
        #expect(ReplyDriver.startCheck(prompt: Self.single, screen: try state("choice-other-typed.txt")) == .terminalDraft)
        #expect(ReplyDriver.startCheck(prompt: Self.single, screen: try state("choice-other-typed-unfocused.txt")) == .terminalDraft)
        #expect(ReplyDriver.startCheck(prompt: Self.body, screen: try state("prompt-draft.txt")) == .terminalDraft)
        #expect(ReplyDriver.startCheck(prompt: Self.body, screen: try state("prompt-suggestion.ansi")) == .ready)
        #expect(ReplyDriver.startCheck(prompt: Self.twoQuestions, screen: try state("choice-two-questions-q2.txt")) == .unexpected)
        #expect(ReplyDriver.startCheck(prompt: Self.twoQuestions, screen: try state("choice-two-questions-q1.txt")) == .ready)
        #expect(ReplyDriver.startCheck(prompt: Self.single, screen: try state("prompt-empty.txt")) == .unexpected)
        #expect(ReplyDriver.startCheck(prompt: Self.body, screen: try state("choice-single-focus0.txt")) == .unexpected)
    }

    @Test func startRejectsBoxesTickedInTerminal() throws {
        let prompt = PendingPrompt.choices(id: "toolu_03", questions: [Self.fieldsQuestion])
        #expect(ReplyDriver.startCheck(prompt: prompt, screen: try state("choice-multiselect-checked.txt")) == .terminalDraft)
    }

    @Test func permissionIsNeverStarted() throws {
        let prompt = PendingPrompt.permission(id: "toolu_09", tool: "Bash", summary: "swift test")
        #expect(ReplyDriver.startCheck(prompt: prompt, screen: try state("prompt-empty.txt")) == .unexpected)
    }

    // MARK: 하나 고르기

    @Test func movesFocusThenSelects() throws {
        var progress = ReplyProgress()
        let start = try state("choice-single-focus0.txt")
        #expect(move(Self.single, .choices([.option(2)]), &progress, start) == .send(.key(.down)))
        #expect(move(Self.single, .choices([.option(2)]), &progress, focused(start, at: 2)) == .send(.key(.enter)))
        #expect(progress.pressedSubmit)
    }

    @Test func movesUpWhenTargetIsAbove() throws {
        var progress = ReplyProgress()
        let start = try state("choice-single-focus0.txt")
        #expect(move(Self.single, .choices([.option(0)]), &progress, focused(start, at: 2)) == .send(.key(.up)))
    }

    @Test func otherAnswerTypesOnceThenConfirms() throws {
        var progress = ReplyProgress()
        let draft = ReplyDraft.choices([.other("잠시 대기")])
        #expect(move(Self.single, draft, &progress, try state("choice-single-focus0.txt")) == .send(.key(.down)))
        #expect(move(Self.single, draft, &progress, try state("choice-other-focused-empty.txt")) == .send(.text("잠시 대기")))
        #expect(progress.typedText)
        #expect(move(Self.single, draft, &progress, try state("choice-other-typed.txt")) == .send(.key(.enter)))
        #expect(progress.pressedSubmit)
    }

    @Test func otherFieldWithForeignTextIsStuck() throws {
        var progress = ReplyProgress()
        guard case let .choiceDialog(typed) = try state("choice-other-typed.txt") else { throw CancellationError() }
        let foreign = ChoiceDialog(questionText: typed.questionText, rows: typed.rows.map {
            $0.kind == .other ? ChoiceRow(label: "다른 글", isFocused: true, isChecked: false, kind: .other) : $0
        }, otherDraft: "다른 글")
        guard case .stuck = move(Self.single, .choices([.other("잠시 대기")]), &progress, .choiceDialog(foreign)) else {
            Issue.record("남의 글이 든 칸에 이어 쓰면 안 됨")
            return
        }
    }

    @Test func emptiedFieldAfterTypingIsStuck() throws {
        var progress = ReplyProgress(question: 0, typedText: true, pressedSubmit: false)
        guard case .stuck = move(Self.single, .choices([.other("잠시 대기")]), &progress, try state("choice-other-focused-empty.txt")) else {
            Issue.record("보낸 글이 칸에 없으면 멈춰야 함")
            return
        }
    }

    @Test func tenthOptionIsReachable() throws {
        let options = (1...10).map { ChoiceOption(label: "선택지 \($0)", description: nil, hasPreview: false) }
        let question = ChoiceQuestion(text: "열 개 중 고르세요", header: nil, multiSelect: false, options: options)
        let prompt = PendingPrompt.choices(id: "toolu_10", questions: [question])
        var progress = ReplyProgress()
        for index in 0..<9 {
            let rows = options.enumerated().map { ChoiceRow(label: $1.label, isFocused: $0 == index, isChecked: false, kind: .option) }
                + [ChoiceRow(label: "Type something.", isFocused: false, isChecked: false, kind: .other)]
            let screen = ScreenState.choiceDialog(ChoiceDialog(questionText: "열 개 중 고르세요", rows: rows, otherDraft: ""))
            #expect(move(prompt, .choices([.option(9)]), &progress, screen) == .send(.key(.down)))
        }
    }

    // MARK: 여러 개 고르기

    @Test func multiSelectTogglesOnlyDifference() throws {
        let prompt = PendingPrompt.choices(id: "toolu_03", questions: [Self.fieldsQuestion])
        var progress = ReplyProgress()
        let draft = ReplyDraft.choices([.options([0, 2])])
        guard case let .choiceDialog(checked) = try state("choice-multiselect-checked.txt") else { throw CancellationError() }
        let rows = checked.rows.enumerated().map { offset, row in
            ChoiceRow(label: row.label, isFocused: offset == 0, isChecked: offset == 0, kind: row.kind)
        }
        let onlyFirst = ScreenState.choiceDialog(ChoiceDialog(questionText: checked.questionText, rows: rows, otherDraft: ""))
        #expect(move(prompt, draft, &progress, onlyFirst) == .send(.key(.down)))
        #expect(move(prompt, draft, &progress, focused(onlyFirst, at: 2)) == .send(.key(.space)))
        #expect(move(prompt, draft, &progress, .choiceDialog(checked)) == .send(.key(.down)))
        #expect(move(prompt, draft, &progress, try state("choice-multiselect-submit-row.txt")) == .send(.key(.enter)))
        #expect(!progress.pressedSubmit)
        #expect(move(prompt, draft, &progress, try state("choice-review.txt")) == .send(.key(.enter)))
        #expect(progress.pressedSubmit)
    }

    @Test func otherTextInMultiSelectIsNotSupported() throws {
        let prompt = PendingPrompt.choices(id: "toolu_03", questions: [Self.fieldsQuestion])
        var progress = ReplyProgress()
        guard case .stuck = move(prompt, .choices([.other("작성자")]), &progress, try state("choice-multiselect-checked.txt")) else {
            Issue.record("여러 개 고르기의 직접 입력은 보내지 않음")
            return
        }
    }

    // MARK: 질문 여러 개

    @Test func secondQuestionFollowsFirst() throws {
        var progress = ReplyProgress()
        let draft = ReplyDraft.choices([.option(0), .option(1)])
        #expect(move(Self.twoQuestions, draft, &progress, try state("choice-two-questions-q1.txt")) == .send(.key(.enter)))
        #expect(!progress.pressedSubmit)
        #expect(move(Self.twoQuestions, draft, &progress, try state("choice-two-questions-q2.txt")) == .send(.key(.down)))
        #expect(progress.question == 1)
    }

    /// 앞 24자와 선택지가 같은 두 질문. 앞 질문에서 Enter 를 보낸 뒤 나온 화면은 다음 질문으로 봐야 한다 (최종 리뷰 I3)
    @Test func lookalikeSecondQuestionGetsItsOwnAnswer() {
        let first = Self.yesNo("다음 단계를 지금 그대로 진행해도 될까요? — 캐시 만료 쪽")
        let second = Self.yesNo("다음 단계를 지금 그대로 진행해도 될까요? — 검색 색인 쪽")
        let prompt = PendingPrompt.choices(id: "toolu_03", questions: [first, second])
        let draft = ReplyDraft.choices([.option(0), .option(1)])
        var progress = ReplyProgress()
        #expect(move(prompt, draft, &progress, Self.dialog(first, focus: 0)) == .send(.key(.enter)))
        #expect(move(prompt, draft, &progress, Self.dialog(second, focus: 0)) == .send(.key(.down)))
        #expect(progress.question == 1)
        #expect(move(prompt, draft, &progress, Self.dialog(second, focus: 1)) == .send(.key(.enter)))
    }

    /// 제출 Enter 뒤 Claude 가 곧바로 다음 질문 창을 띄우는 흐름. 키는 더 보내지 않고 기록(G4)으로 넘긴다 (최종 리뷰 I4)
    @Test func followUpDialogAfterSubmitHandsOverToRecord() throws {
        let followUp = Self.dialog(Self.yesNo("이어서 테스트도 돌릴까요?"), focus: 0)
        var progress = ReplyProgress(question: 0, typedText: false, pressedSubmit: true)
        #expect(move(Self.single, .choices([.option(0)]), &progress, followUp) == .finished)
        #expect(ReplyDriver.isExpected(after: .key(.enter), from: .review(focusedOnSubmit: true), to: followUp))
        #expect(!ReplyDriver.isExpected(after: .key(.down), from: .review(focusedOnSubmit: true), to: followUp))
    }

    @Test func reviewSubmits() throws {
        var progress = ReplyProgress(question: 1, typedText: false, pressedSubmit: false)
        #expect(move(Self.twoQuestions, .choices([.option(0), .option(1)]), &progress, .review(focusedOnSubmit: true)) == .send(.key(.enter)))
        #expect(progress.pressedSubmit)
    }

    @Test func reviewNotOnSubmitIsStuck() {
        var progress = ReplyProgress(question: 1, typedText: false, pressedSubmit: false)
        guard case .stuck = move(Self.twoQuestions, .choices([.option(0), .option(1)]), &progress, .review(focusedOnSubmit: false)) else {
            Issue.record("Cancel 에 포커스가 있으면 Enter 를 누르면 안 됨")
            return
        }
    }

    // MARK: 끝남과 막힘

    @Test func dialogGoneMeansFinished() throws {
        var progress = ReplyProgress(question: 0, typedText: false, pressedSubmit: true)
        #expect(move(Self.single, .choices([.option(1)]), &progress, try state("prompt-busy.txt")) == .finished)
    }

    @Test func dialogGoneBeforeSubmitIsStuck() throws {
        var progress = ReplyProgress()
        guard case .stuck = move(Self.single, .choices([.option(1)]), &progress, try state("prompt-busy.txt")) else {
            Issue.record("보내기 전에 창이 사라지면 멈춰야 함")
            return
        }
    }

    @Test func unrecognizedScreenIsStuck() {
        var progress = ReplyProgress()
        guard case .stuck = move(Self.single, .choices([.option(1)]), &progress, .unrecognized) else {
            Issue.record("모르는 화면에서는 멈춰야 함")
            return
        }
    }

    @Test func otherQuestionOnScreenIsStuck() throws {
        var progress = ReplyProgress()
        guard case .stuck = move(Self.single, .choices([.option(1)]), &progress, try state("choice-two-questions-q1.txt")) else {
            Issue.record("다른 질문 창이면 멈춰야 함")
            return
        }
    }

    // MARK: 본문 질문

    @Test func promptReplyTypesThenSubmits() throws {
        var progress = ReplyProgress()
        let draft = ReplyDraft.text("응, 진행해 줘")
        #expect(move(Self.body, draft, &progress, .prompt(draft: "")) == .send(.text("응, 진행해 줘")))
        #expect(move(Self.body, draft, &progress, .prompt(draft: "응, 진행해 줘")) == .send(.key(.enter)))
        #expect(move(Self.body, draft, &progress, .prompt(draft: "")) == .finished)
    }

    @Test func wrappedDraftStillCountsAsTyped() {
        var progress = ReplyProgress(question: 0, typedText: true, pressedSubmit: false)
        #expect(move(Self.body, .text("응, 그대로 진행해 줘"), &progress, .prompt(draft: "응, 그대로 진행해줘")) == .send(.key(.enter)))
    }

    @Test func foreignPromptTextIsStuck() {
        var progress = ReplyProgress(question: 0, typedText: true, pressedSubmit: false)
        guard case .stuck = move(Self.body, .text("응"), &progress, .prompt(draft: "쓰던 글응")) else {
            Issue.record("섞인 글은 보내면 안 됨")
            return
        }
    }

    // MARK: 기대 기록 (G4)

    @Test func expectedRecordForChoices() {
        #expect(ReplyDriver.expectedRecord(prompt: Self.single, draft: .choices([.option(0)]))
            == .choices(["캐시 만료 방식을 어떻게 할까요?": "읽은 때부터 다시 세기 (Recommended)"]))
        #expect(ReplyDriver.expectedRecord(prompt: Self.single, draft: .choices([.other("x")]))
            == .choices(["캐시 만료 방식을 어떻게 할까요?": "x"]))
        let fields = PendingPrompt.choices(id: "toolu_03", questions: [Self.fieldsQuestion])
        #expect(ReplyDriver.expectedRecord(prompt: fields, draft: .choices([.options([2, 0])]))
            == .choices(["색인에 넣을 필드를 고르세요": "제목, 태그"]))
        #expect(ReplyDriver.expectedRecord(prompt: Self.twoQuestions, draft: .choices([.option(0), .option(1)]))
            == .choices(["어느 쪽을 먼저 배포할까요?": "서버 먼저", "색인을 얼마나 자주 다시 만들까요?": "매주"]))
    }

    @Test func expectedRecordForText() {
        #expect(ReplyDriver.expectedRecord(prompt: Self.body, draft: .text("응")) == .text("응"))
        #expect(ReplyDriver.expectedRecord(prompt: Self.body, draft: .choices([.option(0)])) == nil)
        #expect(ReplyDriver.expectedRecord(prompt: Self.single, draft: .choices([.option(0), .option(1)])) == nil)
    }

    @Test func controlCharactersAreNeverTyped() throws {
        var progress = ReplyProgress()
        guard case .stuck = move(Self.body, .text("응\u{1b}[A"), &progress, .prompt(draft: "")) else {
            Issue.record("제어 문자가 든 글은 입력하지 않음")
            return
        }
        var other = ReplyProgress()
        guard case .stuck = move(Self.single, .choices([.other("a\nb")]), &other, try state("choice-other-focused-empty.txt")) else {
            Issue.record("줄바꿈이 든 글은 입력하지 않음")
            return
        }
    }
}
