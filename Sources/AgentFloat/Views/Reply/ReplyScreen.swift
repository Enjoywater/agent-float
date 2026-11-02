import AgentFloatCore
import SwiftUI

/// Panel-provided actions own window sizing, keyboard handling, and navigation.
struct ReplyActions {
    var back: () -> Void = {}
    var primary: () -> Void = {}
    var openTerminal: () -> Void = {}
    var close: () -> Void = {}
    var recheck: () -> Void = {}
    var openSettings: () -> Void = {}
    var editQuestion: (Int) -> Void = { _ in }
    /// Actual rendered content height corrects offscreen undermeasurement of large line spacing.
    var contentHeight: (CGFloat) -> Void = { _ in }
}

private struct ReplyContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Panel replacement C: navigation, metadata, content, and buttons (design §4.8, drafts 1–10).
struct ReplyScreen: View {
    let center: ReplyCenter
    let session: AgentSession
    let actions: ReplyActions
    /// Nil means measuring; lay out all content without scrolling.
    let height: CGFloat?
    /// The side card's selected row already shows its title; display only the agent badge here.
    var showsHeader = true

    static let compactHeaderHeight: CGFloat = AgentBadge.height + 10
    private var headerHeight: CGFloat { showsHeader ? ReplyHeader.height : Self.compactHeaderHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                ReplyHeader(session: session, isLocked: isSending, onBack: actions.back)
            } else {
                HStack {
                    AgentBadge(session: session)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, ReplyLayout.contentInset)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
            if let height {
                // Scroll only content while keeping buttons fixed (design §4.8 height).
                ScrollView(.vertical) {
                    content.background(GeometryReader { proxy in
                        Color.clear.preference(key: ReplyContentHeightKey.self, value: proxy.size.height)
                    })
                }
                    .scrollBounceBehavior(.basedOnSize)
                    .onPreferenceChange(ReplyContentHeightKey.self) { actions.contentHeight($0) }
                    .frame(maxHeight: .infinity)
                    .frame(height: max(0, height - headerHeight - ReplyFooter.height))
            } else {
                content
            }
            ReplyFooter(center: center, session: session, actions: actions)
        }
    }

    private var isSending: Bool {
        if case .sending = center.phase { return true }
        return false
    }

    private var content: some View {
        ReplyContent(center: center, session: session, actions: actions)
            .padding(.horizontal, ReplyLayout.contentInset)
            .padding(.top, ReplyLayout.navToContent)
    }
}

/// Back chevron/title/elapsed time, then app/folder/reason; chevron 24×24, text starts at 34.
struct ReplyHeader: View {
    /// Navigation row: top 6 + 24; metadata: top 1 + 14.
    static let height: CGFloat = 45

    let session: AgentSession
    let isLocked: Bool
    let onBack: () -> Void

    @Environment(\.colorScheme) private var scheme
    private static let home = NSHomeDirectory()

    var body: some View {
        TimelineView(.periodic(from: .now, by: Motion.labelTick)) { context in
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ReplyPalette.accent)
                            .frame(width: ReplyLayout.backSize, height: ReplyLayout.backSize)
                            .background(ReplyPalette.fill(scheme), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLocked)
                    .opacity(isLocked ? 0.4 : 1)
                    .accessibilityLabel(LanguageSettings.shared.strings.reply.backToList)
                    Text(session.title.isEmpty ? LanguageSettings.shared.strings.untitled : session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(Labels.elapsed(context.date.timeIntervalSince(session.statusSince)))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                .padding(.top, 6)
                .padding(.leading, ReplyLayout.titleLeading - ReplyLayout.backSize - 6)
                .padding(.trailing, ReplyLayout.contentInset)
                HStack(spacing: 5) {
                    AgentBadge(session: session)
                    if let icon = AppIcons.icon(for: session.terminalApp) {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 12, height: 12).fixedSize()
                    }
                    Text(detail).lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(height: 14)
                .padding(.leading, ReplyLayout.titleLeading)
                .padding(.trailing, ReplyLayout.contentInset)
            }
        }
    }

    private var detail: String {
        var parts = [Labels.folder(cwd: session.cwd, home: Self.home)]
        if session.status == .waiting, let reason = session.waitReason { parts.append(LanguageSettings.shared.strings.waitReason(reason)) }
        return parts.joined(separator: " · ")
    }
}

/// Secondary action left, primary capsule right: height 28, radius 14, Return hint.
struct ReplyFooter: View {
    /// Top 12 + button 28 + bottom 10.
    static let height: CGFloat = 50

