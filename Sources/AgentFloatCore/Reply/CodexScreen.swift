import Foundation

/// Codex 0.165.0의 실제 TUI로 검증한 질문 창·notes·본문 입력 칸.
public enum CodexScreen {
    public static func interpret(_ screen: ConsoleScreen) -> ScreenState {
        let lines = screen.lines
        if let header = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Question ") }),
           let footer = lines[(header + 1)...].lastIndex(where: { $0.contains("enter to submit ") }),
           !lines[(footer + 1)...].contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("› ") }) {
            return dialog(screen, header: header, footer: footer)
        }
        guard let index = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("› ") || $0.trimmingCharacters(in: .whitespaces) == "›" }) else {
            return .unrecognized
        }
        var draft = promptText(screen, index: index)
        // 입력 줄은 감길 수 있다. 상태 줄 앞의 빈 줄에서 멈춘다.
        var next = index + 1
        while next < lines.count, !lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
            draft += lines[next].trimmingCharacters(in: .whitespaces)
            next += 1
        }
        return .prompt(draft: draft)
    }

    public static func placingPromptInput(_ screen: ConsoleScreen) -> ConsoleScreen {
        guard case .prompt = interpret(screen), let index = screen.lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("› ") }) else { return screen }
        var lines = screen.lines
        lines[index] = "› " + (screen.composerDraft ?? "")
        var next = index + 1
        while next < lines.count, !lines[next].trimmingCharacters(in: .whitespaces).isEmpty { lines[next] = ""; next += 1 }
        return ConsoleScreen(lines: lines, faint: nil, composerDraft: nil)
    }

    private static func promptText(_ screen: ConsoleScreen, index: Int) -> String {
        let chars = Array(screen.lines[index])
        guard let marker = chars.firstIndex(of: "›") else { return "" }
        let start = marker + 1 + (chars.indices.contains(marker + 1) && chars[marker + 1] == " " ? 1 : 0)
        let faint = screen.faint.flatMap { index < $0.count ? $0[index] : nil }
        return String(chars.enumerated().compactMap { offset, char in
            offset >= start && faint?.contains(offset) != true ? char : nil
        }).trimmingCharacters(in: .whitespaces)
    }

    private static func dialog(_ screen: ConsoleScreen, header: Int, footer: Int) -> ScreenState {
        var question: [String] = []
        var rows: [ChoiceRow] = []
        var notesActive = false
        var notes = ""
        let pattern = #"^\s*(›\s*)?([0-9]+)\.\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return .unrecognized }
        for index in (header + 1)..<footer {
            let line = screen.lines[index]
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range), let labelRange = Range(match.range(at: 3), in: line) {
                let text = String(line[labelRange])
                let label = text.components(separatedBy: "  ").first?.trimmingCharacters(in: .whitespaces) ?? text
                let focused = match.range(at: 1).location != NSNotFound
                rows.append(ChoiceRow(label: label, isFocused: focused, isChecked: false, kind: label == "None of the above" ? .other : .option))
            } else if !rows.isEmpty, line.trimmingCharacters(in: .whitespaces).hasPrefix("› ") {
                notesActive = true
                notes = promptText(screen, index: index)
                if notes == "Add notes" { notes = "" }
            } else if rows.isEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                question.append(line.trimmingCharacters(in: .whitespaces))
            } else if notesActive, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                notes += line.trimmingCharacters(in: .whitespaces)
            }
        }
        guard !question.isEmpty, !rows.isEmpty else { return .unrecognized }
        return .choiceDialog(ChoiceDialog(questionText: question.joined(separator: " "), rows: rows, otherDraft: notes, notesActive: notesActive))
    }
}
