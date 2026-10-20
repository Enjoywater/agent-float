import CoreGraphics

/// 유리가 뒤 화면 밝기를 보고 스스로 고른 톤. 시스템 다크·라이트 설정과는 따로 움직인다(2026-10-19 실측)
public enum GlassTone: Sendable, Equatable {
    case light, dark

    public var opposite: GlassTone {
        switch self {
        case .light: .dark
        case .dark: .light
        }
    }
}

/// 유리는 뒤와 같은 톤이 되어 글자는 읽히지만, 흰 화면 위 밝은 알약·어두운 에디터 위 어두운 알약은 가장자리가 사라진다.
/// 그 경우를 어떻게 다룰지 사용자가 고른다
public enum GlassContrast: String, CaseIterable, Sendable {
    /// 유리가 정한 대로 둔다
    case standard
    /// 유리 가장자리에 뒤와 반대 톤의 얇은 선을 둘러 뒤 화면과 갈라 놓는다
    case outline
    /// 유리 위에 뒤와 반대 톤의 면을 깔아 알약 자체를 뒤와 반대로 보이게 한다
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

    /// 개발용 환경 변수가 저장한 선택보다 앞선다. 모르는 값은 없는 것으로 본다.
    /// 고른 적이 없으면 윤곽선 — 일곱 가지 배경 모두에서 알약 윤곽이 남았고 유리 모양과 테두리 빛 동작은 그대로다.
    /// 반대 모드는 글자가 많은 흰 화면에서 유리가 스스로 어두워져 밝은 알약이 흰 화면 위에 놓이므로 기본으로 두지 않는다 (R54)
    public static func resolve(override: String?, saved: String?) -> GlassContrast {
        override.flatMap(GlassContrast.init(rawValue:)) ?? saved.flatMap(GlassContrast.init(rawValue:)) ?? .outline
    }
}

public struct SurfaceStyle: Equatable, Sendable {
    /// 반대 모드에서 알약이 뒤와 반대 톤이면 가장자리에 붙은 빛은 바깥 배경과 같은 톤이라 녹아 버린다.
    /// 빛을 안쪽으로 들여 빛과 배경 사이에 알약 색 테두리가 남게 한다
    public static let inverseSweepInset: CGFloat = 2

    /// 유리 위에 깔 면의 톤. nil 이면 유리 그대로
    public let fill: GlassTone?
    /// 글자·점이 따를 톤. nil 이면 유리가 정한 톤을 따른다
    public let contentTone: GlassTone?
    /// 가장자리 선의 톤. nil 이면 선 없음
    public let outline: GlassTone?
    public let sweepInset: CGFloat

    public init(fill: GlassTone?, contentTone: GlassTone?, outline: GlassTone?, sweepInset: CGFloat) {
        self.fill = fill
        self.contentTone = contentTone
        self.outline = outline
        self.sweepInset = sweepInset
    }
}
