import AppKit
import Testing
@testable import AgentFloat

struct AppLanguageTests {
    @Test func resolvesOverridesSavedAndSystemPreferences() {
        #expect(AppLanguage.resolve(saved: nil, override: nil, preferred: ["ko-KR"]) == .ko)
        #expect(AppLanguage.resolve(saved: nil, override: nil, preferred: ["en-US"]) == .en)
        #expect(AppLanguage.resolve(saved: nil, override: nil, preferred: ["ja-JP"]) == .en)
        #expect(AppLanguage.resolve(saved: "en", override: nil, preferred: ["ko-KR"]) == .en)
        #expect(AppLanguage.resolve(saved: "en", override: "ko", preferred: []) == .ko)
        #expect(AppLanguage.resolve(saved: "invalid", override: "invalid", preferred: ["ko"]) == .ko)
        #expect(AppLanguage.allCases.map(\.endonym) == ["한국어", "English"])
    }

    @MainActor @Test func selectionPersistsOnlyExplicitChanges() throws {
        let name = "agent-float-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LanguageSettings(defaults: defaults, environment: [:], preferred: ["ko"])
        #expect(defaults.string(forKey: "language") == nil)
        #expect(settings.strings.resetPosition == "위치 초기화")
        settings.select(.en)
        #expect(defaults.string(forKey: "language") == "en")
        #expect(settings.strings.resetPosition == "Reset Position")
    }
}

@MainActor @Test func languageMenuKeepsItsTitleOrderAndActualCheckmark() {
    for language in AppLanguage.allCases {
        let menu = MenuBarController.languageMenu(current: language, target: nil)
        #expect(menu.title == "Language")
        #expect(menu.submenu?.items.map(\.title) == ["한국어", "English"])
        #expect(menu.submenu?.items.first { $0.state == .on }?.representedObject as? String == language.rawValue)
    }
}
