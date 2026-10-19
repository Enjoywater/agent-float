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
