import AppKit
import Testing
@testable import AgentFloat

@MainActor
struct MainMenuTests {
    /// AppKit 은 텍스트 칸의 복사·붙여넣기 단축키를 메인 메뉴의 편집 항목으로 처리한다. 메뉴가 없으면 답장 칸에서 ⌘V 가 아무 일도 하지 않는다
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
