import Foundation

public struct ChoiceOption: Equatable, Sendable {
    /// Preserve raw labels for post-send transcript verification rather than display formatting.
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

    /// Remove recommendation suffixes because a separate badge renders them.
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

    /// Previews change Claude's layout and key handling, so any preview makes the dialog read-only (v1.2 design §4.2).
    public var hasPreview: Bool {
        options.contains(where: \.hasPreview)
    }
}

/// The current user-facing prompt; ID establishes question identity immediately before and after sending.
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

/// Recorded user replies: per-question answers for dialogs, literal user text for body questions.
public enum RecordedAnswer: Equatable, Sendable {
    case choices([String: String])
    case text(String)
}

/// Providers verify replies because each agent has its own transcript format.
public protocol AnswerRecordReading: Sendable {
    func recordedAnswer(sessionId: String, promptId: String) -> RecordedAnswer?
}
