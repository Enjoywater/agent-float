import Foundation

/// 질문 하나에 대한 답. 번호는 질문의 선택지 순서(0부터)
public enum ChoiceAnswer: Equatable, Sendable {
    case option(Int)
    case options(Set<Int>)
    case other(String)
}

public enum ReplyDraft: Equatable, Sendable {
    case choices([ChoiceAnswer])
    case text(String)
}

public struct ReplyProgress: Equatable, Sendable {
    /// 마지막으로 화면에서 본 질문 번호
    public var question: Int
    /// 지금 질문의 칸(또는 프롬프트)에 글을 이미 입력했는지. 같은 글을 두 번 넣지 않기 위함
    public var typedText: Bool
    /// 답 전체를 제출하는 Enter 를 눌렀는지. 이 뒤에 질문 창이 사라져야 정상적으로 끝난 것이다
    public var pressedSubmit: Bool

    public init(question: Int = 0, typedText: Bool = false, pressedSubmit: Bool = false) {
        self.question = question
        self.typedText = typedText
        self.pressedSubmit = pressedSubmit
    }
}

public enum ReplyMove: Equatable, Sendable {
    case send(ConsoleInput)
    case finished
    case stuck(String)
}

public enum StartCheck: Equatable, Sendable {
    case ready, terminalDraft, unexpected
}

/// 화면을 읽고 다음 키 하나만 정한다. 키 순서를 미리 정해 두면 화면이 예상과 달라진 순간에도 남은 키를 계속 보내게 된다
public enum ReplyDriver {
    /// G2. 첫 질문이 그대로 떠 있고 사용자가 터미널에서 손대지 않았을 때만 시작한다
    public static func startCheck(prompt: PendingPrompt, screen: ScreenState) -> StartCheck {
        switch prompt {
        case let .choices(_, questions):
            guard let first = questions.first, case let .choiceDialog(dialog) = screen,
                  ClaudeScreen.matches(dialog, question: first) else { return .unexpected }
            if !dialog.otherDraft.isEmpty || dialog.rows.contains(where: \.isChecked) { return .terminalDraft }
            return dialog.focusedIndex == nil ? .unexpected : .ready
        case .text:
            guard case let .prompt(draft) = screen else { return .unexpected }
            return draft.isEmpty ? .ready : .terminalDraft
        case .permission:
            return .unexpected
        }
    }

    /// G3 한 걸음
    public static func nextMove(prompt: PendingPrompt, draft: ReplyDraft, progress: inout ReplyProgress, screen: ScreenState) -> ReplyMove {
        switch (prompt, draft) {
        case let (.choices(_, questions), .choices(answers)) where questions.count == answers.count && !questions.isEmpty:
            return choiceMove(questions: questions, answers: answers, progress: &progress, screen: screen)
        case let (.text, .text(reply)):
            return textMove(reply: reply, progress: &progress, screen: screen)
        default:
            return .stuck("답의 종류가 질문과 맞지 않음")
        }
    }

    /// G4 에서 transcript 에 있어야 할 답. 여러 개 고르기는 선택지 순서대로 ", " 로 이어 기록된다 (실측 ⑦)
    public static func expectedRecord(prompt: PendingPrompt, draft: ReplyDraft) -> RecordedAnswer? {
        switch (prompt, draft) {
        case let (.choices(_, questions), .choices(answers)) where questions.count == answers.count:
            var record: [String: String] = [:]
            for (question, answer) in zip(questions, answers) {
                switch answer {
                case let .option(index):
                    guard question.options.indices.contains(index) else { return nil }
                    record[question.text] = question.options[index].label
                case let .options(indices):
                    guard !indices.isEmpty, indices.allSatisfy(question.options.indices.contains) else { return nil }
                    record[question.text] = indices.sorted().map { question.options[$0].label }.joined(separator: ", ")
                case let .other(text):
                    record[question.text] = text
                }
            }
            return .choices(record)
        case let (.text, .text(reply)):
            return .text(reply)
        default:
            return nil
        }
    }

