import Foundation
import Synchronization

/// 공유 app-server의 실제 런타임 상태를 읽는다. 저장된 대화 목록이나 mtime은 생존 증거로 쓰지 않는다.
public final class CodexCodeProvider: AgentProvider, AnswerRecordReading, Sendable {
    public let id = "codex"
    public var watchedDirectories: [URL] { [codexHome.appendingPathComponent("app-server-control")] }

    private let codexHome: URL
    private let makeClient: @Sendable () throws -> (any CodexRPC)?
    private let terminalInventory: @Sendable () throws -> CodexTerminalInventory?
    private let cache = Mutex<[String: AgentSession]>([:])
    private let errorMessage = Mutex<String?>(nil)
    private let transcriptPaths = Mutex<[String: String]>([:])
    /// UI 없이 탐지 연결을 진단할 때 사용한다. 연결 성공 또는 소켓 부재 시 nil.
    public var lastError: String? { errorMessage.withLock { $0 } }

    public init(codexHome: URL) {
        self.codexHome = codexHome
        terminalInventory = { try CodexTerminalInventory.live(codexHome: codexHome) }
        let socket = codexHome.appendingPathComponent("app-server-control/app-server-control.sock").path
        makeClient = {
            guard FileManager.default.fileExists(atPath: socket) else { return nil }
            return try CodexSocketRPC(path: socket)
        }
    }

    init(codexHome: URL, terminalInventory: @escaping @Sendable () throws -> CodexTerminalInventory? = { nil }, makeClient: @escaping @Sendable () throws -> (any CodexRPC)?) {
        self.codexHome = codexHome
        self.makeClient = makeClient
        self.terminalInventory = terminalInventory
    }

