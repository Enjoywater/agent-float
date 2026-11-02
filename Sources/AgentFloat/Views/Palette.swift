import AgentFloatCore
import AppKit
import SwiftUI

/// System colors represent status and alerts; AgentBadge names/backgrounds distinguish agents.
enum Palette {
    static let running = Color(nsColor: .systemBlue)
    static let waiting = Color(nsColor: .systemOrange)
    static let done = Color(nsColor: .systemGreen)
    static let gray = Color(nsColor: .systemGray)

    // Use darker orange/green text in light mode to improve contrast on glass.
    private static let askLight = NSColor(srgbRed: 0xC9 / 255, green: 0x34 / 255, blue: 0, alpha: 1)
    private static let newLight = NSColor(srgbRed: 0x24 / 255, green: 0x8A / 255, blue: 0x3D / 255, alpha: 1)
    static let askText = Color(nsColor: dynamic(light: askLight, dark: .systemOrange))
    static let failed = Color(nsColor: .systemRed)
    // Use a darker related red for light-mode text contrast on glass.
    private static let failLight = NSColor(srgbRed: 0xD7 / 255, green: 0, blue: 0x15 / 255, alpha: 1)
    static let failText = Color(nsColor: dynamic(light: failLight, dark: .systemRed))
    static let newText = Color(nsColor: dynamic(light: newLight, dark: .systemGreen))

    /// Dynamic colors can resolve to the glass tone instead of SwiftUI's override and disappear into an inverse-painted pill.
    /// When painted, pin colors to the painted tone.
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
