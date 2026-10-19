import Foundation

public enum QuestionHeuristic {
    /// 마지막 본문 문단이 사용자에게 되묻는 말로 끝나는지 본다. 놓치면 대기 중인 세션이 묻히므로 오탐은 감수한다
    public static func endsWithQuestion(_ markdown: String) -> Bool {
        guard let paragraph = lastBodyParagraph(of: markdown) else { return false }
        return asksUser(paragraph)
    }

    // 어미가 "~하겠습니다"로 끝나도 사용자의 조치를 전제로 멈춘 말이라, 문장 위치와 무관하게 문단 안에만 있으면 질문으로 본다
    private static let conditionalRequests = ["주시면", "해 주면", "해주면", "알려주면"]
    private static let sourceLabels = ["sources", "출처", "참고"]
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "？", "。", "\n"]
    private static let questionMarks: Set<Character> = ["?", "？"]
    private static let questionEndings = [
        "까", "까요", "나요", "있나", "없나", "되나", "는지", "인지", "을지", "할지", "될지",
        "궁금함", "궁금해", "궁금합니다",
        "알려줘", "알려 줘", "알려주세요", "알려줄래", "말해줘", "골라줘", "정해줘", "선택해줘", "확인해줘",
        "어때", "어떤가", "할래", "줄래",
        // 프로젝트마다 답변 어체가 달라, 위 평어 목록만으로는 존댓말·"달라" 요청형이 통째로 빠진다
        "주세요", "부탁드립니다", "해달라", "알려달라", "인가요",
    ]

    private static func lastBodyParagraph(of markdown: String) -> String? {
        paragraphs(of: markdown)
            .last { !isSourceParagraph($0) }
            .map { $0.joined(separator: "\n") }
    }

    private static func paragraphs(of markdown: String) -> [[Substring]] {
        var paragraphs: [[Substring]] = []
        var current: [Substring] = []
        // "\r\n"은 Character 하나라 개행 판정으로 나눠야 CRLF 응답도 빈 줄이 잡힌다
        for line in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.allSatisfy(\.isWhitespace) {
                if !current.isEmpty { paragraphs.append(current) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs
    }

    private static func isSourceParagraph(_ lines: [Substring]) -> Bool {
        isSourceHeading(lines[0]) || lines.allSatisfy(isLinkListItem)
    }

    /// "참고로 …"처럼 라벨로 시작하는 평문 질문까지 출처로 버리면 놓치므로, 라벨 뒤가 콜론·줄 끝일 때만 헤딩으로 본다
    private static func isSourceHeading(_ line: Substring) -> Bool {
        let text = line
            .filter { !"*_`#".contains($0) }
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard let label = sourceLabels.first(where: { text.hasPrefix($0) }) else { return false }
        var rest = text.dropFirst(label.count).drop(while: \.isWhitespace)
        guard let colon = rest.first, colon == ":" || colon == "：" else { return rest.isEmpty }
        rest = rest.dropFirst()
        return rest.allSatisfy(\.isWhitespace) || rest.contains("http")
    }

    private static func isLinkListItem(_ line: Substring) -> Bool {
        let item = line.drop(while: \.isWhitespace)
        let afterNumber = item.drop(while: \.isNumber)
        let isNumbered = afterNumber.count < item.count && (afterNumber.hasPrefix(". ") || afterNumber.hasPrefix(") "))
        let isBulleted = ["- ", "* ", "+ "].contains { item.hasPrefix($0) }
        return (isBulleted || isNumbered) && item.contains("](http")
    }

    private static func asksUser(_ paragraph: String) -> Bool {
        let plain = paragraph
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        if conditionalRequests.contains(where: plain.contains) { return true }
        var sentence = ""
        for character in plain {
            guard sentenceTerminators.contains(character) else {
                sentence.append(character)
                continue
            }
            if questionMarks.contains(character) || endsWithQuestionPhrase(sentence) { return true }
            sentence = ""
        }
        return endsWithQuestionPhrase(sentence)
    }

    private static func endsWithQuestionPhrase(_ sentence: String) -> Bool {
        var end = sentence.endIndex
        while end > sentence.startIndex {
            let previous = sentence.index(before: end)
            let character = sentence[previous]
            // "~"나 이모지로 끝맺는 말투도 어미를 봐야 하므로 기호까지 뗀다
            guard character.isWhitespace || character.isPunctuation || character.isSymbol else { break }
            end = previous
        }
        let trimmed = sentence[..<end]
        return questionEndings.contains { trimmed.hasSuffix($0) }
    }
}
