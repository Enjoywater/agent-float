import Foundation

public enum TtyFormat {
    /// Restrict tty paths to macOS pseudo-terminal devices because they are embedded in scripts.
    public static func isDevicePath(_ tty: String) -> Bool {
        let prefix = "/dev/ttys"
        guard tty.hasPrefix(prefix) else { return false }
        let number = tty.dropFirst(prefix.count)
        return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// Address iTerm by bundle ID to tolerate installation names such as iTerm/iTerm2.
public enum AppleTerminalScripts {
    public static func select(tty: String) -> String {
        """
        tell application id "\(TerminalBundle.appleTerminal)"
          repeat with w in windows
            repeat with t in tabs of w
              if (tty of t) is "\(tty)" then
                set selected of t to true
                set frontmost of w to true
                activate
                return "ok"
              end if
            end repeat
          end repeat
          return "missing"
        end tell
        """
    }

    public static let selectedTty = """
    tell application id "\(TerminalBundle.appleTerminal)" to get tty of selected tab of front window
    """
}

public enum ITermScripts {
    /// Session select chooses only a split; explicitly select its window and tab too (iTerm2 scripting documentation).
    public static func select(tty: String) -> String {
        """
        tell application id "\(TerminalBundle.iTerm)"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if (tty of s) is "\(tty)" then
                  select w
                  tell t to select
                  tell s to select
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          return "missing"
        end tell
        """
    }

    public static let selectedTty = """
    tell application id "\(TerminalBundle.iTerm)" to get tty of current session of current window
    """
}

/// Shared tty-based navigation differs only in each app's script.
struct TtyTabSelector: Sendable {
    let runner: any CommandRunning
    let script: @Sendable (String) -> String

    func select(tty: String) async throws {
        guard TtyFormat.isDevicePath(tty) else { throw NavigationError.terminalNotFound }
        let outcome = try await runner.run(GhosttyScripts.osascript, ["-e", script(tty)])
        // Only ok proves selection; missing indicates the tab closed since listing.
        guard outcome.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
            throw NavigationError.terminalNotFound
        }
    }
}

public struct AppleTerminalNavigator: TerminalNavigator {
    private let selector: TtyTabSelector

    public init(runner: any CommandRunning) {
        selector = TtyTabSelector(runner: runner, script: { AppleTerminalScripts.select(tty: $0) })
    }

    public func canNavigate(_ session: AgentSession) -> Bool {
        if case .appleTerminal = session.locator { return true }
        return false
    }

    public func navigate(to session: AgentSession) async throws {
        guard case let .appleTerminal(tty) = session.locator else { throw NavigationError.terminalNotFound }
        try await selectTab(tty: tty)
    }

    /// Also used when only the outer tty is known, such as tmux clients.
    public func selectTab(tty: String) async throws {
        try await selector.select(tty: tty)
    }
}

public struct ITermNavigator: TerminalNavigator {
    private let selector: TtyTabSelector

    public init(runner: any CommandRunning) {
        selector = TtyTabSelector(runner: runner, script: { ITermScripts.select(tty: $0) })
    }

    public func canNavigate(_ session: AgentSession) -> Bool {
        if case .iTerm = session.locator { return true }
        return false
    }

    public func navigate(to session: AgentSession) async throws {
        guard case let .iTerm(tty) = session.locator else { throw NavigationError.terminalNotFound }
        try await selectTab(tty: tty)
    }

    public func selectTab(tty: String) async throws {
        try await selector.select(tty: tty)
    }
}

/// Match the selected front-window tab tty to identify the session being viewed.
struct TtyFocusReader: Sendable {
    let runner: any CommandRunning
    let script: String
    let ttyOf: @Sendable (TerminalLocator) -> String?

    func focusedSessions(among sessions: [AgentSession]) async throws -> Set<SessionKey> {
        let candidates = sessions.compactMap { session in ttyOf(session.locator).map { (key: session.key, tty: $0) } }
        // Skip osascript when no sessions can match during this polling tick.
        guard !candidates.isEmpty else { return [] }
        let selected = try await runner.run(GhosttyScripts.osascript, ["-e", script])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return [] }
        return Set(candidates.filter { $0.tty == selected }.map(\.key))
    }
}

public struct AppleTerminalFocusProbe: FocusProbe {
    public let bundleIdentifier = TerminalBundle.appleTerminal
    private let reader: TtyFocusReader

    public init(runner: any CommandRunning) {
        reader = TtyFocusReader(runner: runner, script: AppleTerminalScripts.selectedTty) { locator in
            guard case let .appleTerminal(tty) = locator else { return nil }
            return tty
        }
    }

    public func canProbe(_ session: AgentSession) -> Bool {
        reader.ttyOf(session.locator) != nil
    }

    public func focusedSessions(among sessions: [AgentSession]) async throws -> Set<SessionKey> {
        try await reader.focusedSessions(among: sessions)
    }
}

public struct ITermFocusProbe: FocusProbe {
    public let bundleIdentifier = TerminalBundle.iTerm
    private let reader: TtyFocusReader

    public init(runner: any CommandRunning) {
        reader = TtyFocusReader(runner: runner, script: ITermScripts.selectedTty) { locator in
            guard case let .iTerm(tty) = locator else { return nil }
            return tty
        }
    }

    public func canProbe(_ session: AgentSession) -> Bool {
        reader.ttyOf(session.locator) != nil
    }

    public func focusedSessions(among sessions: [AgentSession]) async throws -> Set<SessionKey> {
        try await reader.focusedSessions(among: sessions)
    }
}
