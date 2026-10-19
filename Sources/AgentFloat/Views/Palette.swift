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
    static let askText = Color(nsColor: dynamic(light: NSColor(srgbRed: 0xC9 / 255, green: 0x34 / 255, blue: 0, alpha: 1), dark: .systemOrange))
    static let newText = Color(nsColor: dynamic(light: NSColor(srgbRed: 0x24 / 255, green: 0x8A / 255, blue: 0x3D / 255, alpha: 1), dark: .systemGreen))

    static func dot(for status: AgentStatus) -> Color {
        switch status {
        case .waiting: waiting
        case .running: running
        case .done: done
        case .unknown: gray
        }
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
