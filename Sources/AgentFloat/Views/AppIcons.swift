import AgentFloatCore
import AppKit

/// Show installed app icons on the second row; cache disk lookups per app (spec §4.10).
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func icon(for app: TerminalApp) -> NSImage? {
        for bundleId in candidates(for: app) {
            if let icon = installedIcon(bundleId: bundleId) { return icon }
        }
        return fallback
    }

    private static func installedIcon(bundleId: String) -> NSImage? {
        if let cached = cache[bundleId] { return cached }
        if missing.contains(bundleId) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            missing.insert(bundleId)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleId] = icon
        return icon
    }

    private static func candidates(for app: TerminalApp) -> [String] {
        switch app {
        case .ghostty: [TerminalBundle.ghostty]
        case .orca: [TerminalBundle.orca]
        case let .other(program): otherCandidates[program] ?? []
        case .unknown: []
        }
    }

    /// Cursor inherits VS Code's vscode TERM_PROGRAM, so environment alone cannot distinguish them.
    /// Use whichever is installed; prefer Cursor when both exist, matching spec §4.4.
    private static let otherCandidates: [String: [String]] = [
        "Apple_Terminal": [TerminalBundle.appleTerminal],
        "iTerm.app": [TerminalBundle.iTerm],
        "vscode": [TerminalBundle.cursor, TerminalBundle.vscode],
    ]

    // A fallback icon keeps second-row text aligned across rows.
    private static let fallback = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
}
