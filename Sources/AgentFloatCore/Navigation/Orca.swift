import Foundation

public struct OrcaTerminal: Equatable, Sendable {
    public let handle: String
    public let tabId: String
    public let leafId: String

    public init(handle: String, tabId: String, leafId: String) {
        self.handle = handle
        self.tabId = tabId
        self.leafId = leafId
    }
}

public enum OrcaCLI {
    public static let executable = "/usr/local/bin/orca"

    /// Parse result.terminals entries with handle/tabId/leafId; skip entries lacking required routing fields.
    public static func parseTerminalList(_ json: Data) throws -> [OrcaTerminal] {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: json) else {
            throw NavigationError.commandFailed("unreadable orca output")
        }
        if envelope.ok == false { throw NavigationError.commandFailed("orca reported a failure") }
        guard let entries = envelope.result?.terminals else {
            throw NavigationError.commandFailed("orca output has no terminal list")
        }
        return entries.compactMap { entry in
            guard let handle = entry.handle, let tabId = entry.tabId, let leafId = entry.leafId else { return nil }
            return OrcaTerminal(handle: handle, tabId: tabId, leafId: leafId)
        }
    }

    /// Prefer stable handles because unopened worktrees may use temporary tab/leaf IDs.
    public static func match(tabId: String, leafId: String, handle: String? = nil, in terminals: [OrcaTerminal]) -> OrcaTerminal? {
        if let handle, let byHandle = terminals.first(where: { $0.handle == handle }) {
            return byHandle
        }
        return terminals.first { $0.tabId == tabId && $0.leafId == leafId }
    }

    /// Rendered terminal results include tail lines and an optional draft only when Orca's composer contains text (measurement 12).
    /// Require source=screen; screen-unavailable is accumulated repaint output, while missing source means an older unsupported Orca.
    public static func parseScreen(_ json: Data) throws -> ConsoleScreen {
        guard let envelope = try? JSONDecoder().decode(ScreenEnvelope.self, from: json) else {
            throw NavigationError.commandFailed("unreadable orca screen")
        }
        guard envelope.ok != false, let terminal = envelope.result?.terminal, let lines = terminal.tail else {
            throw NavigationError.commandFailed("orca screen has no lines")
        }
        guard terminal.source == "screen" else {
            throw NavigationError.commandFailed("orca returned no rendered screen (\(terminal.source ?? "no source"))")
        }
        let draft = terminal.draft.flatMap { $0.isEmpty ? nil : $0 }
        return ConsoleScreen(lines: lines, faint: nil, composerDraft: draft)
    }

    static func sendAccepted(_ json: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(SendEnvelope.self, from: json) else { return false }
        return envelope.ok != false && envelope.result?.send?.accepted == true
    }

    private struct ScreenEnvelope: Decodable {
        let ok: Bool?
        let result: Result?

        struct Result: Decodable {
            let terminal: Terminal?
        }

        struct Terminal: Decodable {
            let tail: [String]?
            let draft: String?
            let source: String?
        }
    }

    private struct SendEnvelope: Decodable {
        let ok: Bool?
        let result: Result?

        struct Result: Decodable {
            let send: Send?
        }

        struct Send: Decodable {
            let accepted: Bool?
        }
    }

    private struct Envelope: Decodable {
        let ok: Bool?
        let result: Result?

        struct Result: Decodable {
            let terminals: [Entry]?
        }
    }

    /// Decode fields tolerantly so one malformed entry cannot invalidate the full list.
    private struct Entry: Decodable {
        let handle: String?
        let tabId: String?
        let leafId: String?

        private enum Keys: String, CodingKey { case handle, tabId, leafId }

        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: Keys.self)
            handle = try? container?.decode(String.self, forKey: .handle)
            tabId = try? container?.decode(String.self, forKey: .tabId)
            leafId = try? container?.decode(String.self, forKey: .leafId)
        }
    }
}

public struct OrcaNavigator: TerminalNavigator {
    private let runner: any CommandRunning
    private let activateOrca: @Sendable () -> Void

    public init(runner: any CommandRunning, activateOrca: @escaping @Sendable () -> Void) {
        self.runner = runner
        self.activateOrca = activateOrca
    }

    public func canNavigate(_ session: AgentSession) -> Bool {
        if case .orca = session.locator { return true }
        return false
    }

    public func navigate(to session: AgentSession) async throws {
        guard case let .orca(tabId, leafId, handle) = session.locator else { throw NavigationError.terminalNotFound }
        // Request a large explicit limit because an undocumented default page size could hide valid terminals (R26).
        let listing = try await runner.run(OrcaCLI.executable, ["terminal", "list", "--json", "--limit", "1000"])
        let terminals = try OrcaCLI.parseTerminalList(Data(listing.utf8))
        guard let target = OrcaCLI.match(tabId: tabId, leafId: leafId, handle: handle, in: terminals) else {
            throw NavigationError.terminalNotFound
        }
        _ = try await runner.run(OrcaCLI.executable, ["terminal", "switch", "--terminal", target.handle])
        // Switch changes selection inside Orca only; the app must raise its window separately.
        activateOrca()
    }
}
