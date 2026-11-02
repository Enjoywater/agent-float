import AgentFloatCore
import AppKit
import SwiftUI

/// Centralize dimensions to preserve concentric corners: panel 22 minus padding 6 equals row 16 (spec §4.10).
enum Layout {
    static let pillHeight: CGFloat = 28
    static let pillPadding: CGFloat = 12
    static let headerPadding: CGFloat = 10
    static let panelWidth: CGFloat = 280
    static let panelPadding: CGFloat = 6
    static let panelCornerRadius: CGFloat = 22
    static let rowCornerRadius: CGFloat = 16
    static let rowGap: CGFloat = 4
    static let borderWidth: CGFloat = 1.5
    static let maxHeightRatio: CGFloat = 0.7

    static var listWidth: CGFloat { panelWidth - panelPadding * 2 }
    /// Expanded height excluding the list: vertical padding plus summary row.
    static var panelChromeHeight: CGFloat { panelPadding * 2 + pillHeight }
}

extension View {
    /// Use identical collapsed-pill dimensions for offscreen measurement and visible glass.
    func pillChrome() -> some View {
        padding(.horizontal, Layout.pillPadding).frame(height: Layout.pillHeight)
    }
}

struct FloatRootView: View {
    let model: AppModel
    let replies: ReplyCenter
    let presentation: PanelPresentation

    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Assume system appearance until the glass reports its sampled tone.
    @State private var glassTone: GlassTone = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light

    var body: some View {
        // Anchor content so the pill stays stationary while its window grows early or shrinks late.
        let corner: Alignment = presentation.anchorsTrailing ? .topTrailing : .topLeading
        Group {
            if Motion.isReduced(systemReduceMotion) {
                // Crossfade outside the container because the system joins appearing glass surfaces inside it.
                ZStack(alignment: corner) {
                    if presentation.isGlassExpanded {
                        surface(expanded: true).transition(.opacity)
                    } else {
                        surface(expanded: false).transition(.opacity)
                    }
                }
            } else {
                // Swapping collapsed/expanded views with one glassEffectID jumps directly to the target size.
                // Spring the size and radius of one glass surface for a continuous morph.
                GlassEffectContainer {
                    surface(expanded: presentation.isGlassExpanded)
                        .glassEffectID("float", in: glass)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
        .coordinateSpace(.named(RowFrameKey.space))
    }

    /// Morph capsule radius (half-height) to 22; reuse the summary view so it cannot slide during the transition.
    private func surface(expanded: Bool) -> some View {
        let radius = expanded ? Layout.panelCornerRadius : Layout.pillHeight / 2
        let style = presentation.glassContrast.style(glass: glassTone)
        return VStack(spacing: 0) {
            // Only the summary is a drag handle; making the list draggable would consume row clicks (spec §4.8).
            SummaryRow(summary: model.summary)
                // Pill width comes from this row's ideal width; prevent wrapping during narrow transition frames.
                .fixedSize()
                .padding(.horizontal, expanded ? Layout.headerPadding : Layout.pillPadding)
                .frame(maxWidth: .infinity, alignment: presentation.anchorsTrailing ? .trailing : .leading)
                .frame(height: Layout.pillHeight)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
            if expanded, presentation.isListVisible {
                expandedContent
            }
        }
        .transformEnvironment(\.colorScheme) { scheme in
            if let tone = style.contentTone { scheme = tone.colorScheme }
        }
        .environment(\.paintedGlassTone, style.contentTone)
        .modifier(PaintedText(tone: style.contentTone))
        .padding(expanded ? Layout.panelPadding : 0)
        .frame(
            width: expanded ? presentation.panelWidth : presentation.pillWidth,
            height: expanded ? presentation.panelHeight : Layout.pillHeight,
            alignment: .top
        )
        .background {
            if let fill = style.fill { RoundedRectangle(cornerRadius: radius).fill(fill.surfaceFill) }
        }
        // Read the glass tone outside the override above to avoid observing our own painted tone.
        .background(GlassToneProbe { tone in
            withAnimation(Motion.crossfade) { glassTone = tone }
            presentation.onGlassTone?(tone)
        })
        // Clip inner text while the glass shrinks.
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay {
            if let outline = style.outline {
                RoundedRectangle(cornerRadius: radius).strokeBorder(outline.outlineColor, lineWidth: 1)
            }
        }
        .overlay {
            if model.summary.attention { BorderSweep(cornerRadius: radius, inset: style.sweepInset, tone: style.contentTone) }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: radius))
    }

    /// Slide replies from the right and the list from the left, matching the back navigation direction (design §4.8).
    @ViewBuilder
    private var expandedContent: some View {
        let reduced = Motion.isReduced(systemReduceMotion)
        switch presentation.content {
        case .list:
            ExpandedPanelView(
                groups: model.groups,
                failed: model.failedSessions,
                unseen: model.unseen,
                listHeight: presentation.listHeight,
                canNavigate: canTap,
                onActivate: activate,
                note: note,
                inline: presentation.replyPlacement == .inline && replies.openKey != nil
                    ? InlineReply(center: replies, actions: presentation.replyActions) : nil,
                selectedKey: presentation.replyPlacement == .card ? replies.openKey : nil
            )
            .onPreferenceChange(RowFrameKey.self) { frames in presentation.rowFrames = frames }
            .transition(reduced ? .opacity : .asymmetric(
                insertion: .opacity.combined(with: .offset(x: -ReplyLayout.slideOffset)),
                removal: .opacity
            ))
        case .reply:
            if let session = replies.openSession {
                ReplyScreen(center: replies, session: session, actions: presentation.replyActions, height: presentation.listHeight)
                    .transition(reduced ? .opacity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(x: ReplyLayout.slideOffset)),
                        removal: .opacity.combined(with: .offset(x: ReplyLayout.slideOffset))
                    ))
            }
        }
    }

    /// A waiting row with a readable question opens read-only replies even without a locator; keep its click affordance.
    private func canTap(_ session: AgentSession) -> Bool {
        model.canNavigate(session) || Self.opensReply(session)
    }

    private func note(_ session: AgentSession) -> RowNote? {
        if model.failedKeys.contains(session.key) { return .failed }
        return replies.hasDraft(for: session) ? .drafting : nil
    }

    private static func opensReply(_ session: AgentSession) -> Bool {
        session.status == .waiting && session.prompt != nil
    }

    private func activate(_ session: AgentSession) {
        // Do not navigate when a drag ends over a row (spec §4.8).
        guard !presentation.isDragging else { return }
        // Command-click navigates directly as in v1 and acknowledges any failure (design §4.7).
        let commandHeld = NSEvent.modifierFlags.contains(.command)
        if !commandHeld, Self.opensReply(session) || model.failedKeys.contains(session.key) {
            presentation.openReply?(session)
            return
        }
        replies.acknowledgeFailure(session.key)
        Task { await model.activate(session) }
    }
}

/// Only changing contrast mode alters whether the tone override exists, preserving view identity otherwise.
struct PaintedText: ViewModifier {
    let tone: GlassTone?

    func body(content: Content) -> some View {
        if let tone {
            content.foregroundStyle(tone.textColor)
        } else {
            content
        }
    }
}