    let center: ReplyCenter
    let session: AgentSession
    let actions: ReplyActions
    /// Inline placement delegates horizontal padding to its outer container.
    var insetsHorizontally = true

    var body: some View {
        HStack(spacing: 8) {
            if let secondary {
                Button(secondary.title, action: secondary.action)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .disabled(!secondary.isEnabled)
                    .opacity(secondary.isEnabled ? 1 : 0.4)
            }
            Spacer(minLength: 0)
            PrimaryButton(model: primary, action: actions.primary)
        }
        .padding(.top, ReplyLayout.contentToFooter)
        .padding(.horizontal, insetsHorizontally ? ReplyLayout.contentInset : 0)
        .padding(.bottom, ReplyLayout.bottomPadding)
    }

    private struct Secondary {
        let title: String
        let action: () -> Void
        var isEnabled = true
    }

    private var readOnly: ReadOnlyReason? {
        if case let .readOnly(reason)? = center.availability[session.key] { return reason }
        return nil
    }

    private var secondary: Secondary? {
        switch center.phase {
        case .sending:
            return Secondary(title: LanguageSettings.shared.strings.reply.openTerminal, action: {}, isEnabled: false)
        case let .result(outcome):
            switch outcome {
            case .delivered, .notSent(.alreadyAnswered), .notSent(.sessionEnded): return nil
            case .notSent: return Secondary(title: LanguageSettings.shared.strings.reply.recheck, action: actions.recheck)
            case .stopped, .mismatched: return Secondary(title: LanguageSettings.shared.strings.reply.close, action: actions.close)
            }
        case .editing:
            if readOnly == .accessibilityNeeded { return Secondary(title: LanguageSettings.shared.strings.reply.openSettings, action: actions.openSettings) }
            if readOnly != nil { return nil }
            return Secondary(title: LanguageSettings.shared.strings.reply.openTerminal, action: actions.openTerminal)
        }
    }

    private var primary: PrimaryButton.Model {
        switch center.phase {
        case .sending:
            return PrimaryButton.Model(title: LanguageSettings.shared.strings.sending, style: .accent, isEnabled: false, showsSpinner: true)
        case let .result(outcome):
            switch outcome {
            case .delivered, .notSent(.alreadyAnswered), .notSent(.sessionEnded):
                return PrimaryButton.Model(title: LanguageSettings.shared.strings.reply.backToList, style: .neutral)
            case .notSent, .stopped, .mismatched:
                return PrimaryButton.Model(title: LanguageSettings.shared.strings.reply.openTerminal, style: .accent)
            }
        case .editing:
            if readOnly != nil { return PrimaryButton.Model(title: LanguageSettings.shared.strings.reply.openTerminal, style: .accent) }
            switch center.editor?.primary ?? .disabled {
            case .send: return PrimaryButton.Model(title: LanguageSettings.shared.strings.reply.send, style: .accent)
            case .next: return PrimaryButton.Model(title: LanguageSettings.shared.strings.reply.next, style: .accent)
            case .disabled: return PrimaryButton.Model(title: LanguageSettings.shared.strings.reply.send, style: .accent, isEnabled: false)
            }
        }
    }
}

struct PrimaryButton: View {
    struct Model {
        enum Style {
            case accent, neutral
        }

        let title: String
        let style: Style
        var isEnabled = true
        var showsSpinner = false
    }

    let model: Model
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if model.showsSpinner { ProgressView().controlSize(.mini).tint(.white) }
                Text(model.title).font(.system(size: 13, weight: .semibold))
                if !model.showsSpinner { Text("⏎").font(.system(size: 11)).opacity(0.72) }
            }
            .foregroundStyle(model.style == .accent ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: ReplyLayout.buttonHeight)
            .background(background, in: RoundedRectangle(cornerRadius: ReplyLayout.buttonRadius))
        }
        .buttonStyle(.plain)
        .disabled(!model.isEnabled)
        .opacity(model.isEnabled ? 1 : 0.35)
    }

    private var background: Color {
        model.style == .accent ? ReplyPalette.accent : ReplyPalette.strongFill(scheme)
    }
}

/// Measure the same unscrolled reply content before expansion.
struct ReplyMeasure: View {
    let center: ReplyCenter
    let session: AgentSession

    var body: some View {
        ReplyScreen(center: center, session: session, actions: ReplyActions(), height: nil)
            .frame(width: ReplyLayout.width - Layout.panelPadding * 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
