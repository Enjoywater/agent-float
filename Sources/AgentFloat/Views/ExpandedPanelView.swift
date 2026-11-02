import AgentFloatCore
import SwiftUI

/// Content below the expanded summary; PanelController supplies the maximum height with window sizing.
struct ExpandedPanelView: View {
    let groups: [SessionGroup]
    var failed: [AgentSession] = []
    let unseen: Set<SessionKey>
    let listHeight: CGFloat
    let canNavigate: (AgentSession) -> Bool
    let onActivate: (AgentSession) -> Void
    var note: (AgentSession) -> RowNote? = { _ in nil }
    var inline: InlineReply? = nil
    var selectedKey: SessionKey? = nil

    var body: some View {
        // Use a separate minute clock only while expanded, preserving collapsed idle CPU.
        TimelineView(.periodic(from: .now, by: Motion.labelTick)) { context in
            ScrollView(.vertical) {
                SessionListContent(groups: groups, failed: failed, unseen: unseen, now: context.date, canNavigate: canNavigate, onActivate: onActivate, note: note, inline: inline, selectedKey: selectedKey)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: listHeight)
        }
    }
}

/// Row positions in panel-surface coordinates align the side card to its selected row (design §4.5 B).
struct RowFrameKey: PreferenceKey {
    static let space = "panelSurface"
    static let defaultValue: [SessionKey: CGRect] = [:]

    static func reduce(value: inout [SessionKey: CGRect], nextValue: () -> [SessionKey: CGRect]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

/// Use the same unscrolled list to measure before expansion so glass and window reach their target together.
struct SessionListContent: View {
    let groups: [SessionGroup]
    var failed: [AgentSession] = []
    let unseen: Set<SessionKey>
    let now: Date
    let canNavigate: (AgentSession) -> Bool
    let onActivate: (AgentSession) -> Void
    var note: (AgentSession) -> RowNote? = { _ in nil }
    var inline: InlineReply? = nil
    var selectedKey: SessionKey? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !failed.isEmpty {
                header(LanguageSettings.shared.strings.reply.needsReview, count: failed.count)
                    .foregroundStyle(Palette.failText(on: paintedTone))
                rows(failed)
            }
            ForEach(groups, id: \.status) { group in
                header(Self.title(of: group.status), count: group.sessions.count)
                    .foregroundStyle(.secondary)
                rows(group.sessions)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @Environment(\.paintedGlassTone) private var paintedTone

    private func header(_ title: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text("\(count)").monospacedDigit()
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.top, 8)
        .padding(.horizontal, 10)
        .padding(.bottom, 3)
    }

    /// Separate highlighted rows so waiting and hovered backgrounds do not merge visually.
    private func rows(_ sessions: [AgentSession]) -> some View {
        VStack(alignment: .leading, spacing: Layout.rowGap) {
            ForEach(sessions) { session in
                if let inline, inline.center.openKey == session.key {
                    InlineReplyRow(session: session, inline: inline, now: now, onHeaderTap: inline.actions.back)
                } else {
                    SessionRow(
                        session: session,
                        isUnseen: unseen.contains(session.key),
                        canNavigate: canNavigate(session),
                        now: now,
                        onActivate: { onActivate(session) },
                        note: note(session),
                        isSelected: session.key == selectedKey
                    )
                    // Side-card alignment requires this row's onscreen position.
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: RowFrameKey.self, value: [session.key: proxy.frame(in: .named(RowFrameKey.space))])
                    })
                    // Dim other rows while one is open to keep attention on the selected row (design §4.5 A).
                    .opacity(inline?.center.openKey == nil ? 1 : 0.55)
                }
            }
        }
    }

    static func title(of status: AgentStatus) -> String {
        switch status {
        case .waiting: LanguageSettings.shared.strings.waiting
        case .running: LanguageSettings.shared.strings.running
        case .done: LanguageSettings.shared.strings.done
        case .unknown: LanguageSettings.shared.strings.unknown
        }
    }
}
