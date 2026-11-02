import Testing
@testable import AgentFloatCore

@Suite struct GlassContrastTests {
    @Test(arguments: [GlassTone.light, .dark])
    func standardLeavesEverythingToTheGlass(glass: GlassTone) {
        #expect(GlassContrast.standard.style(glass: glass) == SurfaceStyle(fill: nil, contentTone: nil, outline: nil, sweepInset: 0))
    }

    @Test func outlineDrawsTheOppositeToneOfTheGlass() {
        // Light glass indicates a light background, requiring a dark contrasting outline.
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
        // A highlight at the edge matches the outer background and disappears.
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
        // Default behavior prevents disappearing pills on matching backgrounds while preserving glass (R54).
        #expect(GlassContrast.resolve(override: nil, saved: nil) == .outline)
    }

    @Test func savedStandardStaysStandard() {
        #expect(GlassContrast.resolve(override: nil, saved: "standard") == .standard)
    }
}
