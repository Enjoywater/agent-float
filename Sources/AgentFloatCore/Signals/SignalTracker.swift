import Foundation

/// Pill summary; ASK/NEW are attention signals independent of counts.
public struct PillSummary: Equatable, Sendable {
    public let waiting: Int, running: Int, done: Int, unknown: Int
    public let ask: Bool, new: Bool
    /// Interrupted/mismatched delivery count persists until acknowledged (v1.2 design §4.7).
    public let failed: Int
    public var attention: Bool { ask || new || failed > 0 }
    public var isEmpty: Bool { waiting + running + done + unknown + failed == 0 }

    // Expose construction to the app target and previews because implicit memberwise init is internal.
    public init(waiting: Int, running: Int, done: Int, unknown: Int, ask: Bool, new: Bool, failed: Int = 0) {
        self.waiting = waiting
        self.running = running
        self.done = done
        self.unknown = unknown
        self.ask = ask
        self.new = new
        self.failed = failed
    }
}

/// Observe status transitions and remember completions not yet acknowledged.
public struct SignalTracker: Sendable {
    public private(set) var unseen: Set<SessionKey> = []

    // Retain only confirmed states, skipping unknown intervals when detecting transitions.
    private var lastKnownStatuses: [SessionKey: AgentStatus] = [:]

    public init() {}

    public mutating func ingest(_ sessions: [AgentSession]) {
        let current = Dictionary(sessions.map { ($0.key, $0.status) }, uniquingKeysWith: { _, latest in latest })
        // The first snapshot seeds history without transitions, preventing NEW floods from pre-launch completions.
        let previous = lastKnownStatuses
        var known: [SessionKey: AgentStatus] = [:]

        unseen.formIntersection(current.keys)
        for (key, status) in current {
            switch status {
            case .done:
                if let before = previous[key], before == .running || before == .waiting {
                    unseen.insert(key)
                }
                known[key] = status
            case .running, .waiting:
                // A completion is no longer relevant if work resumed before acknowledgment.
                unseen.remove(key)
                known[key] = status
            case .unknown:
                // Unknown means neither acknowledged nor completed; changing unseen would create or remove unsupported alerts,
                // and overwriting prior state would miss running-to-unknown-to-done completions.
                known[key] = previous[key]
            }
        }
        // Prune history for disappeared sessions.
        lastKnownStatuses = known
    }

    public mutating func markSeen(_ key: SessionKey) {
        unseen.remove(key)
    }

    /// Count failed sessions separately from status groups, matching their exclusive needs-attention placement.
    public func summary(of all: [AgentSession], failed: Set<SessionKey> = []) -> PillSummary {
        let sessions = all.filter { !failed.contains($0.key) }
        let waiting = sessions.count { $0.status == .waiting }
        // Intersect unseen with currently done sessions so unknown states cannot display completion alerts.
        let hasNew = sessions.contains { $0.status == .done && unseen.contains($0.key) }
        return PillSummary(
            waiting: waiting,
            running: sessions.count { $0.status == .running },
            done: sessions.count { $0.status == .done },
            unknown: sessions.count { $0.status == .unknown },
            ask: waiting > 0,
            new: hasNew,
            failed: all.count { failed.contains($0.key) }
        )
    }
}
