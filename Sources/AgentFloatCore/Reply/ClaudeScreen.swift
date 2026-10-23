import Foundation

public struct ChoiceRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case option, other, chat, submit
    }

    /// 체크 상자를 뗀 줄 글. 직접 쓰기 줄은 안내 문구나 쓴 글
    public let label: String
    public let isFocused: Bool
    public let isChecked: Bool
    public let kind: Kind

    public init(label: String, isFocused: Bool, isChecked: Bool, kind: Kind) {
        self.label = label
        self.isFocused = isFocused
        self.isChecked = isChecked
        self.kind = kind
    }
}

public struct ChoiceDialog: Equatable, Sendable {
    /// 감긴 줄을 공백 하나로 이은 질문 문장
    public let questionText: String
    public let rows: [ChoiceRow]
    /// 직접 쓰기 칸에 적힌 글. 비었으면 ""
    public let otherDraft: String

    public init(questionText: String, rows: [ChoiceRow], otherDraft: String) {
        self.questionText = questionText
        self.rows = rows
        self.otherDraft = otherDraft
    }

    public var focusedIndex: Int? {
        rows.firstIndex(where: \.isFocused)
    }
}

public enum ScreenState: Equatable, Sendable {
    case choiceDialog(ChoiceDialog)
    case review(focusedOnSubmit: Bool)
    /// 질문 창이 없고 프롬프트가 보임. 진행 중 화면도 빈 프롬프트로 읽힌다
    case prompt(draft: String)
    case unrecognized
}

/// Claude Code 2.1.309 의 질문 창·확인 화면·프롬프트를 화면 글자로 알아본다. 모양 규칙의 근거는 rulings "v1.2 답장" 실측 표
public enum ClaudeScreen {
    static let otherPlaceholders: Set<String> = ["Type something.", "Type something"]
    static let chatLabel = "Chat about this"
    static let submitLabel = "Submit"
    static let reviewMarker = "Ready to submit your answers?"
    static let reviewSubmitLabel = "Submit answers"
    /// 질문 문장은 이만큼만 비교한다. 길이가 다른 화면 폭에서 감겨도 앞부분은 같다
    static let questionPrefixLength = 24

    public static func interpret(_ screen: ConsoleScreen) -> ScreenState {
        let lines = screen.lines
        let promptIndex = lines.lastIndex(where: isPromptLine)
        let headerIndex = lines.lastIndex(where: isHeaderLine)
        // 맨 아래에 그려진 것이 지금의 화면이다. 위쪽 기록에 남은 옛 질문 창이나 입력 글을 읽지 않는다
        if let headerIndex, promptIndex.map({ headerIndex > $0 }) ?? true {
            return dialogState(Array(lines[(headerIndex + 1)...]))
        }
        if let promptIndex {
            return .prompt(draft: promptDraft(screen, from: promptIndex))
        }
        return .unrecognized
    }

    /// 화면의 질문 문장 앞부분과 선택지(원래 라벨)가 순서까지 같아야 같은 질문이다
    public static func matches(_ dialog: ChoiceDialog, question: ChoiceQuestion) -> Bool {
        let shown = normalized(dialog.questionText)
        let asked = normalized(question.text)
        guard String(shown.prefix(questionPrefixLength)) == String(asked.prefix(questionPrefixLength)) else { return false }
        let labels = dialog.rows.filter { $0.kind == .option }.map(\.label)
        return labels == question.options.map(\.label)
    }

