import AgentFloatCore
import AppKit
import QuartzCore
import SwiftUI

/// "봐야 할 게 있음" 하나만 뜻하는 테두리 빛. 무엇인지는 ASK·NEW 글자가 말한다 (spec 4.6).
/// 글자색(label)을 써야 다크에서는 흰빛, 라이트에서는 먹색으로 바뀌어 밝은 배경에서도 보인다 (light-border.html A안)
struct BorderSweep: View {
    /// 높이의 절반 이상이면 캡슐이 된다. 유리와 같은 값을 받아야 morph 중에도 빛이 유리 가장자리를 따른다
    let cornerRadius: CGFloat
    /// 가장자리에서 안쪽으로 들이는 거리. 알약을 뒤와 반대 톤으로 칠할 때 빛이 바깥 배경에 녹지 않게 한다
    var inset: CGFloat = 0
    /// 알약을 직접 칠했을 때 그 면과 대비되는 톤. nil 이면 유리가 고른 톤을 따른다
    var tone: GlassTone?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        Group {
            if Motion.isReduced(systemReduceMotion) {
                // 돌지 않으면 빛이 지나가는 순간이 없어 평소 밝기로는 눈에 덜 띄므로 더 진하게 둔다
                staticBorder
            } else {
                SweepLayer(cornerRadius: cornerRadius, inset: inset, tone: tone)
            }
        }
        .allowsHitTesting(false)
    }

    private var staticBorder: some View {
        RoundedRectangle(cornerRadius: max(0, cornerRadius - inset))
            .strokeBorder((tone?.textColor ?? Color.primary).opacity(0.7), lineWidth: Layout.borderWidth)
            .padding(inset)
    }
}

/// SwiftUI 로 각도를 매 프레임 바꾸면 앱이 계속 다시 그려 CPU 5~10%를 쓴다(실측).
/// NEW 는 확인할 때까지 몇 시간이고 켜져 있을 수 있어, 회전은 Core Animation 에 맡겨 앱 밖(렌더 서버)에서 돌게 한다
private struct SweepLayer: NSViewRepresentable, Animatable {
    nonisolated var cornerRadius: CGFloat
    let inset: CGFloat
    let tone: GlassTone?

    // 유리의 모서리 반경이 spring 으로 바뀌는 동안 빛의 경로도 같은 중간값을 받게 한다
    nonisolated var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func makeNSView(context: Context) -> SweepLayerView {
        let view = SweepLayerView(cornerRadius: cornerRadius)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SweepLayerView, context: Context) {
        view.cornerRadius = cornerRadius
        view.inset = inset
        // SwiftUI 의 colorScheme 은 이 레이어까지 오지 않아 AppKit 모양을 직접 정한다. nil 이면 유리가 고른 모양을 물려받는다
        let appearance = tone?.appearance
        if view.appearance != appearance { view.appearance = appearance }
    }
}

final class SweepLayerView: NSView {
    var cornerRadius: CGFloat {
        didSet { if cornerRadius != oldValue { needsLayout = true } }
    }
    var inset: CGFloat = 0 {
        didSet { if inset != oldValue { needsLayout = true } }
    }

    private let gradient = CAGradientLayer()
    private let mask = CAShapeLayer()

    /// CSS 시안 `conic-gradient(transparent 0 66%, label 35% 80%, label 86%, transparent 96%)` 과 같은 정지점
    private static let locations: [NSNumber] = [0, 0.66, 0.80, 0.86, 0.96, 1]
    private static let alphas: [CGFloat] = [0, 0, 0.35, 1, 0, 0]

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.locations = Self.locations
        layer?.addSublayer(gradient)

        mask.fillColor = nil
        mask.strokeColor = NSColor.black.cgColor
        mask.lineWidth = Layout.borderWidth
        layer?.mask = mask

        updateColors()
        startSpinning()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = self.bounds
        // 회전해도 모서리가 비지 않도록 대각선 길이의 정사각형을 가운데 둔다
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        mask.frame = bounds
        // strokeBorder 처럼 선 전체가 모양 안쪽에 들어오게 선 두께의 절반만큼 들인다
        let offset = inset + Layout.borderWidth / 2
        let path = bounds.insetBy(dx: offset, dy: offset)
        let radius = min(max(0, cornerRadius - offset), path.width / 2, path.height / 2)
        mask.path = CGPath(roundedRect: path, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }

    /// SwiftUI 의 allowsHitTesting(false) 는 AppKit 뷰의 hitTest 까지 보장하지 않는다.
    /// 빛이 켜진 동안 이 뷰가 클릭을 받으면 끌기와 줄 클릭이 먹통이 되므로 아예 받지 않는다
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// 창이 화면에서 내려갔다 다시 붙으면 Core Animation 이 반복 애니메이션을 떼어 내므로 다시 건다
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startSpinning()
    }

    private func updateColors() {
        var colors: [CGColor] = []
        effectiveAppearance.performAsCurrentDrawingAppearance {
            colors = Self.alphas.map { NSColor.labelColor.withAlphaComponent($0).cgColor }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = colors
        CATransaction.commit()
    }

    private func startSpinning() {
        guard gradient.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        // 화면 좌표가 위쪽으로 늘어나는 레이어라 음수 회전이 시계 방향이다 (시안과 같은 방향)
        spin.toValue = -2 * Double.pi
        spin.duration = Motion.sweepPeriod
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.isRemovedOnCompletion = false
        gradient.add(spin, forKey: "spin")
    }
}
