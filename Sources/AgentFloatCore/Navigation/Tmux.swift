import Foundation

public struct TmuxClient: Equatable, Sendable {
    public let tty: String
    public let pid: Int32
    public let session: String
    public let activity: Int

    public init(tty: String, pid: Int32, session: String, activity: Int) {
        self.tty = tty
        self.pid = pid
        self.session = session
        self.activity = activity
    }
}

public enum TmuxCLI {
    /// GUI apps do not inherit login-shell PATH; search common installation locations directly.
    public static let candidatePaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    static let clientFormat = "#{client_tty}\t#{client_pid}\t#{client_session}\t#{client_activity}"

    public static func resolveExecutable() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Accept only percent-prefixed numeric pane IDs, which are reused in command arguments and new-tab input.
    public static func isPaneId(_ text: String) -> Bool {
        guard text.first == "%", text.count > 1 else { return false }
        return text.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Detached attachment types the socket path into a shell; reject paths containing shell metacharacters.
    public static func isSafeSocketPath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        return path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) }
    }

    /// Discard malformed rows, including rare session names containing tabs.
    public static func parseClients(_ output: String) -> [TmuxClient] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 4, !fields[0].isEmpty, let pid = Int32(fields[1]), let activity = Int(fields[3]) else { return nil }
            return TmuxClient(tty: String(fields[0]), pid: pid, session: String(fields[2]), activity: activity)
        }
    }

    /// Prefer an existing client viewing this session; otherwise choose the most recently active client.
    public static func chooseClient(for paneSession: String, among clients: [TmuxClient]) -> TmuxClient? {
        let watching = clients.filter { $0.session == paneSession }
        let pool = watching.isEmpty ? clients : watching
        return pool.max { $0.activity < $1.activity }
    }
}

/// Select the tmux pane then raise its outer terminal; inject AppKit-dependent behavior through outer.
public struct TmuxNavigator: TerminalNavigator {
    public typealias Outer = @Sendable (_ sessionPid: Int32, _ clientChain: [Int32], _ clientTty: String) async throws -> Void

    private let runner: any CommandRunning
    private let inspector: any ProcessInspecting
    private let executable: String?
    private let outer: Outer

    public init(runner: any CommandRunning, inspector: any ProcessInspecting, executable: String?, outer: @escaping Outer) {
        self.runner = runner
        self.inspector = inspector
        self.executable = executable
        self.outer = outer
    }

    public func canNavigate(_ session: AgentSession) -> Bool {
        if case .tmux = session.locator { return true }
        return false
    }

    public func navigate(to session: AgentSession) async throws {
        guard case let .tmux(socket, pane, pid) = session.locator, let executable,
              TmuxCLI.isSafeSocketPath(socket), TmuxCLI.isPaneId(pane) else {
            throw NavigationError.terminalNotFound
        }
        let paneSession = try await sessionName(of: pane, executable: executable, socket: socket)
        let clients = TmuxCLI.parseClients(try await tmux(executable, socket, ["list-clients", "-F", TmuxCLI.clientFormat]))
        if let client = TmuxCLI.chooseClient(for: paneSession, among: clients) {
            // Targeting a pane switches session, window, and pane together (tmux 3.6 switch-client manual).
            _ = try await tmux(executable, socket, ["switch-client", "-c", client.tty, "-t", pane])
            try await outer(pid, ProcessAncestry.chain(from: client.pid, inspector: inspector), client.tty)
            return
        }
        // Select window/pane before attaching, because attach selects only the session.
        _ = try await tmux(executable, socket, ["select-window", "-t", pane])
        _ = try await tmux(executable, socket, ["select-pane", "-t", pane])
        let attach = "\(executable) -S \(socket) attach -t \(pane)"
        _ = try await runner.run(GhosttyScripts.osascript, ["-e", GhosttyScripts.newTab(initialInput: attach)])
    }

    /// Missing panes/servers mean no destination; report terminalNotFound instead of generic command failure.
    private func sessionName(of pane: String, executable: String, socket: String) async throws -> String {
        let output: String
        do {
            output = try await tmux(executable, socket, ["display-message", "-p", "-t", pane, "#{session_name}"])
        } catch NavigationError.commandFailed {
            throw NavigationError.terminalNotFound
        }
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NavigationError.terminalNotFound }
        return name
    }

    private func tmux(_ executable: String, _ socket: String, _ arguments: [String]) async throws -> String {
        try await runner.run(executable, ["-S", socket] + arguments)
    }
}
