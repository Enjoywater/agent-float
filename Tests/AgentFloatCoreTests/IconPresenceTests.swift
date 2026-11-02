import Testing
@testable import AgentFloatCore

@Suite struct IconPresenceTests {
    @Test func defaultsToTheMenuBarOnly() {
        // Without a saved choice, retain menu-bar-only behavior.
        #expect(IconPresence.resolve(saved: nil) == .menuBar)
        #expect(IconPresence.resolve(saved: "unknown") == .menuBar)
        #expect(IconPresence.resolve(saved: "dock") == .dock)
    }

    @Test func eachChoiceShowsItsIcons() {
        #expect(IconPresence.menuBar.showsMenuBarIcon && !IconPresence.menuBar.showsDockIcon)
        #expect(!IconPresence.dock.showsMenuBarIcon && IconPresence.dock.showsDockIcon)
        #expect(IconPresence.both.showsMenuBarIcon && IconPresence.both.showsDockIcon)
    }

    /// Settings exist only in menu bar/Dock menus; hiding both would make recovery impossible.
    @Test(arguments: IconPresence.allCases)
    func everyChoiceKeepsAWayBackToTheMenu(presence: IconPresence) {
        #expect(presence.showsMenuBarIcon || presence.showsDockIcon)
    }
}
