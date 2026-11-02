import Foundation

public enum PrimaryAction: Equatable, Sendable {
    case send, next, disabled
}

/// Input-rejection reasons also drive the helper text below the field.
public enum TextBlock: Equatable, Sendable {
    /// Claude interprets leading /, !, and # as commands, shell execution, and notes.
    case commandLike
    /// An @ opens file completion, making Enter select a suggestion rather than submit text (measurement 10).
    case mention
    case multiline
    case controlCharacter
    /// Long pastes collapse into Pasted text markers, preventing onscreen verification.
    case tooLong
}

public enum ReplyText {
    /// Claude 2.1.310 preserves up to 800 UTF-16 units and collapses at 801 (S6, 8), matching JS string length.
    public static let pasteFoldLimit = 800

    /// Direct-input fields have no completion; apply command/@ restrictions only to the main composer (measurement 10).
    public static func block(_ text: String, inPrompt: Bool) -> TextBlock? {
        if text.contains(where: \.isNewline) { return .multiline }
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return .controlCharacter }
        // Trim surrounding whitespace before sending.
        if text.trimmingCharacters(in: .whitespaces).utf16.count > pasteFoldLimit { return .tooLong }
        guard inPrompt else { return nil }
        if let first = text.first(where: { !$0.isWhitespace }), "/!#".contains(first) { return .commandLike }
        if text.contains("@") { return .mention }
        return nil
    }
}

/// Retain edited answers by question ID so leaving and reopening a row preserves drafts.
public struct ReplyEditor: Equatable, Sendable {
    public let prompt: PendingPrompt
    /// Current question index; questions.count represents multi-question confirmation.
    public private(set) var step = 0
    public private(set) var answers: [ChoiceAnswer?]
    public private(set) var replyText = ""
    private var otherTexts: [String]

    public init(prompt: PendingPrompt) {
        self.prompt = prompt
        let count = Self.questions(of: prompt).count
        answers = Array(repeating: nil, count: count)
        otherTexts = Array(repeating: "", count: count)
    }

    public var questions: [ChoiceQuestion] {
        Self.questions(of: prompt)
    }

    public var currentQuestion: ChoiceQuestion? {
        questions.indices.contains(step) ? questions[step] : nil
    }

    public var otherText: String {
        otherTexts.indices.contains(step) ? otherTexts[step] : ""
    }

    /// Disable multi-select custom input because its recorded format has not been measured (Task 3 decision).
    public var acceptsOtherText: Bool {
        currentQuestion.map { !$0.multiSelect } ?? false
    }

    public var isReviewing: Bool {
        questions.count > 1 && step == questions.count
    }

    public mutating func choose(option: Int) {
        guard let question = currentQuestion, question.options.indices.contains(option) else { return }
        if question.multiSelect {
            var chosen: Set<Int> = []
            if case let .options(current)? = answers[step] { chosen = current }
            if chosen.contains(option) { chosen.remove(option) } else { chosen.insert(option) }
            answers[step] = chosen.isEmpty ? nil : .options(chosen)
        } else {
            answers[step] = .option(option)
        }
        otherTexts[step] = ""
    }

    public mutating func setOther(_ text: String) {
        guard acceptsOtherText else { return }
        otherTexts[step] = text
        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            answers[step] = .other(text)
        } else if case .other? = answers[step] {
            answers[step] = nil
        }
    }

    public mutating func setReply(_ text: String) {
        replyText = text
    }

    /// After editing an already complete multi-question answer, return directly to confirmation.
    public mutating func advance() {
        guard questions.count > 1, step < questions.count, isAnswered(step) else { return }
        step = answers.indices.allSatisfy(isAnswered) ? questions.count : step + 1
    }

    public mutating func edit(question: Int) {
        guard questions.indices.contains(question) else { return }
        step = question
    }

    public var block: TextBlock? {
        switch prompt {
        case .text:
            return replyText.isEmpty ? nil : ReplyText.block(replyText, inPrompt: true)
        case .choices:
            return otherText.isEmpty ? nil : ReplyText.block(otherText, inPrompt: false)
        case .permission:
            return nil
        }
    }

    public var primary: PrimaryAction {
        switch prompt {
        case .permission:
            return .disabled
        case .text:
            return draft == nil ? .disabled : .send
        case .choices:
            if isReviewing { return draft == nil ? .disabled : .send }
            guard isAnswered(step) else { return .disabled }
            return questions.count == 1 ? .send : .next
        }
    }

    /// Expose a value only when sendable; multi-question answers send from confirmation only.
    /// Trim surrounding whitespace because Claude's normalized recording would otherwise look mismatched.
    public var draft: ReplyDraft? {
        switch prompt {
        case .permission:
            return nil
        case .text:
            guard !replyText.trimmingCharacters(in: .whitespaces).isEmpty,
                  ReplyText.block(replyText, inPrompt: true) == nil else { return nil }
            return .text(Self.trimmed(replyText))
        case .choices:
            guard questions.count == 1 || isReviewing, answers.indices.allSatisfy(isAnswered) else { return nil }
            return .choices(answers.compactMap { answer in
                if case let .other(text)? = answer { return .other(Self.trimmed(text)) }
                return answer
            })
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    private func isAnswered(_ index: Int) -> Bool {
        guard answers.indices.contains(index), let answer = answers[index] else { return false }
        if case let .other(text) = answer {
            return !text.trimmingCharacters(in: .whitespaces).isEmpty && ReplyText.block(text, inPrompt: false) == nil
        }
        return true
    }

    private static func questions(of prompt: PendingPrompt) -> [ChoiceQuestion] {
        if case let .choices(_, questions) = prompt { return questions }
        return []
    }
}

public enum ReplyKeyInput: Equatable, Sendable {
    case digit(Int), returnKey, escape, other
}

public enum ReplyKeyAction: Equatable, Sendable {
    case select(Int), primary, commitComposition, leaveField, back, passThrough
}

public enum ReplyKeys {
    /// Return commits IME composition; sending then could drop or partially compose the final character.
    public static func action(for input: ReplyKeyInput, fieldFocused: Bool, hasMarkedText: Bool) -> ReplyKeyAction {
        switch input {
        case let .digit(number):
            guard !fieldFocused, (1...9).contains(number) else { return .passThrough }
            return .select(number - 1)
        case .returnKey:
            return hasMarkedText ? .commitComposition : .primary
        case .escape:
            // During composition, Escape belongs to the input method.
            if hasMarkedText { return .passThrough }
            return fieldFocused ? .leaveField : .back
        case .other:
            return .passThrough
        }
    }
}
