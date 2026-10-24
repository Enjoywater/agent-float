import Foundation

public enum PrimaryAction: Equatable, Sendable {
    case send, next, disabled
}

/// 보낼 수 없는 글의 이유. 화면 아래 안내 문구가 이 값을 따른다
public enum TextBlock: Equatable, Sendable {
    /// `/`·`!`·`#` 로 시작하면 Claude Code 가 명령·셸·메모로 읽는다
    case commandLike
    /// `@` 가 있으면 프롬프트 위에 파일 자동 완성이 떠 Enter 가 글 대신 제안을 고른다 (실측 ⑩)
    case mention
    case multiline
    case controlCharacter
}

public enum ReplyText {
    /// 직접 쓰기 칸에는 자동 완성이 뜨지 않아 명령·`@` 규칙은 프롬프트에만 적용한다 (실측 ⑩)
    public static func block(_ text: String, inPrompt: Bool) -> TextBlock? {
        if text.contains(where: \.isNewline) { return .multiline }
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return .controlCharacter }
        guard inPrompt else { return nil }
        if let first = text.first(where: { !$0.isWhitespace }), "/!#".contains(first) { return .commandLike }
        if text.contains("@") { return .mention }
        return nil
    }
}

/// 답장 화면에서 고르고 쓰는 중인 답. 질문 id 별로 보관되어, 다른 줄을 보고 돌아와도 그대로 남는다
public struct ReplyEditor: Equatable, Sendable {
    public let prompt: PendingPrompt
    /// 지금 보고 있는 질문. 질문이 여럿이면 `questions.count` 가 확인 화면이다
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

    /// 여러 개 고르기의 직접 입력은 기록 형식을 실측하지 못해 받지 않는다 (Task 3 결정)
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

    /// 확인 화면에서 고치러 들어왔다가 다 답했으면 곧바로 확인 화면으로 돌아간다
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

    /// 보낼 수 있을 때만 값이 있다. 질문이 여럿이면 확인 화면에서만 보낸다.
    /// 앞뒤 공백은 뺀다 — Claude Code 가 다듬어 기록하면 보낸 글과 기록이 달라 보이기 때문이다
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
    /// 한글 조합 중의 ⏎ 는 글자를 확정하는 키다. 여기서 보내면 마지막 글자가 빠지거나 반쯤 조합된 채 보내진다
    public static func action(for input: ReplyKeyInput, fieldFocused: Bool, hasMarkedText: Bool) -> ReplyKeyAction {
        switch input {
        case let .digit(number):
            guard !fieldFocused, (1...9).contains(number) else { return .passThrough }
            return .select(number - 1)
        case .returnKey:
            return hasMarkedText ? .commitComposition : .primary
        case .escape:
            // 조합 중 esc 는 입력기가 조합을 취소하는 데 쓴다
            if hasMarkedText { return .passThrough }
            return fieldFocused ? .leaveField : .back
        case .other:
            return .passThrough
        }
    }
}
