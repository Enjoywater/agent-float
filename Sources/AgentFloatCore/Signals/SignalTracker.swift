import Foundation

/// 위젯 알약에 표시할 요약. ASK/NEW 는 숫자와 별개로 주의를 끄는 신호다
public struct PillSummary: Equatable, Sendable {
    public let waiting: Int, running: Int, done: Int, unknown: Int
    public let ask: Bool, new: Bool
    public var attention: Bool { ask || new }
    public var isEmpty: Bool { waiting + running + done + unknown == 0 }

    // 암시적 memberwise init 은 internal 이라 앱 타깃(프리뷰 포함)에서 쓸 수 있게 명시한다
    public init(waiting: Int, running: Int, done: Int, unknown: Int, ask: Bool, new: Bool) {
        self.waiting = waiting
        self.running = running
        self.done = done
        self.unknown = unknown
        self.ask = ask
        self.new = new
    }
}

/// 세션 목록이 갱신될 때마다 상태 전이를 지켜보며 "내가 아직 확인하지 않은 완료"를 기억한다
public struct SignalTracker: Sendable {
    public private(set) var unseen: Set<SessionKey> = []

    // unknown 은 담지 않고 세션마다 마지막으로 확인된 상태만 둔다. 판독 불가 구간을 건너뛰고도 전이를 판정하려는 것이다
    private var lastKnownStatuses: [SessionKey: AgentStatus] = [:]

    public init() {}

    public mutating func ingest(_ sessions: [AgentSession]) {
        let current = Dictionary(sessions.map { ($0.key, $0.status) }, uniquingKeysWith: { _, latest in latest })
        // 첫 호출은 기억이 비어 있어 어떤 세션도 전이로 판정되지 않는다. 앱을 켜기 전에 끝난 세션이 NEW 로 쏟아지지 않는다
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
                // 확인하기 전에 다시 일을 시작했다면 지난 완료는 더 이상 의미가 없다
                unseen.remove(key)
                known[key] = status
            case .unknown:
                // unknown 은 "확인함"도 "완료"도 아니다. unseen 을 건드리면 알림이 근거 없이 사라지거나 생기고,
                // 직전 상태를 덮어쓰면 running → unknown → done 의 완료를 놓친다
                known[key] = previous[key]
            }
        }
        // 목록에서 사라진 세션은 기억에서도 빠진다
        lastKnownStatuses = known
    }

    public mutating func markSeen(_ key: SessionKey) {
        unseen.remove(key)
    }

    public func summary(of sessions: [AgentSession]) -> PillSummary {
        let waiting = sessions.count { $0.status == .waiting }
        // unseen 에 남은 키라도 지금 done 이 아니면(예: unknown) 알림으로 보이지 않게 교차시킨다
        let hasNew = sessions.contains { $0.status == .done && unseen.contains($0.key) }
        return PillSummary(
            waiting: waiting,
            running: sessions.count { $0.status == .running },
            done: sessions.count { $0.status == .done },
            unknown: sessions.count { $0.status == .unknown },
            ask: waiting > 0,
            new: hasNew
        )
    }
}
