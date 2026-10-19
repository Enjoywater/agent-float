import AgentFloatCore
import AppKit

/// 2행의 앱 이름 대신 실제 앱 아이콘을 보여준다 (spec 4.10). 아이콘 조회는 디스크를 읽으므로 앱마다 한 번만 한다
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

    /// `TERM_PROGRAM` 값 → 앱. Cursor 는 VS Code 에서 갈라져 나와 같은 `vscode` 를 내보내므로 어느 쪽인지 알 수 없어
    /// 설치된 쪽을 고른다. 둘 다 있으면 spec 4.4 의 예인 Cursor 를 먼저 본다
    private static let otherCandidates: [String: [String]] = [
        "Apple_Terminal": [TerminalBundle.appleTerminal],
        "vscode": [TerminalBundle.cursor, TerminalBundle.vscode],
    ]

    // 아이콘 자리가 비면 2행 글자 시작 위치가 줄마다 달라져 묶음 안에서 들쭉날쭉해 보인다
    private static let fallback = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
}
