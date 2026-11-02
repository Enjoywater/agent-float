import Foundation

public enum QuestionHeuristic {
    /// Prefer waiting when ambiguous, except for recognized optional offers and closing remarks.
    public static func endsWithQuestion(_ markdown: String) -> Bool {
        let body = paragraphs(of: markdown).filter { !isSourceParagraph($0) }
        guard let last = body.last else { return false }
        let paragraph = last.joined(separator: "\n")
        let context = body.dropLast().last?.joined(separator: "\n") ?? ""
        let requestedChecks = matches(["기다리", "확인 부탁", "확인할 것", "결정", "정할 것", "질문", "대기", "waiting for", "please check"], context)
        if matches(["(?m)^\\*\\*[ABC]\\*\\*.*\\|"], context) { return true }
        return asksUser(paragraph, requestedChecks: requestedChecks || matches(["확인 부탁", "확인이 필요한", "확인 필요", "남은 확인", "남은 질문"], paragraph))
    }

    private static let sourceLabels = ["sources", "출처", "참고"]

    private struct Rules {
        let suggestions: [String]
        let closings: [String]
        let requests: [String]
        let conditionals: [String]
        let waiting: [String]
        let decisions: [String]
        let checks: [String]
    }

    private static let korean = Rules(
        suggestions: ["^(원하면|원하시면|필요하면|필요하시면)", "^.{0,50}싶으면", "^[^,\"“”「」()]{0,60}(려면|싶다면|원하시면|필요하시면|원하면|필요하면)"],
        closings: ["^추가로 궁금한 점 있으면", "^더 궁금한 점이 있으면"],
        requests: ["(까|까요|나요|있나|없나|되나|는지|인지|을지|할지|될지|궁금함|궁금해|궁금합니다|알려줘|알려 줘|알려주세요|알려줄래|말해줘|골라줘|정해줘|선택해줘|확인해줘|어때|어떤가|할래|줄래|주세요|부탁드립니다|해달라|알려달라|인가요)$"],
        conditionals: ["주시면", "해 ?주면", "알려주면", "하시면", "정해지면", "쓰시면", "(?:려면|다면)"],
        waiting: ["(지시|응답|답변|승인|결정).{0,20}(기다리|대기)", "기다리겠습니다", "대기하겠습니다", "기다리고 있", "확인 부탁$", "확인이 필요한", "기다리는 중", "지시가.{0,20}(착수|시작)"],
        decisions: ["(할지|을지|될지|쓸지|낼지|줄지|할까요)$"],
        checks: ["(는지|인지|있는지|되는지)$"]
    )
    private static let english = Rules(
        suggestions: ["^if (you(?:’|')?d like|you (?:want|need)|needed)\\b"],
        closings: ["^let me know if you (?:need|have) (?:anything else|any (?:other )?questions)", "^feel free to ask", "^happy to help"],
        requests: ["^please (?:confirm|choose|select|tell|share|let|review|approve|provide|decide)", "^let me know (?:which|what|whether|when|how|your)", "^(?:tell|choose|select|confirm|approve|provide)\\b", "(?:your (?:approval|confirmation|decision)|go-ahead).{0,10}(?:needed|required)$"],
        conditionals: ["^once you\\b", "^when you\\b", "^if you\\b", "^after you\\b"],
        waiting: ["\\bwaiting for\\b", "\\bawaiting (?:your|a|the)\\b", "\\bwait for your\\b"],
        decisions: ["^whether to\\b"],
        checks: ["^whether (?!to\\b)"]
    )

    private static func paragraphs(of markdown: String) -> [[Substring]] {
        var paragraphs: [[Substring]] = []
        var current: [Substring] = []
        // CRLF is one Character; split by newline properties so blank paragraphs are recognized.
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

    /// Treat source labels as headings only before a colon or line end, preserving ordinary questions beginning with the same word.
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

    private static func matches(_ patterns: [String], _ text: String) -> Bool {
        patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    private static func asksUser(_ paragraph: String, requestedChecks: Bool) -> Bool {
        // Remove code and URLs before punctuation splitting so their question marks cannot create waits.
        let plain = paragraph.replacingOccurrences(of: #"(?s)```.*?```|`[^`]*`|\b[A-Za-z_]\w*\?\.\w+|https?://[^\s<>]+"#,
                                                   with: " ", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
        for line in plain.components(separatedBy: .newlines) {
            let isList = line.range(of: #"^\s*(?:[-*+] |[0-9]+[.)] )"#, options: .regularExpression) != nil
            let content = line.replacingOccurrences(of: #"^\s*(?:[-*+] |[0-9]+[.)] )"#, with: "", options: .regularExpression)
            if requestedChecks, isList {
                let rules = content.range(of: "[가-힣]", options: .regularExpression) == nil ? english : korean
                if matches(rules.checks, content.trimmingCharacters(in: .whitespacesAndNewlines)) { return true }
            }
            var sentence = ""
            for character in content {
                if ".!?？。".contains(character) {
                    if asksSentence(sentence, questionMark: character == "?" || character == "？", isList: isList && !requestedChecks) { return true }
                    sentence = ""
                } else { sentence.append(character) }
            }
            if asksSentence(sentence, questionMark: false, isList: isList && !requestedChecks) { return true }
        }
        return false
    }

    private static func asksSentence(_ sentence: String, questionMark: Bool, isList: Bool) -> Bool {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
        guard !text.isEmpty else { return false }
        let rules = text.range(of: "[가-힣]", options: .regularExpression) == nil ? english : korean
        if text.contains("려면"), matches(rules.requests, text) { return true }
        if matches(rules.suggestions, text) || matches(rules.closings, text) { return false }
        if questionMark || matches(rules.conditionals, text) || matches(rules.waiting, text) { return true }
        if isList {
            if matches(rules.decisions, text) { return true }
            if matches(rules.checks, text) { return false }
        }
        return matches(rules.requests, text)
    }
}
