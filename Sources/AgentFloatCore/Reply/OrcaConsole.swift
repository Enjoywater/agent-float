import Foundation

/// Orca arrows require literal escape sequences rather than symbolic key names (measurement 12).
public struct OrcaConsole: TerminalConsole {
    /// read --screen omits styles but returns actual composer text separately as draft (measurement S5, 4).
    public let promptCheck = PromptCheck.beforeTyping

    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    public func handles(_ session: AgentSession) -> Bool {
        if case .orca = session.locator { return true }
        return false
    }

    public func availability(of session: AgentSession) async -> ConsoleAvailability {
        handle(of: session) == nil ? .readOnly(.unsupportedTerminal("Orca")) : .ready
    }

    public func readScreen(of session: AgentSession) async throws -> ConsoleScreen {
        guard let handle = handle(of: session) else { throw NavigationError.terminalNotFound }
        let output = try await runner.run(OrcaCLI.executable, ["terminal", "read", "--terminal", handle, "--screen", "--json"])
        let screen = try OrcaCLI.parseScreen(Data(output.utf8))
        return session.key.providerId == "codex" ? CodexScreen.placingPromptInput(screen) : ClaudeScreen.placingPromptInput(screen)
    }

    public func send(_ input: ConsoleInput, to session: AgentSession) async throws {
        guard let handle = handle(of: session) else { throw NavigationError.terminalNotFound }
        try requireSafeText(input)
        var arguments = ["terminal", "send", "--terminal", handle]
        switch input {
        case let .text(text):
            // Orca rejects separate values beginning with -- as options; join any leading-hyphen text to its option.
            arguments += text.hasPrefix("-") ? ["--text=\(text)"] : ["--text", text]
        case .key(.enter):
            arguments += ["--enter"]
        case let .key(key):
            guard let sequence = Self.sequence(key) else { throw NavigationError.commandFailed("erase is not used") }
            arguments += ["--text", sequence]
        }
        let output = try await runner.run(OrcaCLI.executable, arguments + ["--json"])
        // Command success does not prove the terminal accepted input.
        guard OrcaCLI.sendAccepted(Data(output.utf8)) else { throw NavigationError.commandFailed("orca did not accept the input") }
    }

    /// Before-typing checks never erase; expose no deletion text to prevent accidental user-text removal.
    private static func sequence(_ key: ConsoleKey) -> String? {
        switch key {
        case .up: "\u{1b}[A"
        case .down: "\u{1b}[B"
        case .right: "\u{1b}[C"
        case .left: "\u{1b}[D"
        case .tab: "\t"
        case .space: " "
        case .enter: "\r"
        case .backspace: nil
        }
    }

    /// Pass handles only as argv, but reject formats Orca could not have generated.
    private func handle(of session: AgentSession) -> String? {
        guard case let .orca(_, _, handle?) = session.locator, !handle.isEmpty,
              handle.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { return nil }
        return handle
    }
}
