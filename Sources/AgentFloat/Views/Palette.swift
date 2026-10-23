import AgentFloatCore
import AppKit
import SwiftUI

/// 색은 상태 표시에만 쓰고 모두 시스템 색이라 라이트·다크·대비 증가 설정을 시스템이 맞춰 준다 (spec 4.10)
enum Palette {
    static let running = Color(nsColor: .systemBlue)
    static let waiting = Color(nsColor: .systemOrange)
    static let done = Color(nsColor: .systemGreen)
    static let gray = Color(nsColor: .systemGray)

    // 라이트 모드의 systemOrange·systemGreen 글자는 유리 위에서 대비가 낮아 같은 계열의 진한 톤으로 바꾼다
    private static let askLight = NSColor(srgbRed: 0xC9 / 255, green: 0x34 / 255, blue: 0, alpha: 1)
    private static let newLight = NSColor(srgbRed: 0x24 / 255, green: 0x8A / 255, blue: 0x3D / 255, alpha: 1)
    static let askText = Color(nsColor: dynamic(light: askLight, dark: .systemOrange))
    static let failed = Color(nsColor: .systemRed)
    // 라이트 모드의 systemRed 글자도 유리 위에서 옅어 같은 계열의 진한 톤을 쓴다
    private static let failLight = NSColor(srgbRed: 0xD7 / 255, green: 0, blue: 0x15 / 255, alpha: 1)
    static let failText = Color(nsColor: dynamic(light: failLight, dark: .systemRed))
    static let newText = Color(nsColor: dynamic(light: newLight, dark: .systemGreen))

    /// 알약을 뒤와 반대 톤으로 칠하면 동적 색이 SwiftUI 의 톤이 아니라 유리가 고른 톤으로 풀려 면과 같은 톤이 된다(실측).
    /// 칠한 톤이 있으면 그 톤의 색으로 고정한다
    static func askText(on painted: GlassTone?) -> Color {
        switch painted {
        case nil: askText
        case .light?: Color(nsColor: askLight)
        case .dark?: Color(nsColor: fixed(.systemOrange, in: .darkAqua))
        }
    }

    static func failText(on painted: GlassTone?) -> Color {
        switch painted {
        case nil: failText
        case .light?: Color(nsColor: failLight)
        case .dark?: Color(nsColor: fixed(.systemRed, in: .darkAqua))
        }
    }

    static func newText(on painted: GlassTone?) -> Color {
        switch painted {
        case nil: newText
        case .light?: Color(nsColor: newLight)
        case .dark?: Color(nsColor: fixed(.systemGreen, in: .darkAqua))
        }
    }

    static func dot(for status: AgentStatus) -> Color {
        switch status {
        case .waiting: waiting
        case .running: running
        case .done: done
        case .unknown: gray
        }
    }

    private static func fixed(_ color: NSColor, in name: NSAppearance.Name) -> NSColor {
        var resolved = color
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
