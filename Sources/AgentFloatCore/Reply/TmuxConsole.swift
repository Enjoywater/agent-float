import Foundation

/// tmux pane 에 키를 보내고 화면을 읽는다. 붙은 클라이언트가 없어도 pane 은 살아 있어 그대로 동작한다
public struct TmuxConsole: TerminalConsole {
    /// `capture-pane -e` 가 SGR 을 함께 주므로 흐린 안내 문구를 가려낼 수 있다 (R57)
    public let readsFaintText = true

    private let runner: any CommandRunning
    private let executable: String?

    public init(runner: any CommandRunning, executable: String?) {
        self.runner = runner
        self.executable = executable
    }

    public func handles(_ session: AgentSession) -> Bool {
        if case .tmux = session.locator { return true }
        return false
    }

    public func availability(of session: AgentSession) async -> ConsoleAvailability {
        target(of: session) == nil ? .readOnly(.unsupportedTerminal("tmux")) : .ready
    }

    public func readScreen(of session: AgentSession) async throws -> ConsoleScreen {
        guard let target = target(of: session) else { throw NavigationError.terminalNotFound }
        let output = try await runner.run(target.executable, ["-S", target.socket, "capture-pane", "-p", "-e", "-t", target.pane])
        return ConsoleScreen.ansi(output)
    }

    public func send(_ input: ConsoleInput, to session: AgentSession) async throws {
        guard let target = target(of: session) else { throw NavigationError.terminalNotFound }
        try requireSafeText(input)
        let base = ["-S", target.socket, "send-keys", "-t", target.pane]
        switch input {
        case let .text(text):
            // `-l` 은 글자 그대로 보내고, `--` 뒤에 두어야 `-` 로 시작하는 글이 옵션으로 읽히지 않는다
            _ = try await runner.run(target.executable, base + ["-l", "--", text])
        case let .key(key):
            _ = try await runner.run(target.executable, base + [Self.keyName(key)])
        }
    }

    private static func keyName(_ key: ConsoleKey) -> String {
        switch key {
        case .enter: "Enter"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .tab: "Tab"
        case .space: "Space"
        }
    }

    /// 소켓 경로·pane id 가 형식에 맞을 때만 명령에 넣는다 (v1 `TmuxCLI` 검사 재사용)
    private func target(of session: AgentSession) -> (executable: String, socket: String, pane: String)? {
        guard case let .tmux(socket, pane, _) = session.locator, let executable,
              TmuxCLI.isSafeSocketPath(socket), TmuxCLI.isPaneId(pane) else { return nil }
        return (executable, socket, pane)
    }
}
