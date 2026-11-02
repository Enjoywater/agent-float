import AppKit
import Testing
@testable import AgentFloat

@MainActor
struct MainMenuTests {
    /// AppKit routes editing shortcuts through the main menu; without it, Command-V does nothing in reply fields.
    @Test func editShortcutsReachTheReplyField() {
        let items = MainMenu.make().items.flatMap { $0.submenu?.items ?? [] }
        func action(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> Selector? {
            items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }?.action
        }
        #expect(action("v") == #selector(NSText.paste(_:)))
        #expect(action("c") == #selector(NSText.copy(_:)))
        #expect(action("x") == #selector(NSText.cut(_:)))
        #expect(action("a") == #selector(NSText.selectAll(_:)))
        #expect(action("z") == Selector(("undo:")))
        #expect(action("z", [.command, .shift]) == Selector(("redo:")))
    }
}
