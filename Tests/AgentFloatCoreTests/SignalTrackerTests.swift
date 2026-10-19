import Foundation
import Testing
@testable import AgentFloatCore

@Suite struct SignalTrackerTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func key(_ id: String) -> SessionKey {
        SessionKey(providerId: "claude", sessionId: id)
    }

    private static func session(_ id: String, _ status: AgentStatus) -> AgentSession {
        AgentSession(
            key: key(id),
            agentName: "claude",
            title: id,
            cwd: "/Users/me/work",
            status: status,
            waitReason: nil,
            statusSince: now,
            isStale: false,
            lastActivityAt: nil,
            terminalApp: .unknown,
            locator: .none
        )
    }

    @Test func firstIngestMarksNothingNew() {
        // 앱을 켜기 전에 이미 끝난 세션까지 NEW 로 띄우면 켤 때마다 알림이 쏟아진다
        let sessions = [Self.session("a", .done), Self.session("b", .running), Self.session("c", .waiting)]
        var tracker = SignalTracker()
        tracker.ingest(sessions)

        #expect(tracker.unseen.isEmpty)
        #expect(tracker.summary(of: sessions).new == false)
    }

    @Test func runningToDoneBecomesNew() {
        var tracker = SignalTracker()
        tracker.ingest([Self.session("a", .running)])
        let finished = [Self.session("a", .done)]
        tracker.ingest(finished)

        #expect(tracker.unseen == [Self.key("a")])
        let summary = tracker.summary(of: finished)
        #expect(summary.new)
        #expect(summary.ask == false)
        #expect(summary.attention)
    }

    @Test func waitingToDoneBecomesNew() {
        var tracker = SignalTracker()
        tracker.ingest([Self.session("a", .waiting)])
        let finished = [Self.session("a", .done)]
        tracker.ingest(finished)

        #expect(tracker.unseen == [Self.key("a")])
        #expect(tracker.summary(of: finished).new)
    }

    @Test(arguments: [AgentStatus.running, .waiting])
    func doneToActiveClearsNew(resumed: AgentStatus) {
        // 사용자가 보기 전에 같은 세션이 다시 일을 시작하면 지난 완료는 더 이상 의미가 없다
        var tracker = SignalTracker()
        tracker.ingest([Self.session("a", .running)])
        tracker.ingest([Self.session("a", .done)])
        #expect(tracker.unseen == [Self.key("a")])

        let resumedSessions = [Self.session("a", resumed)]
        tracker.ingest(resumedSessions)

        #expect(tracker.unseen.isEmpty)
        #expect(tracker.summary(of: resumedSessions).new == false)
    }

    @Test func markSeenClearsOnlyThatSession() {
        var tracker = SignalTracker()
        tracker.ingest([Self.session("a", .running), Self.session("b", .running)])
        let finished = [Self.session("a", .done), Self.session("b", .done)]
        tracker.ingest(finished)
        #expect(tracker.unseen == [Self.key("a"), Self.key("b")])

        tracker.markSeen(Self.key("a"))
        #expect(tracker.unseen == [Self.key("b")])
        #expect(tracker.summary(of: finished).new)

        tracker.markSeen(Self.key("b"))
        #expect(tracker.unseen.isEmpty)
        #expect(tracker.summary(of: finished).new == false)

        // 확인한 세션이 done 으로 남아 있어도 다음 갱신에서 NEW 로 되살아나면 안 된다
        tracker.ingest(finished)
        #expect(tracker.unseen.isEmpty)
    }

    @Test func vanishedSessionIsForgotten() {
        var tracker = SignalTracker()
        tracker.ingest([Self.session("a", .running)])
        tracker.ingest([Self.session("a", .done)])
        #expect(tracker.unseen == [Self.key("a")])

        tracker.ingest([])
        #expect(tracker.unseen.isEmpty)

        // 사라진 뒤 다시 나타난 done 세션은 전이를 본 적이 없으므로 NEW 가 아니다
        tracker.ingest([Self.session("a", .done)])
        #expect(tracker.unseen.isEmpty)
    }

    @Test func doneThroughUnknownBackToDoneKeepsNew() {
        // 읽을 수 없던 구간이 있었다고 아직 확인하지 않은 완료가 사라지면 안 된다
        var tracker = SignalTracker()
        tracker.ingest([Self.session("a", .running)])
        tracker.ingest([Self.session("a", .done)])

        tracker.ingest([Self.session("a", .unknown)])
        #expect(tracker.unseen == [Self.key("a")])

        let backToDone = [Self.session("a", .done)]
        tracker.ingest(backToDone)
        #expect(tracker.unseen == [Self.key("a")])
        #expect(tracker.summary(of: backToDone).new)
    }

    @Test func seenSessionStaysSeenAcrossUnknown() {
        // unknown 을 거쳤다는 이유만으로 이미 확인한 완료가 새 알림으로 되살아나면 안 된다
        var tracker = SignalTracker()
        tracker.ingest([Self.session("a", .running)])
        tracker.ingest([Self.session("a", .done)])
        tracker.markSeen(Self.key("a"))

        tracker.ingest([Self.session("a", .unknown)])
        let backToDone = [Self.session("a", .done)]
        tracker.ingest(backToDone)

        #expect(tracker.unseen.isEmpty)
        #expect(tracker.summary(of: backToDone).new == false)
    }

    @Test func runningThroughUnknownToDoneBecomesNew() {
        // 판독 불가 구간에 끝난 일을 놓치는 쪽이 알림이 한 번 더 뜨는 쪽보다 나쁘다
        var tracker = SignalTracker()
        tracker.ingest([Self.session("a", .running)])
        tracker.ingest([Self.session("a", .unknown)])
        #expect(tracker.unseen.isEmpty)

        let finished = [Self.session("a", .done)]
        tracker.ingest(finished)

        #expect(tracker.unseen == [Self.key("a")])
        #expect(tracker.summary(of: finished).new)
    }

    @Test func waitingThroughUnknownToDoneBecomesNew() {
        var tracker = SignalTracker()
        tracker.ingest([Self.session("a", .waiting)])
        tracker.ingest([Self.session("a", .unknown)])
        #expect(tracker.unseen.isEmpty)

        let finished = [Self.session("a", .done)]
        tracker.ingest(finished)

        #expect(tracker.unseen == [Self.key("a")])
        #expect(tracker.summary(of: finished).new)
    }

    @Test func askIsTrueWhileAnyWaiting() {
        let tracker = SignalTracker()

        #expect(tracker.summary(of: []).ask == false)
        #expect(tracker.summary(of: [Self.session("a", .running), Self.session("b", .done)]).ask == false)

        let withWaiting = [Self.session("a", .running), Self.session("b", .waiting), Self.session("c", .waiting)]
        let summary = tracker.summary(of: withWaiting)
        #expect(summary.ask)
        #expect(summary.attention)
        #expect(summary.waiting == 2)
    }

    @Test func summaryCountsEachStatus() {
        let tracker = SignalTracker()
        let sessions = [
            Self.session("a", .waiting),
            Self.session("b", .running), Self.session("c", .running),
            Self.session("d", .done), Self.session("e", .done), Self.session("f", .done),
            Self.session("g", .unknown),
        ]
        let summary = tracker.summary(of: sessions)

        #expect(summary.waiting == 1)
        #expect(summary.running == 2)
        #expect(summary.done == 3)
        #expect(summary.unknown == 1)
        #expect(summary.isEmpty == false)
        #expect(tracker.summary(of: []).isEmpty)
        #expect(tracker.summary(of: []).attention == false)
    }
}
