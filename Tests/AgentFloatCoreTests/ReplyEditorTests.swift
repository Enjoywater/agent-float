import Foundation
import Testing
@testable import AgentFloatCore

@Suite struct ReplyEditorTests {
    private static let options = ["읽은 때부터 다시 세기 (Recommended)", "고정 10분 유지", "둘 다 지원"]
        .map { ChoiceOption(label: $0, description: nil, hasPreview: false) }
    private static let single = PendingPrompt.choices(id: "toolu_01", questions: [
        ChoiceQuestion(text: "캐시 만료 방식을 어떻게 할까요?", header: "만료 방식", multiSelect: false, options: options),
    ])
    private static let multi = PendingPrompt.choices(id: "toolu_02", questions: [
        ChoiceQuestion(text: "색인에 넣을 필드를 고르세요", header: "색인 필드", multiSelect: true, options: options),
    ])
    private static let two = PendingPrompt.choices(id: "toolu_03", questions: [
        ChoiceQuestion(text: "어느 쪽을 먼저 배포할까요?", header: "배포 순서", multiSelect: false, options: options),
        ChoiceQuestion(text: "색인을 얼마나 자주 다시 만들까요?", header: "색인 주기", multiSelect: false, options: options),
    ])
    private static let body = PendingPrompt.text(id: "a-2", message: "다음 작업을 진행할까요?")

    // MARK: 질문 창

    @Test func singleQuestionSendsWhenChosen() {
        var editor = ReplyEditor(prompt: Self.single)
        editor.choose(option: 1)
        #expect(editor.primary == .send)
        #expect(editor.draft == .choices([.option(1)]))
    }

    @Test func nothingChosenIsDisabled() {
        let editor = ReplyEditor(prompt: Self.single)
        #expect(editor.primary == .disabled)
        #expect(editor.draft == nil)
    }

    @Test func otherTextReplacesChoice() {
        var editor = ReplyEditor(prompt: Self.single)
        editor.choose(option: 0)
        editor.setOther("잠시 대기")
        #expect(editor.answers[0] == .other("잠시 대기"))
        #expect(editor.draft == .choices([.other("잠시 대기")]))
    }

    @Test func choosingClearsOtherText() {
        var editor = ReplyEditor(prompt: Self.single)
        editor.setOther("x")
        editor.choose(option: 2)
        #expect(editor.otherText == "")
        #expect(editor.answers[0] == .option(2))
    }

    @Test func clearingOtherTextClearsTheAnswer() {
        var editor = ReplyEditor(prompt: Self.single)
        editor.setOther("x")
        editor.setOther("")
        #expect(editor.answers[0] == nil)
        #expect(editor.primary == .disabled)
    }

    @Test func multiSelectToggles() {
        var editor = ReplyEditor(prompt: Self.multi)
        editor.choose(option: 0)
        editor.choose(option: 2)
        editor.choose(option: 0)
        #expect(editor.answers[0] == .options([2]))
        editor.choose(option: 2)
        #expect(editor.answers[0] == nil)
    }

    @Test func multiSelectIgnoresOtherText() {
        var editor = ReplyEditor(prompt: Self.multi)
        editor.setOther("작성자")
        #expect(editor.otherText == "")
        #expect(editor.answers[0] == nil)
        #expect(!editor.acceptsOtherText)
    }

    @Test func multiSelectGoesThroughReview() {
        var editor = ReplyEditor(prompt: Self.multi)
        editor.choose(option: 1)
        #expect(editor.primary == .send)
        #expect(editor.draft == .choices([.options([1])]))
    }

    @Test func twoQuestionsGoThroughReview() {
        var editor = ReplyEditor(prompt: Self.two)
        editor.choose(option: 0)
        #expect(editor.primary == .next)
        #expect(editor.draft == nil)
        editor.advance()
        #expect(editor.step == 1)
        #expect(editor.primary == .disabled)
        editor.setOther("매일 새벽 한 번이면 충분해")
        #expect(editor.primary == .next)
        editor.advance()
        #expect(editor.isReviewing)
        #expect(editor.primary == .send)
        #expect(editor.draft == .choices([.option(0), .other("매일 새벽 한 번이면 충분해")]))
    }

    @Test func editFromReviewReturnsToQuestion() {
        var editor = ReplyEditor(prompt: Self.two)
        editor.choose(option: 0)
        editor.advance()
        editor.choose(option: 1)
        editor.advance()
        editor.edit(question: 0)
        #expect(editor.step == 0)
        #expect(editor.answers == [.option(0), .option(1)])
        editor.choose(option: 2)
        editor.advance()
        #expect(editor.isReviewing)
        #expect(editor.draft == .choices([.option(2), .option(1)]))
    }

    @Test func whitespaceOtherIsNotAnAnswer() {
        var editor = ReplyEditor(prompt: Self.single)
        editor.setOther("   ")
        #expect(editor.primary == .disabled)
    }

    @Test func permissionIsNeverSendable() {
        let editor = ReplyEditor(prompt: .permission(id: "toolu_09", tool: "Bash", summary: "swift test"))
        #expect(editor.primary == .disabled)
        #expect(editor.draft == nil)
    }

