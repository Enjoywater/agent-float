import Testing
@testable import AgentFloatCore

@Suite struct IconPresenceTests {
    @Test func defaultsToTheMenuBarOnly() {
        // 고른 적이 없으면 지금까지처럼 메뉴바에만 둔다
        #expect(IconPresence.resolve(saved: nil) == .menuBar)
        #expect(IconPresence.resolve(saved: "unknown") == .menuBar)
        #expect(IconPresence.resolve(saved: "dock") == .dock)
    }

    @Test func eachChoiceShowsItsIcons() {
        #expect(IconPresence.menuBar.showsMenuBarIcon && !IconPresence.menuBar.showsDockIcon)
        #expect(!IconPresence.dock.showsMenuBarIcon && IconPresence.dock.showsDockIcon)
        #expect(IconPresence.both.showsMenuBarIcon && IconPresence.both.showsDockIcon)
    }

    /// 설정 메뉴는 메뉴바 아이콘이나 Dock 아이콘에만 있다. 둘 다 숨기면 되돌릴 길이 없어진다
    @Test(arguments: IconPresence.allCases)
    func everyChoiceKeepsAWayBackToTheMenu(presence: IconPresence) {
        #expect(presence.showsMenuBarIcon || presence.showsDockIcon)
    }
}