    /// 입력 칸은 폭에 맞춰 단어 사이에서 감기며 그 자리의 공백이 사라지므로 공백을 빼고 비교한다
    public static func sameText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.filter { !$0.isWhitespace } == rhs.filter { !$0.isWhitespace }
    }

    // MARK: 줄 종류

    /// 프롬프트는 `❯` 뒤에 NBSP 가 오고, 선택지 포인터는 일반 공백이 온다 (실측 ⑨·①)
    private static func isPromptLine(_ line: String) -> Bool {
        line == "❯" || line.hasPrefix("❯\u{a0}")
    }

    /// 질문 창 맨 위의 머리표 줄(` ☐ 머리표`) 또는 질문이 여럿일 때의 탭 줄(`←  ☐ 가  ☐ 나  ✔ Submit  →`)
    private static func isHeaderLine(_ line: String) -> Bool {
        var rest = Substring(line).drop(while: { $0 == " " })
        if rest.hasPrefix("←") { rest = rest.dropFirst().drop(while: { $0 == " " }) }
        guard let first = rest.first else { return false }
        return first == "☐" || first == "☒"
    }

    // MARK: 질문 창

    private struct ParsedRow {
        let number: Int?
        let row: ChoiceRow
    }

    private static func dialogState(_ body: [String]) -> ScreenState {
        if let reviewIndex = body.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == reviewMarker }) {
            let rows = body[(reviewIndex + 1)...].compactMap(parseRow)
            guard !rows.isEmpty else { return .unrecognized }
            let onSubmit = rows.contains { $0.row.isFocused && $0.row.label == reviewSubmitLabel }
            return .review(focusedOnSubmit: onSubmit)
        }

        guard let firstRow = body.firstIndex(where: { parseRow($0) != nil }) else { return .unrecognized }
        let question = body[..<firstRow]
            .map(questionLine)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let parsed = body[firstRow...].compactMap(parseRow)
        let rows = classify(parsed)
        guard !question.isEmpty, rows.contains(where: { $0.kind == .option }) else { return .unrecognized }
        let other = rows.first { $0.kind == .other }
        let draft = other.map { otherPlaceholders.contains($0.label) ? "" : $0.label } ?? ""
        return .choiceDialog(ChoiceDialog(questionText: question, rows: rows, otherDraft: draft))
    }

    /// 긴 질문은 줄마다 `│ ` 거터가 붙는다 (실측)
    private static func questionLine(_ line: String) -> String {
        var text = Substring(line)
        if text.hasPrefix("│") { text = text.dropFirst() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// `❯ 1. 라벨`, `  2. [✔] 라벨`, `❯    Submit`. 설명 줄처럼 번호가 없는 들여쓴 줄은 nil
    private static func parseRow(_ line: String) -> ParsedRow? {
        guard let marker = line.first, marker == "❯" || marker == " " else { return nil }
        let isFocused = marker == "❯"
        let rest = line.dropFirst().drop(while: { $0 == " " })
        if rest.trimmingCharacters(in: .whitespaces) == submitLabel {
            return ParsedRow(number: nil, row: ChoiceRow(label: submitLabel, isFocused: isFocused, isChecked: false, kind: .submit))
        }
        guard let match = rest.wholeMatch(of: /(\d+)\. (.*)/), let number = Int(match.output.1) else { return nil }
        var label = String(match.output.2).trimmingCharacters(in: .whitespaces)
        var isChecked = false
        if label.hasPrefix("[✔]") {
            isChecked = true
            label = String(label.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if label.hasPrefix("[ ]") {
            label = String(label.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        return ParsedRow(number: number, row: ChoiceRow(label: label, isFocused: isFocused, isChecked: isChecked, kind: .option))
    }

    /// 직접 쓰기 줄은 글을 쓰면 안내 문구가 사라지므로 글자가 아니라 자리로 찾는다: Chat 줄 바로 앞 번호
    private static func classify(_ parsed: [ParsedRow]) -> [ChoiceRow] {
        let chatNumber = parsed.last { $0.row.label == chatLabel }?.number
        let otherNumber = chatNumber.map { $0 - 1 }
            ?? parsed.first { otherPlaceholders.contains($0.row.label) }?.number
        return parsed.map { item in
            let kind: ChoiceRow.Kind
            if item.row.kind == .submit {
                kind = .submit
            } else if item.number != nil, item.number == chatNumber {
                kind = .chat
            } else if item.number != nil, item.number == otherNumber {
                kind = .other
            } else {
                kind = .option
            }
            return ChoiceRow(label: item.row.label, isFocused: item.row.isFocused, isChecked: item.row.isChecked, kind: kind)
        }
    }

    // MARK: 프롬프트

    /// 프롬프트 줄과 이어지는 줄(입력이 길어 감긴 줄)에서 흐리지 않은 글자만 모은다.
    /// 흐림을 읽지 못하는 화면에서는 안내·제안 문구도 글로 남아, 비어 있지 않은 것으로 판정된다 (설계 4.4 "애매하면 비어 있지 않은 것")
    private static func promptDraft(_ screen: ConsoleScreen, from promptIndex: Int) -> String {
        var pieces: [String] = []
        var index = promptIndex
        while index < screen.lines.count {
            let line = screen.lines[index]
            if index > promptIndex, line.hasPrefix("─") || line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            let skip = index == promptIndex ? 1 : 0
            let faint = screen.faint.map { index < $0.count ? $0[index] : [] }
            let kept = line.enumerated().compactMap { offset, character -> Character? in
                guard offset >= skip, faint?.contains(offset) != true else { return nil }
                return character
            }
            pieces.append(String(kept).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{a0}"))))
            index += 1
        }
        return pieces.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
