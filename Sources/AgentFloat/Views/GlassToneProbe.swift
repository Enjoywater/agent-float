import AgentFloatCore
import AppKit
import SwiftUI

/// 유리가 뒤 화면을 보고 고른 톤을 알려 준다.
/// SwiftUI 의 colorScheme 은 시스템 설정에 고정돼 있고, 유리 안의 AppKit 뷰만 VibrantLight·VibrantDark 로 바뀐다(2026-10-19 실측).
/// 톤을 뒤집어 칠하는 내용 아래에 두면 뒤집힌 톤을 다시 읽어 깜빡이므로, 반드시 그 바깥에 붙인다
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

    /// 빛과 같은 이유로 클릭을 받지 않는다 (BorderSweep 참고)
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
        // 레이아웃 도중에 불릴 수 있어 SwiftUI 상태는 다음 차례에 바꾼다
        DispatchQueue.main.async { [onChange] in onChange(tone) }
    }
}

extension EnvironmentValues {
    /// 알약을 직접 칠한 톤. 동적 색이 이 값을 모르므로 색을 고르는 쪽이 읽는다 (Palette)
    @Entry var paintedGlassTone: GlassTone?
}

extension GlassTone {
    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }

    /// 50% 검정 틴트는 흰 배경 위에서 유리가 도로 밝아져 이기지 못했다(실측). 그보다 진해야 반대 톤으로 보인다
    var surfaceFill: Color {
        switch self {
        case .light: Color.white.opacity(0.8)
        case .dark: Color.black.opacity(0.7)
        }
    }

    /// 시스템과 같은 톤으로 덮어쓰면 colorScheme 값이 바뀌지 않아 유리가 고른 글자색이 그대로 남는다(실측: 다크 모드에서 흰 배경 위 진한 면에 검은 글자).
    /// 칠한 면 위의 글자는 이 색으로 직접 정하고, secondary·tertiary 는 이 색을 기준으로 옅어진다
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
