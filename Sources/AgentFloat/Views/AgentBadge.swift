import AgentFloatCore
import SwiftUI

/// Identify the agent between status and terminal icons, consistently in lists and replies.
struct AgentBadge: View {
    static let height: CGFloat = 14

    let session: AgentSession

    @Environment(\.colorScheme) private var scheme
    @Environment(\.paintedGlassTone) private var paintedTone
    @Environment(\.colorSchemeContrast) private var contrast

    private enum Identity {
        case claude, codex, other
    }

    private var identity: Identity {
        switch session.key.providerId {
        case "claude-code": return .claude
        case "codex": return .codex
        default:
            // Render fake providers with the same agent identities as real sessions.
            switch session.agentName.lowercased() {
            case "claude": return .claude
            case "codex": return .codex
            default: return .other
            }
        }
    }

    private var name: String {
        switch identity {
        case .claude: "Claude"
        case .codex: "Codex"
        case .other: session.agentName.isEmpty ? "Agent" : session.agentName
        }
    }

    private var isDark: Bool { paintedTone.map { $0 == .dark } ?? (scheme == .dark) }

    private var foreground: Color {
        switch identity {
        case .claude: isDark ? Self.color(0xEDC0A4) : Self.color(0x80513A)
        case .codex: isDark ? Self.color(0xD3DDD1) : Self.color(0x3B4740)
        case .other: isDark ? Self.color(0xDFDFDF) : Self.color(0x4B4B4B)
        }
    }

    private var fill: Color {
        switch identity {
        case .claude: isDark ? Self.color(0x49392F) : Self.color(0xF3E7DF)
        case .codex: isDark ? Self.color(0x344237) : Self.color(0xE6E9E5)
        case .other: isDark ? Self.color(0x383838) : Self.color(0xE9E9E9)
        }
    }

    var body: some View {
        Text(name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: Self.height)
            .background(fill, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(foreground.opacity(contrast == .increased ? 0.5 : 0.18), lineWidth: 0.5)
            }
            .fixedSize()
            .layoutPriority(1)
            .accessibilityLabel(LanguageSettings.shared.strings.agentName(name))
            .help(LanguageSettings.shared.strings.agentName(name))
    }

    private static func color(_ rgb: UInt32) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}
