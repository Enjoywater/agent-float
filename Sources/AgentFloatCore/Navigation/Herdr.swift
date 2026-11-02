import Foundation

public struct HerdrTarget: Equatable, Hashable, Sendable {
    public let terminal: String
    public let socket: String
    public let pid: Int32
    public let procStart: String?
    public let appHome: String?

    /// HC variables can leak into child GUI apps. Stop at the first ancestor without a tty,
    /// but allow nested ptys (for example, an editor terminal) below core.
    public static func detect(pid: Int32, procStart: String? = nil, environment: [String: String], inspector: any ProcessInspecting) -> HerdrTarget? {
        guard let terminal = environment["HC_TERMINAL_ID"], isAddress(terminal),
              let socket = environment["HC_TERMINAL_SOCKET"], socket.hasPrefix("/"),
              inspector.tty(pid: pid) != nil else { return nil }
        for ancestor in ProcessAncestry.chain(from: pid, inspector: inspector) {
            if inspector.tty(pid: ancestor) != nil { continue }
            guard inspector.executablePath(pid: ancestor).map({ URL(fileURLWithPath: $0).lastPathComponent }) == "herdr-core" else { return nil }
            return HerdrTarget(terminal: terminal, socket: socket, pid: pid, procStart: procStart,
                               appHome: environment["HERDR_APP_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil })
        }
        return nil
    }

    static func isAddress(_ value: String) -> Bool {
        value.first == "t" && value.count > 1 && value.dropFirst().allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."z").contains(String($0))) }
    }
}

struct HerdrTerminal: Decodable, Sendable {
    let address: String
    let pid: Int32?
    let state: String
    let title: String?
    let labels: [String: String]

    func belongs(to target: HerdrTarget, inspector: any ProcessInspecting) -> Bool {
        guard state == "live", address == target.terminal, let pid,
              inspector.isAlive(pid: target.pid, procStart: target.procStart),
              inspector.tty(pid: pid) != nil,
              HerdrTarget.detect(pid: target.pid, procStart: target.procStart,
                                 environment: inspector.environment(pid: target.pid), inspector: inspector) == target else { return false }
        return ProcessAncestry.chain(from: target.pid, inspector: inspector).contains(pid)
    }
}

enum HerdrCLI {
    static func executable(_ name: String) -> String? {
        let candidates = [NSHomeDirectory() + "/.local/bin/" + name, "/opt/homebrew/bin/" + name, "/usr/local/bin/" + name]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func coreArguments(_ target: HerdrTarget, executable: String) -> [String] {
        ["HC_TERMINAL_SOCKET=\(target.socket)", executable, "get", target.terminal, "--json"]
    }

    static func appArguments(_ target: HerdrTarget, executable: String, command: [String]) -> [String] {
        var arguments: [String] = []
        if let home = target.appHome { arguments.append("HERDR_APP_HOME=\(home)") }
        return arguments + [executable] + command
    }

    static func read(_ target: HerdrTarget) throws -> HerdrTerminal {
        guard let executable = executable("herdr-core") else { throw NavigationError.terminalNotFound }
        return try JSONDecoder().decode(HerdrTerminal.self, from: Data(SyncCommand.run("/usr/bin/env", coreArguments(target, executable: executable)).utf8))
    }

    /// Terminal IDs overlap across cores; match the core labels against the window placement as well.
    static func contains(_ terminal: HerdrTerminal, in listing: Data) throws -> Bool {
        let window = try JSONDecoder().decode(Window.self, from: listing)
        let matches = window.spaces.flatMap { space in
            space.tabs.flatMap { tab in
                tab.terminals.filter {
                    space.machine == nil && space.id == terminal.labels["herdr.space"] &&
                    tab.id == terminal.labels["herdr.tab"] && $0.terminal == terminal.address
                }
            }
        }
        return matches.count == 1
    }

    private struct Window: Decodable {
        let spaces: [Space]
        struct Space: Decodable {
            let id: String
            let machine: String?
            let tabs: [Tab]
        }
        struct Tab: Decodable {
            let id: String
            let terminals: [Pane]
        }
        struct Pane: Decodable { let terminal: String }
    }
}

public struct HerdrNavigator: TerminalNavigator {
    private let runner: any CommandRunning
    private let inspector: any ProcessInspecting
    private let coreExecutable: String?
    private let appExecutable: String?
    private let activateHerdr: @Sendable () -> Void

    public init(runner: any CommandRunning, inspector: any ProcessInspecting = DarwinProcessInspector(), activateHerdr: @escaping @Sendable () -> Void) {
        self.init(runner: runner, inspector: inspector, coreExecutable: HerdrCLI.executable("herdr-core"),
                  appExecutable: HerdrCLI.executable("herdr-app"), activateHerdr: activateHerdr)
    }

    init(runner: any CommandRunning, inspector: any ProcessInspecting, coreExecutable: String?, appExecutable: String?, activateHerdr: @escaping @Sendable () -> Void) {
        self.runner = runner
        self.inspector = inspector
        self.coreExecutable = coreExecutable
        self.appExecutable = appExecutable
        self.activateHerdr = activateHerdr
    }

    public func canNavigate(_ session: AgentSession) -> Bool {
        if case .herdr = session.locator { return true }
        return false
    }

    public func navigate(to session: AgentSession) async throws {
        guard case let .herdr(target) = session.locator else { throw NavigationError.terminalNotFound }
        try await focus(target)
    }

    public func focus(_ target: HerdrTarget) async throws {
        guard let coreExecutable, let appExecutable else { throw NavigationError.terminalNotFound }
        let raw = try await runner.run("/usr/bin/env", HerdrCLI.coreArguments(target, executable: coreExecutable))
        let terminal = try JSONDecoder().decode(HerdrTerminal.self, from: Data(raw.utf8))
        guard terminal.belongs(to: target, inspector: inspector) else { throw NavigationError.terminalNotFound }
        let listing = try await app(target, executable: appExecutable, ["ls"])
        guard try HerdrCLI.contains(terminal, in: Data(listing.utf8)) else { throw NavigationError.terminalNotFound }
        _ = try await app(target, executable: appExecutable, ["do", "agent.focus", "--terminal", target.terminal])
        let status = try await app(target, executable: appExecutable, ["status"])
        guard let object = try JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: Any],
              object["agent"] as? String == target.terminal,
              object["space"] as? String == terminal.labels["herdr.space"],
              object["tab"] as? String == terminal.labels["herdr.tab"] else { throw NavigationError.terminalNotFound }
        try Task.checkCancellation()
        activateHerdr()
    }

    private func app(_ target: HerdrTarget, executable: String, _ command: [String]) async throws -> String {
        try await runner.run("/usr/bin/env", HerdrCLI.appArguments(target, executable: executable, command: command))
    }
}
