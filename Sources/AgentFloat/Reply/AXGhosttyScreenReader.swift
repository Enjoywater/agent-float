import AgentFloatCore
import AppKit
import ApplicationServices

/// Ghostty 창의 텍스트 영역 값을 손쉬운 사용 API 로 읽는다. 창마다 텍스트 영역이 하나뿐이고 선택된 탭의 화면이 들어 있다 (실측 S3)
struct AXGhosttyScreenReader: GhosttyScreenReading {
    /// 응답 없는 앱 때문에 보내기가 멈춰 서지 않게 짧게 둔다
    private static let messagingTimeout: Float = 1
    /// 실측 구조는 창 → 그룹 → 그룹 → 스크롤 영역 → 텍스트 영역이라 이보다 깊이 볼 필요가 없다
    private static let searchDepth = 6

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func screen(windowTitle: String) throws -> [String] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: TerminalBundle.ghostty).first else {
            throw NavigationError.terminalNotFound
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, Self.messagingTimeout)
        let key = GhosttyMatcher.windowKey(windowTitle)
        let windows = (Self.attribute(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let matching = windows.filter { window in
            (Self.attribute(window, kAXTitleAttribute) as? String).map(GhosttyMatcher.windowKey) == key
        }
        // 같은 제목의 창이 둘이면 어느 쪽이 그 세션인지 알 수 없다
        guard matching.count == 1 else { throw NavigationError.terminalNotFound }
        let areas = Self.textAreas(under: matching[0])
        guard areas.count == 1, let value = Self.attribute(areas[0], kAXValueAttribute) as? String else {
            throw NavigationError.terminalNotFound
        }
        return value.components(separatedBy: "\n")
    }

    /// 실행 중에 권한 창을 한 번 띄운다. 이미 허용했거나 거절했다면 창은 다시 뜨지 않는다
    static func requestTrust() {
        // 전역 상수 `kAXTrustedCheckOptionPrompt` 는 Swift 6 에서 동시성 안전하지 않은 var 로 들어와 같은 값의 글자로 쓴다
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func textAreas(under window: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var level: [AXUIElement] = [window]
        for _ in 0..<searchDepth where !level.isEmpty {
            var next: [AXUIElement] = []
            for element in level {
                if attribute(element, kAXRoleAttribute) as? String == kAXTextAreaRole { found.append(element) }
                next += (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            }
            level = next
        }
        return found
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
