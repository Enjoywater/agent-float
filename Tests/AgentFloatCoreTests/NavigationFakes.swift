import Foundation
import Synchronization
@testable import AgentFloatCore

/// 실행 기록을 남기고 호출마다 미리 정한 출력(또는 오류)을 돌려주는 가짜 명령 실행기
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

/// 자식 → 부모 표로 조상 순회를 흉내 낸다. 표에 없는 pid 는 부모가 없는 것으로 본다
struct FakeProcessInspector: ProcessInspecting {
    let parents: [Int32: Int32]

    func isAlive(pid: Int32, procStart: String?) -> Bool { true }
    func environment(pid: Int32) -> [String: String] { [:] }
    func parentPid(of pid: Int32) -> Int32? { parents[pid] }
}

/// `@Sendable` 클로저가 호출 여부와 인자를 남길 수 있게 하는 상자
final class CallLog<Element: Sendable>: Sendable {
    private let storage = Mutex<[Element]>([])

    func append(_ element: Element) {
        storage.withLock { $0.append(element) }
    }

    var entries: [Element] { storage.withLock { $0 } }
}

/// 지정한 동작으로 이동을 흉내 낸다. 제한 시간 처리처럼 이동 자체의 결과·소요 시간이 중요한 경우에 쓴다
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
