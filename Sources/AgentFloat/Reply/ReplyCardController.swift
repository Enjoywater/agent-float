import AgentFloatCore
import AppKit
import Observation
import SwiftUI

/// 옆 카드(B)가 그리는 데 필요한 값. 나타나는 전환은 창을 띄운 뒤 SwiftUI 안에서만 일어난다
@MainActor @Observable
final class ReplyCardState {
    var isShown = false
    var height: CGFloat = 0
    var glassContrast = GlassContrast.outline
    @ObservationIgnored var actions = ReplyActions()
}

/// 패널 옆에 뜨는 두 번째 유리 창. 패널과 같은 레벨·데스크탑 동작을 쓰고, 답하는 동안 키 입력은 이 창이 받는다 (v1.2 설계 4.5 B)
@MainActor
final class ReplyCardController {
    static let padding: CGFloat = 6
    /// 나타날 때 크기·투명도 전환 (설계 4.5 B: 0.96 → 1, 0.22초)
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

    /// 카드는 패널 바로 옆이라 뒤 화면도 비슷하다고 보고 메인 유리의 톤을 그대로 쓴다.
    /// 그대로 두면 시스템 설정 톤에 고정돼 흰 화면 위에서도 어두운 카드가 밝은 패널 옆에 남는다(실측)
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

    /// 카드 안 내용의 높이. 패널과 같은 방식으로 화면 밖에서 잰다
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
