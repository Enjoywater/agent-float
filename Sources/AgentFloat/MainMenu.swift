import AppKit

/// Although normally hidden, this menu supplies reply-field copy/paste/select-all/undo shortcuts.
/// AppKit routes text editing shortcuts through the main menu; it becomes visible when the Dock app is active.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenuItem(appMenu()))
        menu.addItem(submenuItem(editMenu()))
        return menu
    }

    /// The first menu is rendered as the application menu regardless of its name.
    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Agent Float")
        menu.addItem(NSMenuItem(title: "Agent Float 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "편집")
        menu.addItem(NSMenuItem(title: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        return menu
    }

    private static func submenuItem(_ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}
