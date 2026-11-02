import Foundation

/// Send keys/read screens for tmux panes even when no client is attached.
public struct TmuxConsole: TerminalConsole {
    /// capture-pane -e preserves SGR, allowing faint hint detection (R57).
    public let promptCheck = PromptCheck.beforeTyping

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
            // Use -l for literal text and -- to prevent leading-hyphen text from becoming options.
            _ = try await runner.run(target.executable, base + ["-l", "--", text])
        case let .key(key):
            guard let name = Self.keyName(key) else { throw NavigationError.commandFailed("erase is not used") }
            _ = try await runner.run(target.executable, base + [name])
        }
    }

    /// Before-typing checks need no deletion; expose no key name to avoid erasing user input on accidental calls.
    private static func keyName(_ key: ConsoleKey) -> String? {
        switch key {
        case .enter: "Enter"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .tab: "Tab"
        case .space: "Space"
        case .backspace: nil
        }
    }

    /// Reuse v1 TmuxCLI validation before inserting socket paths/pane IDs into commands.
    private func target(of session: AgentSession) -> (executable: String, socket: String, pane: String)? {
        guard case let .tmux(socket, pane, _) = session.locator, let executable,
              TmuxCLI.isSafeSocketPath(socket), TmuxCLI.isPaneId(pane) else { return nil }
        return (executable, socket, pane)
    }
}
