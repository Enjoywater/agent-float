import AppKit

/// 메뉴바 아이콘 앱이라 평소에는 메뉴 막대에 보이지 않지만, 답장 칸의 ⌘C·⌘V·⌘A·⌘Z 는 이 메뉴의 단축키로만 동작한다
/// (AppKit 은 텍스트 칸의 편집 단축키를 메인 메뉴의 편집 항목으로 처리한다). Dock 에 둔 채 앱이 앞에 오면 메뉴 막대에 보인다
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenuItem(appMenu()))
        menu.addItem(submenuItem(editMenu()))
        return menu
    }

    /// 첫 메뉴는 이름과 상관없이 앱 메뉴로 그려진다
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
