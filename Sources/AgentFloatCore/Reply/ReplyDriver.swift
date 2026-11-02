import Foundation

/// One question's answer; option indices are zero-based.
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
    /// Last question index observed onscreen.
    public var question: Int
    /// Track typed input per question to prevent inserting the same text twice.
    public var typedText: Bool
    /// Whether final submission Enter was sent; successful completion requires the dialog to disappear afterward.
    public var pressedSubmit: Bool
    /// Track advancing Enter separately and look only at subsequent questions;
    /// otherwise identical prefixes/options could match the previous question and receive its answer again.
    public var pressedNext: Bool
    /// Remember pre-probe text; deletion must restore it exactly to prove user text was untouched.
    public var promptBefore: String?
    /// Whether the probe-deletion key has been sent.
    public var erasedProbe: Bool

    public init(
        question: Int = 0, typedText: Bool = false, pressedSubmit: Bool = false, pressedNext: Bool = false,
        promptBefore: String? = nil, erasedProbe: Bool = false
    ) {
        self.question = question
        self.typedText = typedText
        self.pressedSubmit = pressedSubmit
        self.pressedNext = pressedNext
        self.promptBefore = promptBefore
        self.erasedProbe = erasedProbe
    }
}

public enum ReplyMove: Equatable, Sendable {
    case send(ConsoleInput)
    case finished
    case stuck(String)
    /// Restore the initial composer after detecting existing text; do not send the reply.
    case restored
}

public enum StartCheck: Equatable, Sendable {
    case ready, terminalDraft, unexpected
}

/// Choose only one next key from the current screen; precomputed sequences would continue after unexpected changes.
public enum ReplyDriver {
    /// G2: Start only with the unchanged first question and no user edits in the terminal.
    public static func startCheck(prompt: PendingPrompt, screen: ScreenState, check: PromptCheck = .beforeTyping) -> StartCheck {
        switch prompt {
        case let .choices(_, questions):
            guard let first = questions.first, case let .choiceDialog(dialog) = screen,
                  ClaudeScreen.matches(dialog, question: first) else { return .unexpected }
            if !dialog.otherDraft.isEmpty || dialog.rows.contains(where: \.isChecked) { return .terminalDraft }
            return dialog.focusedIndex == nil ? .unexpected : .ready
        case .text:
            guard case let .prompt(draft) = screen else { return .unexpected }
            // Consoles exposing hints as text require a first-character probe before emptiness can be decided.
            if check == .afterTyping { return .ready }
            return draft.isEmpty ? .ready : .terminalDraft
        case .permission:
            return .unexpected
        }
    }

    /// One G3 step.
    public static func nextMove(
        prompt: PendingPrompt, draft: ReplyDraft, progress: inout ReplyProgress, screen: ScreenState, check: PromptCheck = .beforeTyping, codex: Bool = false
    ) -> ReplyMove {
        switch (prompt, draft) {
        case let (.choices(_, questions), .choices(answers)) where questions.count == answers.count && !questions.isEmpty:
            return choiceMove(questions: questions, answers: answers, progress: &progress, screen: screen, codex: codex)
        case let (.text, .text(reply)):
            switch check {
            case .beforeTyping: return textMove(reply: reply, progress: &progress, screen: screen)
            case .afterTyping: return probeMove(reply: reply, progress: &progress, screen: screen)
            }
        default:
            return .stuck("Answer kind does not match the question")
        }
    }

    /// Expected G4 transcript answer; multi-select choices are joined in option order with comma-space (measurement 7).
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

    /// Require exactly the expected change; other changes indicate concurrent terminal edits and stop delivery (Review Focus 1).
    public static func isExpected(
        after input: ConsoleInput, from old: ScreenState, to new: ScreenState, check: PromptCheck = .beforeTyping
    ) -> Bool {
        switch old {
        case let .choiceDialog(before):
            return dialogTransition(after: input, from: before, to: new)
        case .review:
            // Claude may immediately show another dialog after submission; send no further keys and defer to G4.
            guard input == .key(.enter) else { return false }
            switch new {
            case .prompt, .choiceDialog: return true
            case .review, .unrecognized: return false
            }
        case let .prompt(draft):
            guard case let .prompt(after) = new else { return false }
            switch input {
            case let .text(text):
                if ClaudeScreen.sameText(after, draft + text) { return true }
                // Typing replaces hints, but inserts into an existing draft at its cursor position.
                return check == .afterTyping && (ClaudeScreen.sameText(after, text) || isInsertion(of: text, into: draft, giving: after))
            case .key(.enter):
                // When hints look like text, verify inserted text disappeared rather than composer emptiness; G4 verifies submission.
                return check == .afterTyping ? !ClaudeScreen.sameText(after, draft) : after.isEmpty
            case .key(.backspace):
                return check == .afterTyping && removesOneCharacter(from: draft, giving: after)
            case .key:
                return false
            }
        case .unrecognized:
            return false
        }
    }

