import AppKit
import os
import ServiceManagement

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private static let log = Logger(subsystem: "dev.enjoywater.agent-float", category: "menu")

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let launchAtLoginItem = NSMenuItem(
        title: "로그인 시 실행",
        action: #selector(MenuBarController.toggleLaunchAtLogin),
        keyEquivalent: ""
    )
    private let onResetPosition: () -> Void

    init(onResetPosition: @escaping () -> Void) {
        self.onResetPosition = onResetPosition
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "capsule.on.rectangle", accessibilityDescription: "Agent Float")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(makeItem("위치 초기화", action: #selector(resetPosition)))
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("Agent Float 종료", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// 사용자가 시스템 설정에서 로그인 항목을 직접 끄거나 켤 수 있어 열 때마다 실제 상태를 다시 읽는다
    func menuNeedsUpdate(_ menu: NSMenu) {
        launchAtLoginItem.state = switch SMAppService.mainApp.status {
        case .enabled: .on
        // 등록은 됐지만 사용자가 시스템 설정에서 막아 둔 상태라 켜짐도 꺼짐도 아니다
        case .requiresApproval: .mixed
        default: .off
        }
    }

    private func makeItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func resetPosition() {
        onResetPosition()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                // 사용자가 시스템 설정에서 막은 항목은 다시 register 해도 켜지지 않는다(R29).
                // 켜려면 설정 화면에서 승인해야 하고, Option 을 누른 채 고르면 등록 자체를 지워 깨끗한 꺼짐으로 되돌린다
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
        // 처음 켤 때도 시스템이 승인을 요구할 수 있어 바로 승인 화면을 연다
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