    /// 보낸 입력 하나가 만들어야 할 변화만 일어났는지. 그 밖의 변화는 사용자가 터미널에서 함께 손댄 것으로 보고 멈춘다 (Review Focus 1)
    public static func isExpected(after input: ConsoleInput, from old: ScreenState, to new: ScreenState) -> Bool {
        switch old {
        case let .choiceDialog(before):
            return dialogTransition(after: input, from: before, to: new)
        case .review:
            guard input == .key(.enter), case .prompt = new else { return false }
            return true
        case let .prompt(draft):
            guard case let .prompt(after) = new else { return false }
            switch input {
            case let .text(text):
                return ClaudeScreen.sameText(after, draft + text)
            case .key(.enter):
                return after.isEmpty
            case .key:
                return false
            }
        case .unrecognized:
            return false
        }
    }

    /// 붙여 넣은 글이 아직 다 그려지지 않은 중간 화면. 이것을 결과로 보면 멀쩡한 입력을 멈추게 된다
    public static func isPartial(after input: ConsoleInput, state: ScreenState) -> Bool {
        guard case let .text(text) = input else { return false }
        let shown: String
        switch state {
        case let .choiceDialog(dialog): shown = dialog.otherDraft
        case let .prompt(draft): shown = draft
        case .review, .unrecognized: return false
        }
        let typed = text.filter { !$0.isWhitespace }
        let visible = shown.filter { !$0.isWhitespace }
        return !visible.isEmpty && visible.count < typed.count && typed.hasPrefix(visible)
    }

    private static func dialogTransition(after input: ConsoleInput, from before: ChoiceDialog, to new: ScreenState) -> Bool {
        if input == .key(.enter) {
            // 고르기·제출 뒤에는 다음 질문, 확인 화면, 또는 질문 창이 닫힌 프롬프트만 나와야 한다
            switch new {
            case let .choiceDialog(after): return !sameQuestion(before, after)
            case .review, .prompt: return true
            case .unrecognized: return false
            }
        }
        guard case let .choiceDialog(after) = new, sameQuestion(before, after),
              let from = before.focusedIndex, let to = after.focusedIndex else { return false }
        let checksBefore = before.rows.map(\.isChecked)
        let checksAfter = after.rows.map(\.isChecked)
        switch input {
        case .key(.down), .key(.up):
            let delta = input == .key(.down) ? 1 : -1
            return to == from + delta && checksBefore == checksAfter && before.otherDraft == after.otherDraft
        case .key(.space):
            let flipped = zip(checksBefore, checksAfter).enumerated().filter { $1.0 != $1.1 }.map(\.offset)
            return to == from && flipped == [from] && before.otherDraft == after.otherDraft
        case let .text(text):
            return to == from && checksBefore == checksAfter && before.otherDraft.isEmpty
                && ClaudeScreen.sameText(after.otherDraft, text)
        case .key:
            return false
        }
    }

    private static func sameQuestion(_ lhs: ChoiceDialog, _ rhs: ChoiceDialog) -> Bool {
        ClaudeScreen.normalized(lhs.questionText) == ClaudeScreen.normalized(rhs.questionText)
            && lhs.rows.filter { $0.kind == .option }.map(\.label) == rhs.rows.filter { $0.kind == .option }.map(\.label)
    }

    // MARK: 질문 창

    private static func choiceMove(
        questions: [ChoiceQuestion], answers: [ChoiceAnswer], progress: inout ReplyProgress, screen: ScreenState
    ) -> ReplyMove {
        switch screen {
        case let .review(focusedOnSubmit):
            guard focusedOnSubmit else { return .stuck("확인 화면의 포커스가 Submit 이 아님") }
            guard progress.question == questions.count - 1 else { return .stuck("마지막 질문 전에 확인 화면이 나옴") }
            guard !progress.pressedSubmit else { return .stuck("Submit 뒤에도 확인 화면이 남아 있음") }
            progress.pressedSubmit = true
            return .send(.key(.enter))
        case .prompt:
            return progress.pressedSubmit ? .finished : .stuck("보내기 전에 질문 창이 사라짐")
        case .unrecognized:
            return .stuck("알 수 없는 화면")
        case let .choiceDialog(dialog):
            return dialogMove(dialog, questions: questions, answers: answers, progress: &progress)
        }
    }

