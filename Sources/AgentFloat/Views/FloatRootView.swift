import AgentFloatCore
import AppKit
import SwiftUI

/// 동심 모서리(패널 22 − 여백 6 = 줄 16)를 지키려면 이 값들이 함께 움직여야 해서 한곳에 둔다 (spec 4.10)
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
    /// 목록을 뺀 펼친 패널 높이 (위아래 여백 + 요약 줄)
    static var panelChromeHeight: CGFloat { panelPadding * 2 + pillHeight }
}

extension View {
    /// 접힌 알약 모양. 화면 밖에서 크기를 잴 때도 같은 값을 써야 창 크기와 유리 크기가 맞는다
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
    /// 유리가 고른 톤이 들어오기 전 첫 화면은 시스템 설정과 같다고 본다
    @State private var glassTone: GlassTone = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light

    var body: some View {
        // 창이 먼저 커지거나 나중에 줄어드는 동안에도 알약이 화면상 제자리에 있도록 고정 모서리에 붙인다
        let corner: Alignment = presentation.anchorsTrailing ? .topTrailing : .topLeading
        Group {
            if Motion.isReduced(systemReduceMotion) {
                // 컨테이너 안에서는 나타나는 유리를 시스템이 이어 붙여 늘리므로(실측) 크로스페이드는 컨테이너 밖에서 한다
                ZStack(alignment: corner) {
                    if presentation.isGlassExpanded {
                        surface(expanded: true).transition(.opacity)
                    } else {
                        surface(expanded: false).transition(.opacity)
                    }
                }
            } else {
                // 같은 glassEffectID 로 접힘·펼침 뷰를 바꿔 끼우면 유리가 중간 없이 바로 목표 크기가 된다(실측, 보고서 참고).
                // 유리 하나의 크기·모서리를 spring 으로 바꿔야 같은 유리가 늘어나는 morph 가 된다
                GlassEffectContainer {
                    surface(expanded: presentation.isGlassExpanded)
                        .glassEffectID("float", in: glass)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
    }

    /// 접힘 = 캡슐(높이의 절반 반경), 펼침 = 반경 22 둥근 사각형. 요약 줄은 두 상태에서 같은 뷰라 morph 중에 미끄러지지 않는다
    private func surface(expanded: Bool) -> some View {
        let radius = expanded ? Layout.panelCornerRadius : Layout.pillHeight / 2
        let style = presentation.glassContrast.style(glass: glassTone)
        return VStack(spacing: 0) {
            // 끄는 손잡이는 요약 줄뿐이다. 목록까지 손잡이면 줄 클릭이 끌기로 먹힌다 (spec 4.8)
            SummaryRow(summary: model.summary)
                // 알약 폭은 이 줄의 이상적 폭으로 정해지므로 전환 중 좁은 폭을 받아도 줄바꿈하지 않게 한다
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
        // 위의 톤 덮어쓰기 바깥이어야 유리가 고른 톤 그대로를 읽는다
        .background(GlassToneProbe { tone in
            withAnimation(Motion.crossfade) { glassTone = tone }
        })
        // 유리가 줄어드는 동안 안쪽 글자가 유리 밖으로 삐져나오지 않게 한다
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

    /// 목록과 답장 화면은 옆으로 밀려 바뀐다. "‹ 목록"과 방향이 맞게 답장은 오른쪽에서, 목록은 왼쪽에서 들어온다 (설계 4.8 움직임)
    @ViewBuilder
    private var expandedContent: some View {
        let reduced = Motion.isReduced(systemReduceMotion)
        switch presentation.content {
        case .list:
            ExpandedPanelView(
                groups: model.groups,
                unseen: model.unseen,
                listHeight: presentation.listHeight,
                canNavigate: canTap,
                onActivate: activate,
                note: note
            )
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

    /// 질문을 읽은 대기 줄은 이동할 곳이 없어도(보기만) 답장 화면이 열리므로 눌리는 줄로 보여야 한다
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
        // 끈 뒤 손을 뗀 자리가 줄 위여도 이동하지 않는다 (spec 4.8)
        guard !presentation.isDragging else { return }
        // ⌘+클릭은 v1 처럼 바로 이동한다. 실패 표시는 그 세션을 직접 본 것이므로 끈다 (설계 4.7)
        let commandHeld = NSEvent.modifierFlags.contains(.command)
        if !commandHeld, Self.opensReply(session) || model.failedKeys.contains(session.key) {
            presentation.openReply?(session)
            return
        }
        replies.acknowledgeFailure(session.key)
        Task { await model.activate(session) }
    }
}

/// 모드를 바꿀 때만 톤이 생기거나 없어져, 그때 말고는 뷰 정체성이 바뀌지 않는다
private struct PaintedText: ViewModifier {
    let tone: GlassTone?

    func body(content: Content) -> some View {
        if let tone {
            content.foregroundStyle(tone.textColor)
        } else {
            content
        }
    }
}
