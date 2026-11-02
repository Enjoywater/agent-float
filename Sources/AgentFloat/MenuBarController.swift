import AgentFloatCore
import AppKit
import os
import ServiceManagement

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private static let log = Logger(subsystem: "dev.enjoywater.agent-float", category: "menu")

    private static let launchAtLoginId = NSUserInterfaceItemIdentifier("launchAtLogin")
    private static let contrastId = NSUserInterfaceItemIdentifier("contrast")
    private static let placementId = NSUserInterfaceItemIdentifier("placement")
    private static let presenceId = NSUserInterfaceItemIdentifier("presence")

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let onResetPosition: () -> Void
    private let contrast: () -> GlassContrast
    private let onSelectContrast: (GlassContrast) -> Void
    private let placement: () -> ReplyPlacement
    private let onSelectPlacement: (ReplyPlacement) -> Void
    private let presence: () -> IconPresence
    private let onSelectPresence: (IconPresence) -> Void

    init(
        onResetPosition: @escaping () -> Void,
        contrast: @escaping () -> GlassContrast,
        onSelectContrast: @escaping (GlassContrast) -> Void,
        placement: @escaping () -> ReplyPlacement,
        onSelectPlacement: @escaping (ReplyPlacement) -> Void,
        presence: @escaping () -> IconPresence,
        onSelectPresence: @escaping (IconPresence) -> Void
    ) {
        self.onResetPosition = onResetPosition
        self.contrast = contrast
        self.onSelectContrast = onSelectContrast
        self.placement = placement
        self.onSelectPlacement = onSelectPlacement
        self.presence = presence
        self.onSelectPresence = onSelectPresence
        super.init()

        statusItem.button?.image = Self.statusIcon()
        statusItem.menu = makeMenu(includesQuit: true)
    }

    /// When the menu bar icon is hidden, settings remain available only in the Dock context menu.
    func setStatusItemVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    /// Omit Quit from the Dock context menu because the Dock adds it automatically.
    func dockMenu() -> NSMenu {
        let menu = makeMenu(includesQuit: false)
        refreshStates(of: menu)
        return menu
    }

    /// Refresh login-item state whenever opening the menu because users can change it in System Settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStates(of: menu)
    }

    private func makeMenu(includesQuit: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(makeItem("위치 초기화", action: #selector(resetPosition)))
        menu.addItem(makeChoiceMenu("가장자리 대비", id: Self.contrastId, GlassContrast.allCases, title: Self.title(of:), action: #selector(selectContrast(_:))))
        // Choose where to show the reply view (v1.2 design §4.5).
        menu.addItem(makeChoiceMenu("답장 화면", id: Self.placementId, ReplyPlacement.allCases, title: Self.title(of:), action: #selector(selectPlacement(_:))))
        menu.addItem(makeChoiceMenu("아이콘 위치", id: Self.presenceId, IconPresence.allCases, title: Self.title(of:), action: #selector(selectPresence(_:))))
        let launchAtLogin = makeItem("로그인 시 실행", action: #selector(toggleLaunchAtLogin))
        launchAtLogin.identifier = Self.launchAtLoginId
        menu.addItem(launchAtLogin)
        if includesQuit {
            menu.addItem(.separator())
            menu.addItem(makeItem("Agent Float 종료", action: #selector(quit), keyEquivalent: "q"))
        }
        return menu
    }

    /// Choice items carry raw values; check the one matching the group's current value.
    private func refreshStates(of menu: NSMenu) {
        let current: [NSUserInterfaceItemIdentifier: String] = [
            Self.contrastId: contrast().rawValue,
            Self.placementId: placement().rawValue,
            Self.presenceId: presence().rawValue,
        ]
        for item in menu.items {
            if let id = item.identifier, let selected = current[id] {
                for choice in item.submenu?.items ?? [] {
                    choice.state = choice.representedObject as? String == selected ? .on : .off
                }
            }
            guard item.identifier == Self.launchAtLoginId else { continue }
            item.state = switch SMAppService.mainApp.status {
            case .enabled: .on
            // Registered but blocked in System Settings is neither fully enabled nor disabled.
            case .requiresApproval: .mixed
            default: .off
            }
        }
    }

    private func makeChoiceMenu<Choice: RawRepresentable<String>>(
        _ title: String, id: NSUserInterfaceItemIdentifier, _ choices: [Choice], title choiceTitle: (Choice) -> String, action: Selector
    ) -> NSMenuItem {
        let submenu = NSMenu()
        for choice in choices {
            let item = makeItem(choiceTitle(choice), action: action)
            item.representedObject = choice.rawValue
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.identifier = id
        parent.submenu = submenu
        return parent
    }

    /// Keep the colored icon non-template; use a symbol when running outside the resource bundle.
    private static func statusIcon() -> NSImage? {
        guard let icon = Bundle.main.image(forResource: "MenuBarIcon") else {
            return NSImage(systemSymbolName: "capsule.on.rectangle", accessibilityDescription: "Agent Float")
        }
        icon.size = NSSize(width: 18, height: 18)
        icon.accessibilityDescription = "Agent Float"
        return icon
    }

    private func makeItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func resetPosition() {
        onResetPosition()
    }

    private static func title(of mode: GlassContrast) -> String {
        switch mode {
        // The default is Outline, so calling another option Default would be misleading.
        case .standard: "유리 그대로"
        case .outline: "윤곽선"
        case .inverse: "뒤 화면과 반대"
        }
    }

    private static func title(of placement: ReplyPlacement) -> String {
        switch placement {
        case .panel: "패널 전환"
        case .inline: "줄 안에서 펼침"
        case .card: "옆에 카드"
        }
    }

    private static func title(of presence: IconPresence) -> String {
        switch presence {
        case .menuBar: "메뉴바에서 보기"
        case .dock: "Dock에서 보기"
        case .both: "둘 다 보기"
        }
    }

    @objc private func selectPresence(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let presence = IconPresence(rawValue: raw) else { return }
        onSelectPresence(presence)
    }

    @objc private func selectPlacement(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let placement = ReplyPlacement(rawValue: raw) else { return }
        onSelectPlacement(placement)
    }

    @objc private func selectContrast(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = GlassContrast(rawValue: raw) else { return }
        onSelectContrast(mode)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                // Registering again cannot enable an item blocked in System Settings (R29).
                // Open approval settings, or hold Option to unregister and restore a clean disabled state.
                if NSEvent.modifierFlags.contains(.option) {
                    try service.unregister()
                } else {
                    SMAppService.openSystemSettingsLoginItems()
                }
                return
            default:
                try service.register()
            }
        } catch {
            Self.log.error("login item toggle failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
        // Initial registration may require approval too; open the approval settings immediately.
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
