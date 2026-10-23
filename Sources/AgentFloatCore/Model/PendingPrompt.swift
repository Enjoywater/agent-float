import Foundation

public struct ChoiceOption: Equatable, Sendable {
    /// 보낸 뒤 기록과 대조하는 값이라 화면용으로 다듬기 전 그대로 둔다
    public let label: String
    public let description: String?
    public let hasPreview: Bool

    private static let recommendedSuffix = " (Recommended)"

    public init(label: String, description: String?, hasPreview: Bool) {
        self.label = label
        self.description = description
        self.hasPreview = hasPreview
    }

    public var isRecommended: Bool {
        label.hasSuffix(Self.recommendedSuffix)
    }

    /// 접미사는 추천 배지로 따로 보여 주므로 라벨에서는 뗀다
    public var displayLabel: String {
        isRecommended ? String(label.dropLast(Self.recommendedSuffix.count)) : label
    }
}

public struct ChoiceQuestion: Equatable, Sendable {
    public let text: String
    public let header: String?
    public let multiSelect: Bool
    public let options: [ChoiceOption]

    public init(text: String, header: String?, multiSelect: Bool, options: [ChoiceOption]) {
        self.text = text
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
    }

    /// 미리보기가 하나라도 있으면 Claude Code 가 다른 배치와 키 동작으로 그려 여기서는 답하지 않는다 (v1.2 설계 4.2)
    public var hasPreview: Bool {
        options.contains(where: \.hasPreview)
    }
}

/// 세션이 지금 사용자에게 묻고 있는 것. id 는 보내기 직전·직후에 "같은 질문인지"를 가리는 기준이다
public enum PendingPrompt: Equatable, Sendable {
    case choices(id: String, questions: [ChoiceQuestion])
    case text(id: String, message: String)
    case permission(id: String, tool: String, summary: String)

    public var id: String {
        switch self {
        case let .choices(id, _), let .text(id, _), let .permission(id, _, _): id
        }
    }
}

/// transcript 에 남은 사용자의 답. 질문 창은 질문 문장별 답, 본문 질문은 사용자가 보낸 글 그대로
public enum RecordedAnswer: Equatable, Sendable {
    case choices([String: String])
    case text(String)
}

/// 보낸 답이 실제로 기록됐는지 확인하려면 에이전트별 기록을 읽어야 해서 provider 가 맡는다
public protocol AnswerRecordReading: Sendable {
    func recordedAnswer(sessionId: String, promptId: String) -> RecordedAnswer?
}
