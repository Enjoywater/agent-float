import CoreGraphics

/// Glass tone follows background brightness independently of system appearance (measured 2026-10-19).
public enum GlassTone: Sendable, Equatable {
    case light, dark

    public var opposite: GlassTone {
        switch self {
        case .light: .dark
        case .dark: .light
        }
    }
}

/// Glass matches the background tone, preserving text but hiding light-on-light or dark-on-dark pill edges.
/// Let users choose how to handle that lost boundary.
public enum GlassContrast: String, CaseIterable, Sendable {
    /// Preserve the system glass appearance.
    case standard
    /// Outline glass with a thin contrasting border.
    case outline
    /// Paint a contrasting surface over glass to invert the pill relative to its background.
    case inverse

    public func style(glass: GlassTone) -> SurfaceStyle {
        switch self {
        case .standard:
            SurfaceStyle(fill: nil, contentTone: nil, outline: nil, sweepInset: 0)
        case .outline:
            SurfaceStyle(fill: nil, contentTone: nil, outline: glass.opposite, sweepInset: 0)
        case .inverse:
            SurfaceStyle(fill: glass.opposite, contentTone: glass.opposite, outline: nil, sweepInset: SurfaceStyle.inverseSweepInset)
        }
    }

    /// Development overrides outrank saved preferences; ignore unknown values.
    /// Default to Outline: all seven backgrounds preserve the pill boundary without changing glass or border animation.
    /// Inverse mode can place a light pill on white when text makes glass dark, so it is not the default (R54).
    public static func resolve(override: String?, saved: String?) -> GlassContrast {
        override.flatMap(GlassContrast.init(rawValue:)) ?? saved.flatMap(GlassContrast.init(rawValue:)) ?? .outline
    }
}

public struct SurfaceStyle: Equatable, Sendable {
    /// An inverse pill's edge highlight can match the outer background and disappear.
    /// Inset the highlight, leaving a strip of pill color between it and the background.
    public static let inverseSweepInset: CGFloat = 2

    /// Painted surface tone; nil preserves glass.
    public let fill: GlassTone?
    /// Text/dot tone; nil follows the glass's chosen tone.
    public let contentTone: GlassTone?
    /// Outline tone; nil omits the outline.
    public let outline: GlassTone?
    public let sweepInset: CGFloat

    public init(fill: GlassTone?, contentTone: GlassTone?, outline: GlassTone?, sweepInset: CGFloat) {
        self.fill = fill
        self.contentTone = contentTone
        self.outline = outline
        self.sweepInset = sweepInset
    }
}