    /// Partially rendered paste frames are not results and must not stop valid input.
    /// Include previous text because the probe character already occupies the field while the remainder is pasted.
    public static func isPartial(after input: ConsoleInput, from old: ScreenState, state: ScreenState) -> Bool {
        guard case let .text(text) = input, let shown = typedField(state) else { return false }
        let typed = ((typedField(old) ?? "") + text).filter { !$0.isWhitespace }
        let visible = shown.filter { !$0.isWhitespace }
        return !visible.isEmpty && visible.count < typed.count && typed.hasPrefix(visible)
    }

    private static func typedField(_ state: ScreenState) -> String? {
        switch state {
        case let .choiceDialog(dialog): dialog.otherDraft
        case let .prompt(draft): draft
        case .review, .unrecognized: nil
        }
    }

    /// Check whether inserting inserted anywhere in base produces result; ignore wrap-dependent whitespace.
    static func isInsertion(of inserted: String, into base: String, giving result: String) -> Bool {
        let base = Array(base.filter { !$0.isWhitespace })
        let inserted = Array(inserted.filter { !$0.isWhitespace })
        let result = Array(result.filter { !$0.isWhitespace })
        guard !inserted.isEmpty, result.count == base.count + inserted.count else { return false }
        return (0...base.count).contains { index in
            Array(base[..<index] + inserted + base[index...]) == result
        }
    }

    static func removesOneCharacter(from old: String, giving new: String) -> Bool {
        let old = Array(old.filter { !$0.isWhitespace })
        return old.indices.contains { isInsertion(of: String(old[$0]), into: new, giving: String(old)) }
    }

