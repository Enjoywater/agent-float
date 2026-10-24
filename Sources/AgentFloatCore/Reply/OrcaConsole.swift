import Foundation

/// Orca 터미널에 키를 보내고 화면을 읽는다. 화살표는 키 이름이 아니라 ESC 시퀀스 글자로 보내야 들어간다 (실측 ⑫)
public struct OrcaConsole: TerminalConsole {
    /// `read --screen` 이 글자만 주고 스타일은 주지 않는다 (실측 ⑫)
    public let readsFaintText = false

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
        return try OrcaCLI.parseScreen(Data(output.utf8))
    }

    public func send(_ input: ConsoleInput, to session: AgentSession) async throws {
        guard let handle = handle(of: session) else { throw NavigationError.terminalNotFound }
        try requireSafeText(input)
        var arguments = ["terminal", "send", "--terminal", handle]
        switch input {
        case let .text(text):
            // `--` 로 시작하는 글을 따로 넘기면 Orca 가 옵션으로 읽어 "값 없음"으로 거절한다(실측). 붙여 넘기면 값으로 받으므로 `-` 로 시작하면 모두 붙인다
            arguments += text.hasPrefix("-") ? ["--text=\(text)"] : ["--text", text]
        case .key(.enter):
            arguments += ["--enter"]
        case let .key(key):
            arguments += ["--text", Self.sequence(key)]
        }
        let output = try await runner.run(OrcaCLI.executable, arguments + ["--json"])
        // 명령은 성공해도 터미널이 입력을 받지 않았을 수 있다
        guard OrcaCLI.sendAccepted(Data(output.utf8)) else { throw NavigationError.commandFailed("orca did not accept the input") }
    }

    private static func sequence(_ key: ConsoleKey) -> String {
        switch key {
        case .up: "\u{1b}[A"
        case .down: "\u{1b}[B"
        case .right: "\u{1b}[C"
        case .left: "\u{1b}[D"
        case .tab: "\t"
        case .space: " "
        case .enter: "\r"
        }
    }

    /// handle 은 argv 로만 넘기지만, 형식이 다른 값은 Orca 가 만든 것이 아니므로 쓰지 않는다
    private func handle(of session: AgentSession) -> String? {
        guard case let .orca(_, _, handle?) = session.locator, !handle.isEmpty,
              handle.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { return nil }
        return handle
    }
}
