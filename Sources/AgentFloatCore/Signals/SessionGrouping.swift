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
    /// Group by AgentStatus declaration order and omit empty groups.
    public static func groups(_ sessions: [AgentSession], excluding failed: Set<SessionKey> = []) -> [SessionGroup] {
        AgentStatus.allCases.compactMap { status in
            let members = sessions.filter { $0.status == status && !failed.contains($0.key) }
            guard !members.isEmpty else { return nil }
            return SessionGroup(status: status, sessions: members.sorted(by: ordering(for: status)))
        }
    }

    /// Needs-attention group, most recently failed first.
    public static func failed(_ failed: Set<SessionKey>, among sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter { failed.contains($0.key) }.sorted(by: ordering(for: .done))
    }

    private static func ordering(for status: AgentStatus) -> (AgentSession, AgentSession) -> Bool {
        // Longest-waiting sessions first; other states sort by most recent transition.
        let oldestFirst = status == .waiting
        return { lhs, rhs in
            if lhs.statusSince != rhs.statusSince {
                return oldestFirst ? lhs.statusSince < rhs.statusSince : lhs.statusSince > rhs.statusSince
            }
            // Use locale-independent ordering so identical input always yields identical presentation.
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
