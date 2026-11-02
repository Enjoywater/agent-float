import Foundation
import Synchronization
@testable import AgentFloatCore

/// Fake runner records calls and returns configured outputs/errors.
actor FakeCommandRunner: CommandRunning {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    private(set) var calls: [Call] = []
    private let respond: @Sendable (Call) throws -> String

    init(_ respond: @escaping @Sendable (Call) throws -> String) {
        self.respond = respond
    }

    func run(_ executable: String, _ arguments: [String]) async throws -> String {
        let call = Call(executable: executable, arguments: arguments)
        calls.append(call)
        return try respond(call)
    }
}

/// Model ancestry with a child-to-parent map; absent entries have no parent.
struct FakeProcessInspector: ProcessInspecting {
    let parents: [Int32: Int32]

    func isAlive(pid: Int32, procStart: String?) -> Bool { true }
    func environment(pid: Int32) -> [String: String] { [:] }
    func parentPid(of pid: Int32) -> Int32? { parents[pid] }
}

/// Thread-safe storage for Sendable closures to record calls and arguments.
final class CallLog<Element: Sendable>: Sendable {
    private let storage = Mutex<[Element]>([])

    func append(_ element: Element) {
        storage.withLock { $0.append(element) }
    }

    var entries: [Element] { storage.withLock { $0 } }
}

/// Inject navigation behavior for checks involving completion, timing, or failure.
struct ScriptedNavigator: TerminalNavigator {
    let behavior: @Sendable () async throws -> Void

    func canNavigate(_ session: AgentSession) -> Bool { true }
    func navigate(to session: AgentSession) async throws { try await behavior() }
}

func makeSession(
    locator: TerminalLocator,
    title: String = "세션",
    cwd: String = "/Users/me/work",
    sessionId: String = "s1"
) -> AgentSession {
    AgentSession(
        key: SessionKey(providerId: "claude-code", sessionId: sessionId),
        agentName: "Claude",
        title: title,
        cwd: cwd,
        status: .running,
        waitReason: nil,
        statusSince: Date(timeIntervalSince1970: 1_800_000_000),
        isStale: false,
        lastActivityAt: nil,
        terminalApp: .unknown,
        locator: locator
    )
}
