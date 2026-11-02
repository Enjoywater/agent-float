import AgentFloatCore
import AppKit
import Observation
import SwiftUI

/// Side-card rendering state; animate appearance inside SwiftUI after opening the window.
@MainActor @Observable
final class ReplyCardState {
    var isShown = false
    var height: CGFloat = 0
    var glassContrast = GlassContrast.outline
    @ObservationIgnored var actions = ReplyActions()
}

/// A second glass window sharing panel level/Space behavior; it receives keyboard input while replying (v1.2 design §4.5 B).
@MainActor
final class ReplyCardController {
    static let padding: CGFloat = 6
    /// Animate appearance scale and opacity: 0.96 to 1 over 0.22 seconds (design §4.5 B).
    static let appear = Animation.easeOut(duration: 0.22)

    let panel: FloatingPanel
    private let state = ReplyCardState()
    private let replies: ReplyCenter

    init(replies: ReplyCenter) {
        self.replies = replies
        panel = FloatingPanel(contentRect: CGRect(x: 0, y: 0, width: ReplyLayout.width, height: 100))
        let host = PanelHostingView(rootView: ReplyCardView(center: replies, state: state))
        host.sizingOptions = []
        panel.contentView = host
    }

    var isVisible: Bool { panel.isVisible }

    func setContrast(_ contrast: GlassContrast) {
        state.glassContrast = contrast
    }

    /// Adjacent windows likely share a background, so reuse the main glass's sampled tone.
    /// Otherwise the card stays system-dark beside a light panel over a white background.
    func setTone(_ tone: GlassTone) {
        panel.appearance = tone.appearance
    }

    func show(frame: CGRect, actions: ReplyActions, reduced: Bool) {
        state.actions = actions
        state.height = frame.height - Self.padding * 2
        let wasVisible = panel.isVisible
        panel.setFrame(frame, display: true, animate: false)
        guard !wasVisible else { return }
        state.isShown = false
        panel.orderFrontRegardless()
        withAnimation(reduced ? Motion.crossfade : Self.appear) { state.isShown = true }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.acceptsKeyInput = false
        state.isShown = false
        panel.orderOut(nil)
    }

    /// Measure card content offscreen using the same approach as the panel.
    func measureHeight(for session: AgentSession) -> CGFloat {
        let measurer = NSHostingView(rootView: ReplyCardMeasure(center: replies, session: session))
        return ceil(measurer.fittingSize.height) + Self.padding * 2
    }
}

private struct ReplyCardView: View {
    let center: ReplyCenter
    let state: ReplyCardState

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var glassTone: GlassTone = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light

    var body: some View {
        let reduced = Motion.isReduced(systemReduceMotion)
        return surface
            .scaleEffect(state.isShown || reduced ? 1 : 0.96)
            .opacity(state.isShown ? 1 : 0)
    }

    private var surface: some View {
        let style = state.glassContrast.style(glass: glassTone)
        return Group {
            if let session = center.openSession {
                ReplyScreen(center: center, session: session, actions: state.actions, height: state.height, showsHeader: false)
            }
        }
        .transformEnvironment(\.colorScheme) { scheme in
            if let tone = style.contentTone { scheme = tone.colorScheme }
        }
        .environment(\.paintedGlassTone, style.contentTone)
        .modifier(PaintedText(tone: style.contentTone))
        .padding(ReplyCardController.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if let fill = style.fill { RoundedRectangle(cornerRadius: Layout.panelCornerRadius).fill(fill.surfaceFill) }
        }
        .background(GlassToneProbe { tone in glassTone = tone })
        .clipShape(RoundedRectangle(cornerRadius: Layout.panelCornerRadius))
        .overlay {
            if let outline = style.outline {
                RoundedRectangle(cornerRadius: Layout.panelCornerRadius).strokeBorder(outline.outlineColor, lineWidth: 1)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: Layout.panelCornerRadius))
    }
}

private struct ReplyCardMeasure: View {
    let center: ReplyCenter
    let session: AgentSession

    var body: some View {
        ReplyScreen(center: center, session: session, actions: ReplyActions(), height: nil, showsHeader: false)
            .frame(width: ReplyLayout.width - ReplyCardController.padding * 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
