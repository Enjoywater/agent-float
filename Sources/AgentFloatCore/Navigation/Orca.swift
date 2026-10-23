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

    /// `{"result":{"terminals":[{handle,tabId,leafId,…}]}}`. 이동에 필요한 세 값이 없는 항목은 건너뛴다
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

    /// handle 을 먼저 본다. tab·leaf 는 워크트리를 열기 전까지 임시 값이라 그것만으로는 있는 터미널도 못 찾는다
    public static func match(tabId: String, leafId: String, handle: String? = nil, in terminals: [OrcaTerminal]) -> OrcaTerminal? {
        if let handle, let byHandle = terminals.first(where: { $0.handle == handle }) {
            return byHandle
        }
        return terminals.first { $0.tabId == tabId && $0.leafId == leafId }
    }

    /// `{"ok":true,"result":{"terminal":{"tail":[줄…],"draft":"…","source":"screen"}}}`. `draft` 는 Orca 입력창에 글이 있을 때만 온다 (실측 ⑫).
    /// `source` 가 `screen` 이 아니면 렌더된 화면이 아니다 — `screen-unavailable` 은 겹쳐 쓴 조각이 쌓인 누적 출력이고, 없으면 그 구분을 모르는 옛 Orca 다
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

    /// 항목 하나의 필드 타입이 어긋나도 목록 전체를 버리지 않도록 필드별로 관대하게 읽는다
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
        // 기본 페이지 크기가 문서에 없어, 터미널이 많아져 목록이 잘리면 있는 탭도 못 찾게 된다 (R26)
        let listing = try await runner.run(OrcaCLI.executable, ["terminal", "list", "--json", "--limit", "1000"])
        let terminals = try OrcaCLI.parseTerminalList(Data(listing.utf8))
        guard let target = OrcaCLI.match(tabId: tabId, leafId: leafId, handle: handle, in: terminals) else {
            throw NavigationError.terminalNotFound
        }
        _ = try await runner.run(OrcaCLI.executable, ["terminal", "switch", "--terminal", target.handle])
        // switch 는 Orca 안의 선택만 바꾸므로 창을 앞으로 올리는 일은 앱이 한다
        activateOrca()
    }
}
