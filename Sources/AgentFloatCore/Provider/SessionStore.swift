import Foundation
import Synchronization

/// provider 여러 개의 결과를 이어붙인다. 한 provider 의 실패가 다른 provider 의 세션을 지우지 않도록 격리한다
public final class SessionStore: Sendable {
    private let providers: [any AgentProvider]
    // provider id 가 겹쳐도 서로의 직전 결과를 덮지 않도록 순번으로 구분한다
    private let lastResults = Mutex<[Int: [AgentSession]]>([:])

    public init(providers: [any AgentProvider]) {
        self.providers = providers
    }

    public var watchedDirectories: [URL] {
        providers.flatMap(\.watchedDirectories)
    }

    /// 세션을 만든 provider 에게만 묻는다. 다른 에이전트의 기록에서 같은 id 를 찾으면 엉뚱한 답을 맞다고 볼 수 있다
    public func recordedAnswer(for key: SessionKey, promptId: String) -> RecordedAnswer? {
        for provider in providers where provider.id == key.providerId {
            if let reader = provider as? any AnswerRecordReading,
               let answer = reader.recordedAnswer(sessionId: key.sessionId, promptId: promptId) {
                return answer
            }
        }
        return nil
    }

    /// 정렬은 하지 않는다. 화면 순서는 표시 계층이 정한다
    public func snapshot(now: Date) -> [AgentSession] {
        var merged: [AgentSession] = []
        for (index, provider) in providers.enumerated() {
            do {
                let fresh = try provider.snapshot(now: now)
                lastResults.withLock { $0[index] = fresh }
                merged += fresh
            } catch {
                // 일시적 오류로 목록이 비면 위젯이 깜빡이므로 직전 결과를 유지한다
                merged += lastResults.withLock { $0[index] } ?? []
            }
        }
        return merged
    }
}