    private static func dialogTransition(after input: ConsoleInput, from before: ChoiceDialog, to new: ScreenState) -> Bool {
        if input == .key(.enter) {
            // After selection/submission, expect only the next question, confirmation, or a prompt after dialog dismissal.
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
        case .key(.tab):
            return to == from && checksBefore == checksAfter && !before.notesActive && after.notesActive && after.otherDraft.isEmpty
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

    // MARK: Question dialogs

    private static func choiceMove(
        questions: [ChoiceQuestion], answers: [ChoiceAnswer], progress: inout ReplyProgress, screen: ScreenState, codex: Bool
    ) -> ReplyMove {
        switch screen {
        case let .review(focusedOnSubmit):
            guard focusedOnSubmit else { return .stuck("Confirmation focus is not on Submit") }
            guard progress.question == questions.count - 1 else { return .stuck("Confirmation appeared before the final question") }
            guard !progress.pressedSubmit else { return .stuck("Confirmation remains after Submit") }
            progress.pressedSubmit = true
            return .send(.key(.enter))
        case .prompt:
            return progress.pressedSubmit ? .finished : .stuck("Dialog disappeared before sending")
        case .unrecognized:
            return .stuck("Unrecognized screen")
        case let .choiceDialog(dialog):
            // A post-submission dialog is a new question; send no keys and proceed to G4.
            if progress.pressedSubmit { return .finished }
            return dialogMove(dialog, questions: questions, answers: answers, progress: &progress, codex: codex)
        }
    }

    private static func dialogMove(
        _ dialog: ChoiceDialog, questions: [ChoiceQuestion], answers: [ChoiceAnswer], progress: inout ReplyProgress, codex: Bool
    ) -> ReplyMove {
        let start = progress.question + (progress.pressedNext ? 1 : 0)
        guard start < questions.count,
              let index = questions[start...].indices.first(where: { ClaudeScreen.matches(dialog, question: questions[$0]) }) else {
            return .stuck("A different dialog is visible")
        }
        progress.pressedNext = false
        if index != progress.question {
            progress.question = index
            progress.typedText = false
        }
        guard let focus = dialog.focusedIndex else { return .stuck("Focus could not be found") }
        let question = questions[index]
        // Single-question single-select Enter submits directly; other dialogs submit from confirmation (measurement 6).
        let submitsNow = codex ? index == questions.count - 1 : questions.count == 1 && !question.multiSelect
        let optionRows = dialog.rows.indices.filter { dialog.rows[$0].kind == .option }

        switch answers[index] {
        case let .option(choice):
            guard !question.multiSelect, optionRows.indices.contains(choice) else { return .stuck("Invalid option") }
            let target = optionRows[choice]
            if focus != target { return step(from: focus, to: target) }
            return pressEnter(submits: submitsNow, progress: &progress)
        case let .other(text):
            guard !question.multiSelect else { return .stuck("Custom input is unsupported for multiple selection") }
            guard isTypable(text) else { return .stuck("Unsupported input character") }
            guard let target = dialog.rows.firstIndex(where: { $0.kind == .other }) else { return .stuck("Custom input field is missing") }
            if focus != target { return step(from: focus, to: target) }
            if codex && !dialog.notesActive { return .send(.key(.tab)) }
            if dialog.otherDraft.isEmpty {
                guard !progress.typedText else { return .stuck("Typed text is not visible in the field") }
                progress.typedText = true
                return .send(.text(text))
            }
            guard progress.typedText, ClaudeScreen.sameText(dialog.otherDraft, text) else { return .stuck("The field contains different text") }
            return pressEnter(submits: submitsNow, progress: &progress)
        case let .options(chosen):
            guard question.multiSelect, chosen.allSatisfy(optionRows.indices.contains) else { return .stuck("Invalid option") }
            guard dialog.otherDraft.isEmpty, dialog.rows.allSatisfy({ $0.kind != .other || !$0.isChecked }) else {
                return .stuck("Custom input field is not empty")
            }
            for (choice, row) in optionRows.enumerated() where dialog.rows[row].isChecked != chosen.contains(choice) {
                if focus != row { return step(from: focus, to: row) }
                // Use Space for toggles because Enter can mean something else on direct-input rows (R60).
                return .send(.key(.space))
            }
            guard let submit = dialog.rows.firstIndex(where: { $0.kind == .submit }) else { return .stuck("Submit row is missing") }
            if focus != submit { return step(from: focus, to: submit) }
            return pressEnter(submits: false, progress: &progress)
        }
    }

    /// Track whether Enter submits everything or advances so the next screen is interpreted correctly.
    private static func pressEnter(submits: Bool, progress: inout ReplyProgress) -> ReplyMove {
        if submits { progress.pressedSubmit = true } else { progress.pressedNext = true }
        return .send(.key(.enter))
    }

    private static func step(from focus: Int, to target: Int) -> ReplyMove {
        .send(.key(target > focus ? .down : .up))
    }

    // MARK: Text questions

    private static func textMove(reply: String, progress: inout ReplyProgress, screen: ScreenState) -> ReplyMove {
        guard isTypable(reply) else { return .stuck("Unsupported input character") }
        guard case let .prompt(current) = screen else { return .stuck("Prompt is not visible") }
        if current.isEmpty {
            if progress.pressedSubmit { return .finished }
            guard !progress.typedText else { return .stuck("Typed text is not visible in the prompt") }
            progress.typedText = true
            return .send(.text(reply))
        }
        guard progress.typedText, ClaudeScreen.sameText(current, reply) else { return .stuck("Prompt contains different text") }
        guard !progress.pressedSubmit else { return .stuck("Text remains after Enter") }
        progress.pressedSubmit = true
        return .send(.key(.enter))
    }

    /// Probe with one character: an otherwise empty field contains only it after hints disappear (S5, 1; S6).
    /// If inserted into existing text, erase exactly once and stop without sending (R78).
    private static func probeMove(reply: String, progress: inout ReplyProgress, screen: ScreenState) -> ReplyMove {
        // A combining first character may not be fully removed by one deletion.
        guard isTypable(reply), let first = reply.first, !first.isWhitespace, first.unicodeScalars.count == 1 else {
            return .stuck("Unsupported input character")
        }
        guard case let .prompt(current) = screen else { return .stuck("Prompt is not visible") }
        let probe = String(first)
        guard let before = progress.promptBefore else {
            progress.promptBefore = current
            return .send(.text(probe))
        }
        if progress.erasedProbe {
            return ClaudeScreen.sameText(current, before) ? .restored : .stuck("Composer was not restored after deleting the probe")
        }
        if progress.pressedSubmit { return .finished }
        if progress.typedText {
            guard ClaudeScreen.sameText(current, reply) else { return .stuck("Prompt contains different text") }
            progress.pressedSubmit = true
            return .send(.key(.enter))
        }
        if ClaudeScreen.sameText(current, probe) {
            let rest = String(reply.dropFirst())
            if rest.isEmpty {
                progress.pressedSubmit = true
                return .send(.key(.enter))
            }
            progress.typedText = true
            return .send(.text(rest))
        }
        guard isInsertion(of: probe, into: before, giving: current) else { return .stuck("Probe insertion did not match expectations") }
        progress.erasedProbe = true
        return .send(.key(.backspace))
    }

    /// Control characters act as keys: newline submits and Escape cancels rather than inserting text.
    static func isTypable(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
            && !text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}
