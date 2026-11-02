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
        // Do not flood NEW on launch with sessions completed before the app started.
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
        // Resumed work invalidates a completion not yet acknowledged.
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

        // Acknowledged sessions remaining done must not regain NEW on the next refresh.
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

        // A disappeared/reappeared done session has no observed transition, so it is not NEW.
        tracker.ingest([Self.session("a", .done)])
        #expect(tracker.unseen.isEmpty)
    }

    @Test func doneThroughUnknownBackToDoneKeepsNew() {
        // An unreadable interval must not erase an unacknowledged completion.
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
        // An unknown interval must not resurrect an already acknowledged completion.
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
        // Missing work completed during an unreadable interval is worse than an extra notification.
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


    // MARK: Send failures (v1.2 design §4.7)

    @Test func failedSessionsLeaveStatusCounts() {
        let tracker = SignalTracker()
        let sessions = [Self.session("a", .waiting), Self.session("b", .waiting), Self.session("c", .running)]
        let summary = tracker.summary(of: sessions, failed: [Self.key("a")])
        #expect(summary.waiting == 1)
        #expect(summary.running == 1)
        #expect(summary.failed == 1)
        #expect(summary.attention)
    }

    @Test func failureAloneDrawsAttention() {
        let tracker = SignalTracker()
        let summary = tracker.summary(of: [Self.session("a", .running)], failed: [Self.key("a")])
        #expect(summary.running == 0)
        #expect(summary.failed == 1)
        #expect(summary.attention)
        #expect(!summary.isEmpty)
    }
}
