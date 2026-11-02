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
        menu.addItem(NSMenuItem(title: LanguageSettings.shared.strings.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: LanguageSettings.shared.strings.editMenu)
        menu.addItem(NSMenuItem(title: LanguageSettings.shared.strings.undo, action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: LanguageSettings.shared.strings.redo, action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: LanguageSettings.shared.strings.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: LanguageSettings.shared.strings.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: LanguageSettings.shared.strings.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: LanguageSettings.shared.strings.selectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        return menu
    }

    private static func submenuItem(_ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}
