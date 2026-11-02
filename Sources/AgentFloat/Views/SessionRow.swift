import AgentFloatCore
import Foundation
import SwiftUI

/// Drafts and send failures override waiting reasons on the second row (v1.2 design §§4.6–4.7).
enum RowNote: Equatable {
    case drafting, failed
}

struct SessionRow: View {
    let session: AgentSession
    let isUnseen: Bool
    let canNavigate: Bool
    let now: Date
    let onActivate: () -> Void
    var note: RowNote? = nil
    /// The expanded inline row's outer container paints its background; avoid double painting.
    var showsBackground = true
    /// This row owns the side-card reply: stronger orange and 1pt border (design §4.5 B).
    var isSelected = false

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.paintedGlassTone) private var paintedTone

    private static let home = NSHomeDirectory()

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                detailLine
            }
            Spacer(minLength: 0)
            Text(Labels.elapsed(now.timeIntervalSince(session.statusSince)))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
                .padding(.top, 2)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background {
            // Overlay hover on waiting orange so the waiting state remains visible.
            if showsBackground {
                ZStack {
                    RoundedRectangle(cornerRadius: Layout.rowCornerRadius).fill(isSelected ? Palette.waiting.opacity(0.26) : statusTint)
                    RoundedRectangle(cornerRadius: Layout.rowCornerRadius).fill(hoverTint)
                    if isSelected {
                        RoundedRectangle(cornerRadius: Layout.rowCornerRadius).strokeBorder(Palette.waiting.opacity(0.55), lineWidth: 1)
                    }
                }
            }
        }
        .opacity(isSeenDone ? 0.62 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Layout.rowCornerRadius))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onActivate)
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(session.title.isEmpty ? LanguageSettings.shared.strings.untitled : session.title)
                .font(.system(size: 13, weight: isUnseen ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if isUnseen {
                Text("NEW")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.3)
                    .foregroundStyle(Palette.newText(on: paintedTone))
                    .padding(.vertical, 1.5)
                    .padding(.horizontal, 6)
                    .background(Palette.done.opacity(colorScheme == .dark ? 0.2 : 0.18), in: Capsule())
                    .fixedSize()
            }
        }
    }

    private var detailLine: some View {
        HStack(spacing: 5) {
            AgentBadge(session: session)
            if let icon = AppIcons.icon(for: session.terminalApp) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 12, height: 12)
                    .fixedSize()
                    .accessibilityLabel(terminalLabel)
            }
            detailText
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var terminalLabel: String {
        switch session.terminalApp {
        case .ghostty: LanguageSettings.shared.strings.terminalName("Ghostty")
        case .herdr: LanguageSettings.shared.strings.terminalName("Herdr")
        case .orca: LanguageSettings.shared.strings.terminalName("Orca")
        case let .other(name): LanguageSettings.shared.strings.terminalName(name)
        case .unknown: LanguageSettings.shared.strings.terminal
        }
    }

    private var detailText: Text {
        guard let note else { return Text(detail) }
        let base = Labels.folder(cwd: session.cwd, home: Self.home)
        switch note {
        case .drafting:
            return Text("\(base) · \(Text(LanguageSettings.shared.strings.reply.drafting).foregroundColor(ReplyPalette.accent).fontWeight(.semibold))")
        case .failed:
            return Text("\(base) · \(Text(LanguageSettings.shared.strings.reply.deliveryFailed).foregroundColor(ReplyPalette.failed).fontWeight(.semibold))")
        }
    }

    private var detail: String {
        var parts = [Labels.folder(cwd: session.cwd, home: Self.home)]
        if let reason = session.waitReason, session.status == .waiting {
            parts.append(LanguageSettings.shared.strings.waitReason(reason))
        }
        if session.isStale {
            parts.append(LanguageSettings.shared.strings.inactivity(Labels.inactivityMinutes(since: session.lastActivityAt ?? session.statusSince, now: now)))
        }
        return parts.joined(separator: " · ")
    }

    // Suspected unresponsiveness stays gray even while running to avoid implying active work (spec §4.7).
    private var dotColor: Color {
        session.isStale ? Palette.gray : Palette.dot(for: session.status)
    }

    private var isSeenDone: Bool {
        session.status == .done && !isUnseen
    }

    private var statusTint: Color {
        guard session.status == .waiting else { return .clear }
        return Palette.waiting.opacity(colorScheme == .dark ? 0.14 : 0.12)
    }

    // Do not highlight rows without destinations; that would imply navigation is available.
    private var hoverTint: Color {
        guard isHovered, canNavigate else { return .clear }
        return Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06)
    }
}
