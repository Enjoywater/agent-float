import Foundation

public enum TtyFormat {
    /// 스크립트 문자열 안에 그대로 들어가므로 macOS 의사 터미널 경로 형태만 받는다
    public static func isDevicePath(_ tty: String) -> Bool {
        let prefix = "/dev/ttys"
        guard tty.hasPrefix(prefix) else { return false }
        let number = tty.dropFirst(prefix.count)
        return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// 앱 이름이 `iTerm`·`iTerm2` 처럼 설치마다 달라도 맞도록 번들 id 로 부른다
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
    /// 세션 `select` 는 그 탭 안의 분할 창만 고르므로 창과 탭도 따로 고른다 (iTerm2 스크립팅 문서)
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

/// tty 로 탭을 고르는 터미널의 공통 이동. 앱마다 다른 것은 스크립트뿐이다
struct TtyTabSelector: Sendable {
    let runner: any CommandRunning
    let script: @Sendable (String) -> String

    func select(tty: String) async throws {
        guard TtyFormat.isDevicePath(tty) else { throw NavigationError.terminalNotFound }
        let outcome = try await runner.run(GhosttyScripts.osascript, ["-e", script(tty)])
        // 목록을 읽은 뒤 탭이 닫혔으면 "missing" 이 온다. "ok" 외에는 그 탭을 보여 주지 못한 것이다
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

    /// tmux 의 바깥 터미널처럼 세션 위치 정보 없이 tty 만 아는 경우에도 쓴다
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

/// 맨 앞 창에서 선택된 탭의 tty 와 같은 세션을 사용자가 보고 있는 것으로 본다
struct TtyFocusReader: Sendable {
    let runner: any CommandRunning
    let script: String
    let ttyOf: @Sendable (TerminalLocator) -> String?

    func focusedSessions(among sessions: [AgentSession]) async throws -> Set<SessionKey> {
        let candidates = sessions.compactMap { session in ttyOf(session.locator).map { (key: session.key, tty: $0) } }
        // 감시 주기마다 불리므로 짝지을 세션이 없으면 osascript 를 띄우지 않는다
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
