import Foundation
import Synchronization

/// Combine provider results while isolating failures so one cannot remove another's sessions.
public final class SessionStore: Sendable {
    private let providers: [any AgentProvider]
    // Disambiguate duplicate provider IDs by index so their prior results cannot overwrite each other.
    private let lastResults = Mutex<[Int: [AgentSession]]>([:])

    public init(providers: [any AgentProvider]) {
        self.providers = providers
    }

    public var watchedDirectories: [URL] {
        providers.flatMap(\.watchedDirectories)
    }

    /// Ask only the originating provider; identical IDs in another agent's history could falsely verify a reply.
    public func recordedAnswer(for key: SessionKey, promptId: String) -> RecordedAnswer? {
        for provider in providers where provider.id == key.providerId {
            if let reader = provider as? any AnswerRecordReading,
               let answer = reader.recordedAnswer(sessionId: key.sessionId, promptId: promptId) {
                return answer
            }
        }
        return nil
    }

    /// Leave sorting to the presentation layer.
    public func snapshot(now: Date) -> [AgentSession] {
        var merged: [AgentSession] = []
        for (index, provider) in providers.enumerated() {
            do {
                let fresh = try provider.snapshot(now: now)
                lastResults.withLock { $0[index] = fresh }
                merged += fresh
            } catch {
                // Retain prior results on transient errors to avoid an empty-widget flicker.
                merged += lastResults.withLock { $0[index] } ?? []
            }
        }
        return merged
    }
}
