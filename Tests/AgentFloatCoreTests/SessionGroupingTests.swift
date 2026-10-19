import Foundation
import Testing
@testable import AgentFloatCore

@Suite struct SessionGroupingTests {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    private static func session(_ id: String, _ status: AgentStatus, minutesAgo: Double, title: String? = nil) -> AgentSession {
        AgentSession(
            key: SessionKey(providerId: "claude", sessionId: id),
            agentName: "claude",
            title: title ?? id,
            cwd: "/Users/me/work",
            status: status,
            waitReason: nil,
            statusSince: base.addingTimeInterval(-minutesAgo * 60),
            isStale: false,
            lastActivityAt: nil,
            terminalApp: .unknown,
            locator: .none
        )
    }

    private static func ids(_ group: SessionGroup) -> [String] {
        group.sessions.map(\.key.sessionId)
    }

    @Test func groupsOrderAndSorting() {
        // 입력은 일부러 화면 순서와 어긋나게 섞는다
        let sessions = [
            Self.session("done-old", .done, minutesAgo: 50),
            Self.session("unknown-1", .unknown, minutesAgo: 5),
            Self.session("wait-new", .waiting, minutesAgo: 2),
            Self.session("run-1", .running, minutesAgo: 10),
            Self.session("done-new", .done, minutesAgo: 3),
            Self.session("wait-old", .waiting, minutesAgo: 30),
        ]
        let groups = SessionGrouping.groups(sessions)

        #expect(groups.map(\.status) == [.waiting, .running, .done, .unknown])
        #expect(Self.ids(groups[0]) == ["wait-old", "wait-new"])
        #expect(Self.ids(groups[1]) == ["run-1"])
        #expect(Self.ids(groups[2]) == ["done-new", "done-old"])
        #expect(Self.ids(groups[3]) == ["unknown-1"])
    }

    @Test func emptyStatusesAreOmitted() {
        let groups = SessionGrouping.groups([
            Self.session("r", .running, minutesAgo: 1),
            Self.session("d", .done, minutesAgo: 1),
        ])

        #expect(groups.map(\.status) == [.running, .done])
        #expect(SessionGrouping.groups([]).isEmpty)
    }

    @Test func runningIsNewestFirstAndTiesFallBackToTitle() {
        let running = SessionGrouping.groups([
            Self.session("r-old", .running, minutesAgo: 20),
            Self.session("r-new", .running, minutesAgo: 1),
        ])
        #expect(Self.ids(running[0]) == ["r-new", "r-old"])

        // 같은 시각이면 입력 순서와 무관하게 제목 순으로 고정되어야 화면이 깜빡이지 않는다
        let tied = SessionGrouping.groups([
            Self.session("x1", .waiting, minutesAgo: 5, title: "beta"),
            Self.session("x2", .waiting, minutesAgo: 5, title: "alpha"),
            Self.session("x3", .done, minutesAgo: 5, title: "gamma"),
            Self.session("x4", .done, minutesAgo: 5, title: "delta"),
        ])
        #expect(Self.ids(tied[0]) == ["x2", "x1"])
        #expect(Self.ids(tied[1]) == ["x4", "x3"])
    }
}
