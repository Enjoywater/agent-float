import Testing
@testable import AgentFloatCore

@Suite struct GlassContrastTests {
    @Test(arguments: [GlassTone.light, .dark])
    func standardLeavesEverythingToTheGlass(glass: GlassTone) {
        #expect(GlassContrast.standard.style(glass: glass) == SurfaceStyle(fill: nil, contentTone: nil, outline: nil, sweepInset: 0))
    }

    @Test func outlineDrawsTheOppositeToneOfTheGlass() {
        // 유리가 밝다는 것은 뒤가 밝다는 뜻이라 어두운 선이어야 뒤와 갈린다
        #expect(GlassContrast.outline.style(glass: .light) == SurfaceStyle(fill: nil, contentTone: nil, outline: .dark, sweepInset: 0))
        #expect(GlassContrast.outline.style(glass: .dark) == SurfaceStyle(fill: nil, contentTone: nil, outline: .light, sweepInset: 0))
    }

    @Test func inverseFillsAndForcesTheOppositeTone() {
        let onLight = GlassContrast.inverse.style(glass: .light)
        #expect(onLight == SurfaceStyle(fill: .dark, contentTone: .dark, outline: nil, sweepInset: SurfaceStyle.inverseSweepInset))
        let onDark = GlassContrast.inverse.style(glass: .dark)
        #expect(onDark == SurfaceStyle(fill: .light, contentTone: .light, outline: nil, sweepInset: SurfaceStyle.inverseSweepInset))
    }

    @Test func inverseSweepLeavesARimOfFill() {
        // 빛이 가장자리에 붙으면 바깥 배경과 같은 톤이라 녹아 버린다
        #expect(SurfaceStyle.inverseSweepInset >= 1.5)
    }

    @Test func toneOpposite() {
        #expect(GlassTone.light.opposite == .dark)
        #expect(GlassTone.dark.opposite == .light)
    }

    @Test func overrideWinsOverSaved() {
        #expect(GlassContrast.resolve(override: "inverse", saved: "outline") == .inverse)
        #expect(GlassContrast.resolve(override: nil, saved: "outline") == .outline)
    }

    @Test func unknownValuesFallBack() {
        #expect(GlassContrast.resolve(override: "loud", saved: "inverse") == .inverse)
        #expect(GlassContrast.resolve(override: "", saved: "bogus") == .outline)
    }

    @Test func outlineIsTheDefault() {
        // 같은 톤 배경에서 알약이 사라지는 문제를 기본으로 막되 유리 모양은 지킨다 (R54)
        #expect(GlassContrast.resolve(override: nil, saved: nil) == .outline)
    }

    @Test func savedStandardStaysStandard() {
        #expect(GlassContrast.resolve(override: nil, saved: "standard") == .standard)
    }
}
