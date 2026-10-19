import Foundation
import Synchronization
import Testing
@testable import AgentFloatCore

private struct ProviderFailure: Error {}

/// 호출마다 지정된 결과를 돌려주거나 던진다. 던진 뒤에도 직전 결과가 살아남는지 확인하려면 결과를 중간에 바꿀 수 있어야 한다
private final class ScriptedProvider: AgentProvider, Sendable {
    let id: String
    let watchedDirectories: [URL]
    private let outcome: Mutex<Result<[AgentSession], any Error>>

    init(id: String, watching: [URL] = [], outcome: Result<[AgentSession], any Error>) {
        self.id = id
        watchedDirectories = watching
        self.outcome = Mutex(outcome)
    }

    func set(_ outcome: Result<[AgentSession], any Error>) {
        self.outcome.withLock { $0 = outcome }
    }

    func snapshot(now: Date) throws -> [AgentSession] {
        try outcome.withLock { $0 }.get()
    }
}

@Suite struct SessionStoreTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func session(_ providerId: String, _ sessionId: String, status: AgentStatus = .running) -> AgentSession {
        AgentSession(
            key: SessionKey(providerId: providerId, sessionId: sessionId),
            agentName: providerId,
            title: sessionId,
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

    @Test func storeIsolatesFailingProvider() {
        let healthy = ScriptedProvider(id: "alpha", outcome: .success([Self.session("alpha", "a1")]))
        let flaky = ScriptedProvider(id: "beta", outcome: .success([Self.session("beta", "b1")]))
        let store = SessionStore(providers: [healthy, flaky])
        #expect(store.snapshot(now: Self.now).map(\.key.sessionId) == ["a1", "b1"])

        flaky.set(.failure(ProviderFailure()))
        healthy.set(.success([Self.session("alpha", "a1", status: .done), Self.session("alpha", "a2")]))
        let during = store.snapshot(now: Self.now)

        #expect(during.map(\.key.sessionId) == ["a1", "a2", "b1"])
        #expect(during.first { $0.key.sessionId == "a1" }?.status == .done)
    }

    @Test func recoveredProviderReplacesItsPreviousResult() {
        let flaky = ScriptedProvider(id: "beta", outcome: .success([Self.session("beta", "b1")]))
        let store = SessionStore(providers: [flaky])
        _ = store.snapshot(now: Self.now)
        flaky.set(.failure(ProviderFailure()))
        _ = store.snapshot(now: Self.now)

        flaky.set(.success([Self.session("beta", "b2")]))

        #expect(store.snapshot(now: Self.now).map(\.key.sessionId) == ["b2"])
    }

    @Test func providerThatNeverSucceededContributesNothing() {
        let healthy = ScriptedProvider(id: "alpha", outcome: .success([Self.session("alpha", "a1")]))
        let broken = ScriptedProvider(id: "beta", outcome: .failure(ProviderFailure()))
        let store = SessionStore(providers: [broken, healthy])

        #expect(store.snapshot(now: Self.now).map(\.key.sessionId) == ["a1"])
    }

    @Test func providerThatSucceedsWithEmptyListClearsItsSessions() {
        let provider = ScriptedProvider(id: "alpha", outcome: .success([Self.session("alpha", "a1")]))
        let store = SessionStore(providers: [provider])
        _ = store.snapshot(now: Self.now)

        provider.set(.success([]))

        #expect(store.snapshot(now: Self.now).isEmpty)
    }

    @Test func resultsAreConcatenatedInProviderOrderWithoutSorting() {
        let first = ScriptedProvider(id: "alpha", outcome: .success([Self.session("alpha", "z9"), Self.session("alpha", "a1")]))
        let second = ScriptedProvider(id: "beta", outcome: .success([Self.session("beta", "m5")]))

        let store = SessionStore(providers: [first, second])

        #expect(store.snapshot(now: Self.now).map(\.key.sessionId) == ["z9", "a1", "m5"])
    }

    @Test func watchedDirectoriesAreGatheredFromAllProviders() {
        let one = URL(fileURLWithPath: "/Users/me/.agent-one/sessions")
        let two = URL(fileURLWithPath: "/Users/me/.agent-two/state")
        let store = SessionStore(providers: [
            ScriptedProvider(id: "alpha", watching: [one], outcome: .success([])),
            ScriptedProvider(id: "beta", watching: [two], outcome: .success([])),
        ])

        #expect(store.watchedDirectories == [one, two])
    }

    @Test func emptyStoreYieldsNothing() {
        let store = SessionStore(providers: [])

        #expect(store.snapshot(now: Self.now).isEmpty)
        #expect(store.watchedDirectories.isEmpty)
    }
}
