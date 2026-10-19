public protocol TerminalNavigator: Sendable {
    func canNavigate(_ session: AgentSession) -> Bool
    func navigate(to session: AgentSession) async throws
}

public struct NavigatorRegistry: Sendable {
    private let navigators: [any TerminalNavigator]

    public init(_ navigators: [any TerminalNavigator]) {
        self.navigators = navigators
    }

    public func canNavigate(_ session: AgentSession) -> Bool {
        navigators.contains { $0.canNavigate(session) }
    }

    /// 담당자가 실패하면 그대로 올린다. 다른 담당자로 넘기면 엉뚱한 터미널을 앞으로 올릴 수 있다
    public func navigate(to session: AgentSession) async throws {
        guard let navigator = navigators.first(where: { $0.canNavigate(session) }) else {
            throw NavigationError.terminalNotFound
        }
        try await navigator.navigate(to: session)
    }

    /// 첫 실행의 자동화 승인 창처럼 사람이 답할 때까지 끝나지 않는 이동이 있어 시간을 제한한다.
    /// 시간이 다 되면 이동을 취소해 실행 중인 명령까지 종료시킨 뒤 `timedOut` 을 던진다 (R23)
    public func navigate(to session: AgentSession, timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await navigate(to: session) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NavigationError.timedOut
            }
            // 먼저 끝난 쪽이 결과다. 남은 쪽은 취소되고, 그 결과는 그룹이 끝날 때 버려진다
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
