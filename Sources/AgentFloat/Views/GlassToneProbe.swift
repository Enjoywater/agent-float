import AgentFloatCore
import AppKit
import SwiftUI

/// Report the tone chosen by glass from its background.
/// SwiftUI colorScheme stays system-bound; only AppKit views inside glass become VibrantLight/VibrantDark (measured 2026-10-19).
/// Mount outside tone-inverted content to avoid reading the inverted tone and creating flicker.
struct GlassToneProbe: NSViewRepresentable {
    let onChange: (GlassTone) -> Void

    func makeNSView(context: Context) -> GlassToneProbeView {
        GlassToneProbeView(onChange: onChange)
    }

    func updateNSView(_ view: GlassToneProbeView, context: Context) {
        view.onChange = onChange
    }
}

final class GlassToneProbeView: NSView {
    var onChange: (GlassTone) -> Void
    private var reported: GlassTone?

    init(onChange: @escaping (GlassTone) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Reject clicks for the same reason as BorderSweep.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        report()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        report()
    }

    private func report() {
        guard window != nil else { return }
        let tone: GlassTone = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        guard tone != reported else { return }
        reported = tone
        DebugLog.write("glass tone=\(tone) appearance=\(effectiveAppearance.name.rawValue)")
        // Callbacks may occur during layout; defer SwiftUI state updates to the next turn.
        DispatchQueue.main.async { [onChange] in onChange(tone) }
    }
}

extension EnvironmentValues {
    /// The painted pill tone; Palette reads it because dynamic colors cannot infer it.
    @Entry var paintedGlassTone: GlassTone?
}

extension GlassTone {
    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }

    /// A 50% black tint lost against glass adapting to white backgrounds; stronger tint is required for inversion.
    var surfaceFill: Color {
        switch self {
        case .light: Color.white.opacity(0.8)
        case .dark: Color.black.opacity(0.7)
        }
    }

    /// Overriding with the system tone does not change colorScheme, leaving glass-selected text colors unchanged.
    /// Set the painted surface's text color directly and derive secondary/tertiary opacity from it.
    var textColor: Color {
        switch self {
        case .light: Color.black.opacity(0.85)
        case .dark: Color.white.opacity(0.85)
        }
    }

    var outlineColor: Color {
        switch self {
        case .light: Color.white.opacity(0.35)
        case .dark: Color.black.opacity(0.28)
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