    public func snapshot(now: Date) throws -> [AgentSession] {
        cache.withLock { previous in
            do {
                errorMessage.withLock { $0 = nil }
                guard let client = try makeClient() else {
                    previous = [:]
                    return []
                }
                _ = try client.call("initialize", params: Data(#"{"clientInfo":{"name":"agent_float","title":"Agent Float","version":"1"}}"#.utf8))
                try client.notify("initialized")
                var ids: Set<String> = []
                var cursor: String?
                var cursors: Set<String> = []
                repeat {
                    var params: [String: Any] = ["limit": 100]
                    if let cursor { params["cursor"] = cursor }
                    let page = try JSONDecoder().decode(LoadedPage.self, from: client.call(
                        "thread/loaded/list", params: JSONSerialization.data(withJSONObject: params)
                    ))
                    ids.formUnion(page.data)
                    cursor = page.nextCursor
                    if let cursor, !cursors.insert(cursor).inserted { throw CodexRPCError.invalidResponse }
                } while cursor != nil

                let terminals = try terminalInventory()
                var sessions: [String: AgentSession] = [:]
                for id in ids.sorted() {
                    let params = try JSONSerialization.data(withJSONObject: ["threadId": id, "includeTurns": false])
                    let response: ThreadResponse
                    do {
                        response = try JSONDecoder().decode(ThreadResponse.self, from: client.call("thread/read", params: params))
                    } catch CodexRPCError.server(let code) where code == -32602 {
                        // 목록을 읽은 직후 내려간 세션을 다시 로드하지 않는다.
                        continue
                    }
                    let thread = response.thread
                    guard thread.id == id else { throw CodexRPCError.invalidResponse }
                    guard thread.status.type != "notLoaded", thread.parentThreadId == nil, !thread.source.isSubagent else { continue }
                    let placement = terminals?.placement(title: thread.name, cwd: thread.cwd)
                    if terminals != nil, placement == nil { continue }
                    let tail = thread.path.flatMap { try? CodexTranscript.read(path: $0, sessionID: id) }
                    if let path = thread.path { transcriptPaths.withLock { $0[id] = path } }
                    var derived = thread.status.derived
                    var prompt: PendingPrompt?
                    if derived.status == .waiting, derived.reason == .question { prompt = tail?.pendingChoice }
                    if derived.status == .waiting, derived.reason == .permission {
                        prompt = .permission(id: tail?.latestTool?.id ?? "codex:\(id):permission", tool: tail?.latestTool?.name ?? "Codex", summary: tail?.latestTool?.summary ?? "Codex가 승인을 기다리고 있습니다.")
                    }
                    if derived.status == .done, let message = tail?.lastMessage, QuestionHeuristic.endsWithQuestion(message.text) {
                        derived = (.waiting, .bodyQuestion)
                        prompt = .text(id: message.id, message: message.text)
                    }
                    let old = previous[id]
                    let since: Date
                    if let old, old.status == derived.status, old.waitReason == derived.reason {
                        since = old.statusSince
                    } else {
                        since = now
                    }
                    sessions[id] = AgentSession(
                        key: SessionKey(providerId: self.id, sessionId: id), agentName: "Codex",
                        title: Self.nonEmpty(thread.name) ?? Self.nonEmpty(thread.preview).map { String($0.prefix(120)) } ?? "이름 없는 세션",
                        cwd: thread.cwd, status: derived.status, waitReason: derived.reason,
                        statusSince: since, isStale: false,
                        lastActivityAt: Date(timeIntervalSince1970: thread.updatedAt),
                        terminalApp: placement?.app ?? .unknown, locator: placement?.locator ?? .none, prompt: prompt
                    )
                }
                previous = sessions
                transcriptPaths.withLock { paths in paths = paths.filter { sessions[$0.key] != nil } }
            } catch {
                errorMessage.withLock { $0 = String(describing: error) }
                // SessionStore의 오류 폴백은 이전 running을 유지한다. 여기서는 관측 실패를 명시한다.
                previous = previous.mapValues { old in
                    AgentSession(
                        key: old.key, agentName: old.agentName, title: old.title, cwd: old.cwd,
                        status: .unknown, waitReason: nil,
                        statusSince: old.status == .unknown ? old.statusSince : now, isStale: true,
                        lastActivityAt: old.lastActivityAt, terminalApp: .unknown, locator: .none
                    )
                }
            }
            return previous.values.sorted { $0.key.sessionId < $1.key.sessionId }
        }
    }

    public func recordedAnswer(sessionId: String, promptId: String) -> RecordedAnswer? {
        guard let path = transcriptPaths.withLock({ $0[sessionId] }) else { return nil }
        return (try? CodexTranscript.read(path: path, sessionID: sessionId))?.records[promptId]
    }

    private static func nonEmpty(_ text: String?) -> String? {
        text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
}

private struct LoadedPage: Decodable {
    let data: [String]
    let nextCursor: String?
}

private struct ThreadResponse: Decodable {
    let thread: CodexThread
}

private struct CodexThread: Decodable {
    let id: String
    let name: String?
    let preview: String?
    let cwd: String
    let updatedAt: TimeInterval
    let parentThreadId: String?
    let path: String?
    let source: Source
    let status: Status

    struct Source: Decodable {
        let isSubagent: Bool
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let name = try? container.decode(String.self) {
                isSubagent = name.lowercased().hasPrefix("subagent")
            } else {
                let keys = try decoder.container(keyedBy: SourceKey.self)
                isSubagent = keys.contains(.subAgent)
            }
        }
        enum SourceKey: String, CodingKey { case subAgent }
    }

    struct Status: Decodable {
        let type: String
        let activeFlags: [String]?

        var derived: (status: AgentStatus, reason: WaitReason?) {
            switch type {
            case "idle": return (.done, nil)
            case "active":
                guard let activeFlags, activeFlags.allSatisfy({ ["waitingOnApproval", "waitingOnUserInput"].contains($0) }) else {
                    return (.unknown, nil)
                }
                if activeFlags.contains("waitingOnApproval") { return (.waiting, .permission) }
                if activeFlags.contains("waitingOnUserInput") { return (.waiting, .question) }
                return (.running, nil)
            default: return (.unknown, nil)
            }
        }
    }
}