    private static func dialogMove(
        _ dialog: ChoiceDialog, questions: [ChoiceQuestion], answers: [ChoiceAnswer], progress: inout ReplyProgress
    ) -> ReplyMove {
        guard let index = questions.firstIndex(where: { ClaudeScreen.matches(dialog, question: $0) }) else {
            return .stuck("다른 질문 창이 떠 있음")
        }
        guard index >= progress.question else { return .stuck("앞 질문으로 돌아감") }
        if index != progress.question {
            progress.question = index
            progress.typedText = false
        }
        guard let focus = dialog.focusedIndex else { return .stuck("포커스를 찾을 수 없음") }
        let question = questions[index]
        // 질문 하나짜리 하나 고르기는 고르는 Enter 가 곧 제출이다. 그 밖에는 확인 화면의 Submit 이 제출이다 (실측 ⑥)
        let submitsNow = questions.count == 1 && !question.multiSelect
        let optionRows = dialog.rows.indices.filter { dialog.rows[$0].kind == .option }

        switch answers[index] {
        case let .option(choice):
            guard !question.multiSelect, optionRows.indices.contains(choice) else { return .stuck("고를 수 없는 선택지") }
            let target = optionRows[choice]
            if focus != target { return step(from: focus, to: target) }
            if submitsNow { progress.pressedSubmit = true }
            return .send(.key(.enter))
        case let .other(text):
            guard !question.multiSelect else { return .stuck("여러 개 고르기의 직접 입력은 보내지 않음") }
            guard isTypable(text) else { return .stuck("입력할 수 없는 글자가 있음") }
            guard let target = dialog.rows.firstIndex(where: { $0.kind == .other }) else { return .stuck("직접 쓰기 칸이 없음") }
            if focus != target { return step(from: focus, to: target) }
            if dialog.otherDraft.isEmpty {
                guard !progress.typedText else { return .stuck("입력한 글이 칸에 보이지 않음") }
                progress.typedText = true
                return .send(.text(text))
            }
            guard progress.typedText, ClaudeScreen.sameText(dialog.otherDraft, text) else { return .stuck("칸에 다른 글이 있음") }
            if submitsNow { progress.pressedSubmit = true }
            return .send(.key(.enter))
        case let .options(chosen):
            guard question.multiSelect, chosen.allSatisfy(optionRows.indices.contains) else { return .stuck("고를 수 없는 선택지") }
            guard dialog.otherDraft.isEmpty, dialog.rows.allSatisfy({ $0.kind != .other || !$0.isChecked }) else {
                return .stuck("직접 쓰기 칸이 비어 있지 않음")
            }
            for (choice, row) in optionRows.enumerated() where dialog.rows[row].isChecked != chosen.contains(choice) {
                if focus != row { return step(from: focus, to: row) }
                // Enter 도 켜고 끄지만 직접 쓰기 줄에서는 뜻이 달라질 수 있어 Space 로 고정한다 (R60)
                return .send(.key(.space))
            }
            guard let submit = dialog.rows.firstIndex(where: { $0.kind == .submit }) else { return .stuck("Submit 줄이 없음") }
            if focus != submit { return step(from: focus, to: submit) }
            return .send(.key(.enter))
        }
    }

    private static func step(from focus: Int, to target: Int) -> ReplyMove {
        .send(.key(target > focus ? .down : .up))
    }

    // MARK: 본문 질문

    private static func textMove(reply: String, progress: inout ReplyProgress, screen: ScreenState) -> ReplyMove {
        guard isTypable(reply) else { return .stuck("입력할 수 없는 글자가 있음") }
        guard case let .prompt(current) = screen else { return .stuck("프롬프트가 보이지 않음") }
        if current.isEmpty {
            if progress.pressedSubmit { return .finished }
            guard !progress.typedText else { return .stuck("입력한 글이 프롬프트에 보이지 않음") }
            progress.typedText = true
            return .send(.text(reply))
        }
        guard progress.typedText, ClaudeScreen.sameText(current, reply) else { return .stuck("프롬프트에 다른 글이 있음") }
        guard !progress.pressedSubmit else { return .stuck("Enter 뒤에도 글이 남아 있음") }
        progress.pressedSubmit = true
        return .send(.key(.enter))
    }

    /// 제어 문자는 키로 해석되어(줄바꿈은 Enter, ESC 는 취소) 글과 다른 동작을 일으킨다
    static func isTypable(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
            && !text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}
