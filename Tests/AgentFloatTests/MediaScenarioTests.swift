import AgentFloatCore
import Foundation
import Testing
@testable import AgentFloat

struct MediaScenarioTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func mixedSceneKeepsBothAgentsWaitingWithoutAutomaticStateChanges() throws {
        let provider = FakeProvider(count: 1, startedAt: start, mediaScene: .mixed)
        let initial = try provider.snapshot(now: start)
        let later = try provider.snapshot(now: start.addingTimeInterval(60))
        #expect(initial == later)
        #expect(Set(initial.filter { $0.status == .waiting }.map(\.agentName)) == ["Claude", "Codex"])
        #expect(initial.filter { $0.prompt != nil }.count == 2)
    }

    @Test func eachQuestionSceneUsesTheChosenAgentAndNeverHasARealLocator() throws {
        for scene in [FakeProvider.MediaScene.choice, .multi, .body, .permission] {
            for agent in FakeProvider.MediaAgent.allCases {
                let sessions = try FakeProvider(count: 1, startedAt: start, mediaScene: scene, mediaAgent: agent).snapshot(now: start)
                let target = try #require(sessions.first { $0.key.sessionId == "fake-media-target" })
                #expect(target.agentName == agent.name)
                #expect(target.status == .waiting)
                #expect(target.prompt != nil)
                #expect(sessions.allSatisfy { $0.key.providerId == "fake" && $0.locator == .none && $0.cwd.hasPrefix("/demo/") })
                switch scene {
                case .body:
                    guard case .text? = target.prompt else { Issue.record("body scene requires text input"); continue }
                case .permission:
                    guard case .permission? = target.prompt else { Issue.record("permission scene must be read-only"); continue }
                default:
                    guard case let .choices(_, questions)? = target.prompt else { Issue.record("choice scene requires choices"); continue }
                    #expect(questions.count == (scene == .multi ? 2 : 1))
                    #expect(questions.allSatisfy { !$0.multiSelect })
                }
            }
        }
    }

    @Test func onlyNewSceneTransitionsToDone() throws {
        for scene in [FakeProvider.MediaScene.ask, .running, .unknown, .new] {
            let provider = FakeProvider(count: 1, startedAt: start, mediaScene: scene)
            let first = try #require(provider.snapshot(now: start).first)
            let later = try #require(provider.snapshot(now: start.addingTimeInterval(6)).first)
            if scene == .new {
                #expect(first.status == .running)
                #expect(later.status == .done)
                #expect(first.key == later.key)
            } else {
                #expect(first == later)
            }
        }
    }

    @MainActor @Test func mediaEnvironmentRequiresFakeModeAndRoutesTheCodexProfile() throws {
        let environment = ["AGENT_FLOAT_MEDIA_SCENE": "choice", "AGENT_FLOAT_MEDIA_AGENT": "codex"]
        #expect(AppDelegate.makeProviders(environment).map(\.id) == ["claude-code", "codex"])
        let providers = AppDelegate.makeProviders(environment.merging(["AGENT_FLOAT_FAKE_SESSIONS": "1"]) { _, new in new })
        let provider = try #require(providers.first as? FakeProvider)
        #expect(provider.mediaScene == .choice)
        #expect(provider.mediaAgent == .codex)
        #expect(provider.watchedDirectories.isEmpty)
    }

    @Test func mismatchFixtureUsesAnotherAnswerFromTheSameQuestion() async throws {
        let session = try #require(FakeProvider(count: 1, startedAt: start, mediaScene: .choice, mediaAgent: .codex).snapshot(now: start).first)
        let prompt = try #require(session.prompt)
        guard case let .choices(_, questions) = prompt else { Issue.record("expected choices"); return }
        let question = try #require(questions.first)
        let backend = FakeReplyBackend.make(["AGENT_FLOAT_FAKE_REPLY": "mismatch", "AGENT_FLOAT_FAKE_REPLY_STAGE_DELAY": "0"])
        for index in 0..<2 {
            let outcome = await backend.deliver(.choices([.option(index)]), prompt, session, { _ in })
            guard case let .mismatched(_, recorded) = outcome else { Issue.record("expected mismatch"); continue }
            #expect(recorded == .choices([question.text: question.options[1 - index].label]))
        }
    }
}
