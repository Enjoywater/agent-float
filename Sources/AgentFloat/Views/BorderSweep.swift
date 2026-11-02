import AgentFloatCore
import AppKit
import QuartzCore
import SwiftUI

/// The border means something needs attention; ASK/NEW specifies what (spec §4.6).
/// Use label color for white in dark mode and dark ink in light mode, preserving contrast (light-border.html A).
struct BorderSweep: View {
    /// At half-height the shape becomes a capsule; share the glass radius so the border follows its morph.
    let cornerRadius: CGFloat
    /// Inset from the edge so inverse-tone pill highlights do not blend into the background.
    var inset: CGFloat = 0
    /// Contrast with a painted pill; nil follows the glass's sampled tone.
    var tone: GlassTone?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        Group {
            if Motion.isReduced(systemReduceMotion) {
                // A stationary highlight has no passing sweep to attract attention, so increase its intensity.
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

/// Updating SwiftUI angles each frame redraws continuously and measured 5–10% CPU.
/// NEW can remain for hours; run rotation through Core Animation in the render server.
private struct SweepLayer: NSViewRepresentable, Animatable {
    nonisolated var cornerRadius: CGFloat
    let inset: CGFloat
    let tone: GlassTone?

    // Interpolate the border path with the glass radius during the spring.
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
        // SwiftUI colorScheme does not reach this layer; set AppKit appearance explicitly or inherit the glass tone.
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

    /// Match the CSS draft stops: conic-gradient(transparent 0 66%, label 35% 80%, label 86%, transparent 96%).
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
        // Center a diagonal-sized square so rotation never exposes empty corners.
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        mask.frame = bounds
        // Inset by half the stroke width to keep the full line inside, like strokeBorder.
        let offset = inset + Layout.borderWidth / 2
        let path = bounds.insetBy(dx: offset, dy: offset)
        let radius = min(max(0, cornerRadius - offset), path.width / 2, path.height / 2)
        mask.path = CGPath(roundedRect: path, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }

    /// SwiftUI allowsHitTesting(false) does not guarantee AppKit hitTest behavior.
    /// Reject clicks explicitly so the highlight cannot disable dragging or row selection.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// Core Animation drops repeating animations when a window leaves the screen; reinstall on return.
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
        // Layer coordinates increase upward, so negative rotation is clockwise, matching the draft.
        spin.toValue = -2 * Double.pi
        spin.duration = Motion.sweepPeriod
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.isRemovedOnCompletion = false
        gradient.add(spin, forKey: "spin")
    }
}
