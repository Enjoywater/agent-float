import AgentFloatCore
import SwiftUI

/// Reply dimensions match the v1.2 design §4.8 table.
enum ReplyLayout {
    static let width: CGFloat = 320
    static let innerRadius: CGFloat = 12
    static let buttonHeight: CGFloat = 28
    static let buttonRadius: CGFloat = 14
    static let keycapSize: CGFloat = 18
    static let keycapRadius: CGFloat = 5
    static let chipHeight: CGFloat = 18
    static let chipRadius: CGFloat = 9
    static let backSize: CGFloat = 24
    static let titleLeading: CGFloat = 34
    static let contentInset: CGFloat = 10
    static let navToContent: CGFloat = 12
    static let chipToQuestion: CGFloat = 8
    static let questionToOptions: CGFloat = 12
    static let optionGap: CGFloat = 6
    static let optionsToField: CGFloat = 6
    static let contentToFooter: CGFloat = 12
    static let bottomPadding: CGFloat = 10
    static let fieldMaxLines = 5
    static let slideOffset: CGFloat = 12
    static let autoReturn: Duration = .milliseconds(1200)
    /// Text replies ask at the end, so show only the tail (design §6 implementation starting point).
    static let messageTailLines = 12
    static let messageTailCharacters = 600
    static let messageMaxHeight: CGFloat = 182
    static let messageFade: CGFloat = 34
}

/// Reply fills/strokes; reserve color for states, selections, and primary actions (design §4.8).
enum ReplyPalette {
    static let accent = Color(nsColor: .systemBlue)
    static let failed = Color(nsColor: .systemRed)

    static func fill(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.07 : 0.045)
    }

    static func strongFill(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.11 : 0.075)
    }

    /// Recessed input-field surface.
    static func well(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.62)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.16 : 0.12)
    }
}
