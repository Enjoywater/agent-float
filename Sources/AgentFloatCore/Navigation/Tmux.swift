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
    /// 앱은 로그인 셸의 PATH 를 물려받지 않으므로 흔한 설치 위치를 직접 찾는다
    public static let candidatePaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    static let clientFormat = "#{client_tty}\t#{client_pid}\t#{client_session}\t#{client_activity}"

    public static func resolveExecutable() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// pane id 는 `%` 뒤 숫자다. 명령 인자와 새 탭 입력에 그대로 들어가므로 이 형태만 받는다
    public static func isPaneId(_ text: String) -> Bool {
        guard text.first == "%", text.count > 1 else { return false }
        return text.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// 분리된 세션은 새 탭의 셸에 소켓 경로를 입력해 붙이므로, 셸이 따로 해석하는 문자가 없는 경로만 받는다
    public static func isSafeSocketPath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        return path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) }
    }

    /// 형식이 다른 줄은 버린다. 세션 이름에 탭이 들어간 드문 경우도 함께 버려진다
    public static func parseClients(_ output: String) -> [TmuxClient] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 4, !fields[0].isEmpty, let pid = Int32(fields[1]), let activity = Int(fields[3]) else { return nil }
            return TmuxClient(tty: String(fields[0]), pid: pid, session: String(fields[2]), activity: activity)
        }
    }

    /// 그 세션을 이미 보고 있는 클라이언트를 먼저 쓴다. 없으면 사용자가 가장 최근에 만진 클라이언트로 데려간다
    public static func chooseClient(for paneSession: String, among clients: [TmuxClient]) -> TmuxClient? {
        let watching = clients.filter { $0.session == paneSession }
        let pool = watching.isEmpty ? clients : watching
        return pool.max { $0.activity < $1.activity }
    }
}

/// pane 으로 옮긴 뒤 바깥 터미널을 앞으로 올린다. 바깥 앱을 고르고 올리는 일은 AppKit 이 필요해 앱 타깃이 `outer` 로 맡는다
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
            // pane 을 대상으로 주면 세션·창·pane 이 함께 바뀐다 (tmux 3.6 man switch-client)
            _ = try await tmux(executable, socket, ["switch-client", "-c", client.tty, "-t", pane])
            try await outer(pid, ProcessAncestry.chain(from: client.pid, inspector: inspector), client.tty)
            return
        }
        // attach 는 세션만 열고 그 세션의 현재 창·pane 을 바꾸지 않으므로 붙기 전에 골라 둔다
        _ = try await tmux(executable, socket, ["select-window", "-t", pane])
        _ = try await tmux(executable, socket, ["select-pane", "-t", pane])
        let attach = "\(executable) -S \(socket) attach -t \(pane)"
        _ = try await runner.run(GhosttyScripts.osascript, ["-e", GhosttyScripts.newTab(initialInput: attach)])
    }

    /// pane 이 닫혔거나 서버가 없으면 여기서 실패한다. 갈 곳이 없는 것이므로 명령 실패 대신 찾지 못함으로 올린다
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
