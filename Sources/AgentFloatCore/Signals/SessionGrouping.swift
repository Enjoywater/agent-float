import Foundation

public struct SessionGroup: Equatable, Sendable {
    public let status: AgentStatus
    public let sessions: [AgentSession]

    public init(status: AgentStatus, sessions: [AgentSession]) {
        self.status = status
        self.sessions = sessions
    }
}

public enum SessionGrouping {
    /// AgentStatus 선언 순서(대기 → 진행 → 완료 → 알 수 없음)대로 묶고, 세션이 없는 상태는 생략한다
    public static func groups(_ sessions: [AgentSession]) -> [SessionGroup] {
        AgentStatus.allCases.compactMap { status in
            let members = sessions.filter { $0.status == status }
            guard !members.isEmpty else { return nil }
            return SessionGroup(status: status, sessions: members.sorted(by: ordering(for: status)))
        }
    }

    private static func ordering(for status: AgentStatus) -> (AgentSession, AgentSession) -> Bool {
        // 대기는 오래 기다리게 한 쪽이 먼저, 나머지는 방금 바뀐 쪽이 먼저
        let oldestFirst = status == .waiting
        return { lhs, rhs in
            if lhs.statusSince != rhs.statusSince {
                return oldestFirst ? lhs.statusSince < rhs.statusSince : lhs.statusSince > rhs.statusSince
            }
            // 로케일에 따라 순서가 달라지는 비교 대신 고정된 순서를 써야 같은 입력에 같은 화면이 나온다
            if lhs.title != rhs.title {
                return lhs.title < rhs.title
            }
            if lhs.key.providerId != rhs.key.providerId {
                return lhs.key.providerId < rhs.key.providerId
            }
            return lhs.key.sessionId < rhs.key.sessionId
        }
    }
}
