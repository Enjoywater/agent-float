import Foundation

public struct ChoiceRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case option, other, chat, submit
    }

    /// Option text without checkbox markers; direct-input rows contain a hint or draft.
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
    /// Question text with wrapped lines joined by single spaces.
    public let questionText: String
    public let rows: [ChoiceRow]
    /// Text currently in the direct-input field, empty when absent.
    public let otherDraft: String
    public let notesActive: Bool

    public init(questionText: String, rows: [ChoiceRow], otherDraft: String, notesActive: Bool = false) {
        self.questionText = questionText
        self.rows = rows
        self.otherDraft = otherDraft
        self.notesActive = notesActive
    }

    public var focusedIndex: Int? {
        rows.firstIndex(where: \.isFocused)
    }
}

public enum ScreenState: Equatable, Sendable {
    case choiceDialog(ChoiceDialog)
    case review(focusedOnSubmit: Bool)
    /// No dialog and a visible prompt; running screens can also appear as an empty prompt.
    case prompt(draft: String)
    case unrecognized
}

/// Recognize Claude Code 2.1.309 dialogs, confirmation, and prompts from rendered text (v1.2 reply rulings measurements).
public enum ClaudeScreen {
    static let otherPlaceholders: Set<String> = ["Type something.", "Type something"]
    static let chatLabel = "Chat about this"
    static let submitLabel = "Submit"
    static let reviewMarker = "Ready to submit your answers?"
    static let reviewSubmitLabel = "Submit answers"
    /// Compare only the question prefix, which remains stable when terminal widths wrap differently.
    static let questionPrefixLength = 24

    public static func interpret(_ screen: ConsoleScreen) -> ScreenState {
        let lines = screen.lines
        if let promptIndex = activePromptIndex(lines) {
            return .prompt(draft: promptDraft(screen, from: promptIndex))
        }
        if let headerIndex = lines.lastIndex(where: isHeaderLine) {
            return dialogState(Array(lines[(headerIndex + 1)...]))
        }
        return .unrecognized
    }

    /// For terminals exposing composer text separately, such as Orca draft (S5), screen text contains only faint suggestions.
    /// Replace that suggestion with the supplied draft; leave dialogs untouched because draft ownership is ambiguous and must block sending.
    public static func placingPromptInput(_ screen: ConsoleScreen) -> ConsoleScreen {
        guard let index = activePromptIndex(screen.lines) else { return screen }
        var lines = screen.lines
        lines[index] = "❯\u{a0}" + (screen.composerDraft ?? "")
        // Wrapped hint lines still belong to the composer.
        var next = index + 1
        while next < lines.count, !lines[next].hasPrefix("─"), !lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
            lines[next] = ""
            next += 1
        }
        return ConsoleScreen(lines: lines, faint: nil, composerDraft: nil)
    }

    /// Only the bottommost rendered prompt is current; return nil for old scrollback prompts or a later dialog.
    private static func activePromptIndex(_ lines: [String]) -> Int? {
        guard let promptIndex = lines.lastIndex(where: isPromptLine) else { return nil }
        if let headerIndex = lines.lastIndex(where: isHeaderLine), headerIndex > promptIndex { return nil }
        return promptIndex
    }

    /// Match the question prefix and original option labels in exact order.
    public static func matches(_ dialog: ChoiceDialog, question: ChoiceQuestion) -> Bool {
        let shown = normalized(dialog.questionText)
        let asked = normalized(question.text)
        guard String(shown.prefix(questionPrefixLength)) == String(asked.prefix(questionPrefixLength)) else { return false }
        let labels = dialog.rows.filter { $0.kind == .option }.map(\.label)
        return labels == question.options.map(\.label)
    }

    /// Wrapping removes inter-word spaces, so compare composer text without whitespace.
    public static func sameText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.filter { !$0.isWhitespace } == rhs.filter { !$0.isWhitespace }
    }

    // MARK: Line kinds

    /// Prompts use NBSP after ❯; option pointers use ordinary spaces (measurements 9 and 1).
    private static func isPromptLine(_ line: String) -> Bool {
        line == "❯" || line.hasPrefix("❯\u{a0}")
    }

    /// Dialog header chip or multi-question tab row, including arrows, question chips, and Submit.
    private static func isHeaderLine(_ line: String) -> Bool {
        var rest = Substring(line).drop(while: { $0 == " " })
        if rest.hasPrefix("←") { rest = rest.dropFirst().drop(while: { $0 == " " }) }
        guard let first = rest.first else { return false }
        return first == "☐" || first == "☒"
    }

    // MARK: Question dialogs

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

    /// Wrapped questions repeat the vertical gutter on each line.
    private static func questionLine(_ line: String) -> String {
        var text = Substring(line)
        if text.hasPrefix("│") { text = text.dropFirst() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Option numbers start one space after the pointer (two for aligned two-digit numbers); descriptions indent five spaces.
    static let maxRowIndent = 2

    /// Parse pointer/number/label or checked options; unnumbered Submit/description/deeply indented lines return nil.
    private static func parseRow(_ line: String) -> ParsedRow? {
        guard let marker = line.first, marker == "❯" || marker == " " else { return nil }
        let isFocused = marker == "❯"
        let afterMarker = line.dropFirst()
        let rest = afterMarker.drop(while: { $0 == " " })
        if rest.trimmingCharacters(in: .whitespaces) == submitLabel {
            return ParsedRow(number: nil, row: ChoiceRow(label: submitLabel, isFocused: isFocused, isChecked: false, kind: .submit))
        }
        guard afterMarker.count - rest.count <= maxRowIndent,
              let match = rest.wholeMatch(of: /(\d+)\. (.*)/), let number = Int(match.output.1) else { return nil }
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

    /// Locate direct input by position immediately before Chat, since typing replaces its placeholder text.
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

    // MARK: Prompt

    /// Collect only non-faint text from the prompt and its wrapped continuation lines.
    /// Without faint styling, hints look like draft text; ambiguity must count as non-empty (design §4.4).
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