    // MARK: 본문 질문과 글 검사

    @Test func bodyReplySends() {
        var editor = ReplyEditor(prompt: Self.body)
        editor.setReply("응, 진행해 줘")
        #expect(editor.primary == .send)
        #expect(editor.draft == .text("응, 진행해 줘"))
    }

    /// 앞뒤 공백은 보낼 글에서 뺀다. Claude Code 가 공백을 다듬어 기록하면 보낸 글과 달라 보여 실패로 표시된다 (최종 리뷰 M1)
    @Test func surroundingWhitespaceIsTrimmedFromTheDraft() {
        var body = ReplyEditor(prompt: Self.body)
        body.setReply("  응, 진행해 줘 ")
        #expect(body.draft == .text("응, 진행해 줘"))
        var dialog = ReplyEditor(prompt: Self.single)
        dialog.setOther(" 잠시 대기  ")
        #expect(dialog.draft == .choices([.other("잠시 대기")]))
    }

    @Test func commandLikeTextIsBlocked() {
        var editor = ReplyEditor(prompt: Self.body)
        for text in ["/compact", "  !ls", "#메모"] {
            editor.setReply(text)
            #expect(editor.block == .commandLike)
            #expect(editor.primary == .disabled)
        }
        editor.setReply("응, 진행해 줘")
        #expect(editor.block == nil)
    }

    /// Claude Code 는 800자를 넘게 붙여 넣으면 `[Pasted text #N]` 으로 접어, 화면에서 넣은 글을 확인할 수 없다 (실측 S6 ⑧)
    @Test func textOverPasteFoldLimitIsBlocked() {
        #expect(ReplyText.block(String(repeating: "a", count: 800), inPrompt: true) == nil)
        #expect(ReplyText.block(String(repeating: "a", count: 801), inPrompt: true) == .tooLong)
        #expect(ReplyText.block(String(repeating: "가", count: 801), inPrompt: false) == .tooLong)
        #expect(ReplyText.block("  " + String(repeating: "a", count: 800) + "  ", inPrompt: true) == nil)
        var editor = ReplyEditor(prompt: Self.body)
        editor.setReply(String(repeating: "a", count: 801))
        #expect(editor.block == .tooLong)
        #expect(editor.primary == .disabled)
    }

    @Test func mentionIsBlockedOnlyInPrompt() {
        #expect(ReplyText.block("Package.swift @Sources 확인", inPrompt: true) == .mention)
        #expect(ReplyText.block("확인 @Pack /he", inPrompt: false) == nil)
        #expect(ReplyText.block("/로 시작해도 칸에서는 됨", inPrompt: false) == nil)
    }

    @Test func multilineAndControlAreBlocked() {
        #expect(ReplyText.block("a\nb", inPrompt: true) == .multiline)
        #expect(ReplyText.block("a\nb", inPrompt: false) == .multiline)
        #expect(ReplyText.block("a\u{1b}b", inPrompt: false) == .controlCharacter)
        var editor = ReplyEditor(prompt: Self.single)
        editor.setOther("a\nb")
        #expect(editor.block == .multiline)
        #expect(editor.primary == .disabled)
    }

    // MARK: 키

    @Test func returnDuringCompositionOnlyCommits() {
        #expect(ReplyKeys.action(for: .returnKey, fieldFocused: true, hasMarkedText: true) == .commitComposition)
    }

    @Test func returnSends() {
        #expect(ReplyKeys.action(for: .returnKey, fieldFocused: true, hasMarkedText: false) == .primary)
        #expect(ReplyKeys.action(for: .returnKey, fieldFocused: false, hasMarkedText: false) == .primary)
    }

    @Test func digitsSelectOnlyOutsideField() {
        #expect(ReplyKeys.action(for: .digit(2), fieldFocused: false, hasMarkedText: false) == .select(1))
        #expect(ReplyKeys.action(for: .digit(2), fieldFocused: true, hasMarkedText: false) == .passThrough)
        #expect(ReplyKeys.action(for: .digit(0), fieldFocused: false, hasMarkedText: false) == .passThrough)
    }

    @Test func escapeLeavesFieldThenGoesBack() {
        #expect(ReplyKeys.action(for: .escape, fieldFocused: true, hasMarkedText: false) == .leaveField)
        #expect(ReplyKeys.action(for: .escape, fieldFocused: false, hasMarkedText: false) == .back)
        #expect(ReplyKeys.action(for: .escape, fieldFocused: true, hasMarkedText: true) == .passThrough)
    }

    // MARK: 배치 설정

    @Test func placementDefaultsToPanel() {
        #expect(ReplyPlacement.resolve(override: nil, saved: nil) == .panel)
        #expect(ReplyPlacement.resolve(override: "inline", saved: "card") == .inline)
        #expect(ReplyPlacement.resolve(override: nil, saved: "card") == .card)
        #expect(ReplyPlacement.resolve(override: "bogus", saved: nil) == .panel)
    }
}
