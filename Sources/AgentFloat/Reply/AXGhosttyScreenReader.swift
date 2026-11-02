import AgentFloatCore
import AppKit
import ApplicationServices

/// Read Ghostty's selected tab through the window's single Accessibility text area (measurement S3).
struct AXGhosttyScreenReader: GhosttyScreenReading {
    /// Use a short timeout so an unresponsive app cannot stall sending.
    private static let messagingTimeout: Float = 1
    /// The observed hierarchy is window/group/group/scroll area/text area; deeper traversal is unnecessary.
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
        // Duplicate window titles cannot uniquely identify the session.
        guard matching.count == 1 else { throw NavigationError.terminalNotFound }
        let areas = Self.textAreas(under: matching[0])
        guard areas.count == 1, let value = Self.attribute(areas[0], kAXValueAttribute) as? String else {
            throw NavigationError.terminalNotFound
        }
        return value.components(separatedBy: "\n")
    }

    /// Request Accessibility permission once at runtime; previous approval or denial suppresses the prompt.
    static func requestTrust() {
        // Use the constant's literal value because Swift 6 imports kAXTrustedCheckOptionPrompt as an unsafe global var.
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
