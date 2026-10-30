import Foundation
import Testing
@testable import AgentFloatCore

/// 외부 모델 대신 로컬 응답 fixture에 연결한 실제 Codex TUI에서만 명시적으로 실행한다.
struct CodexTUIIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_FLOAT_CODEX_TUI_FIXTURE"] != nil))
    func deliversAndVerifiesThroughActualCodexTUI() async throws {
        let manifestPath = try #require(ProcessInfo.processInfo.environment["AGENT_FLOAT_CODEX_TUI_FIXTURE"])
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        let tail = try CodexTranscript.read(path: manifest.path, sessionID: manifest.id)
        let prompt: PendingPrompt
        let draft: ReplyDraft
        let expected: RecordedAnswer
        if manifest.kind == "text" {
            let message = try #require(tail.lastMessage)
            prompt = .text(id: message.id, message: message.text)
            draft = .text("Purple")
            expected = .text("Purple")
        } else {
            prompt = try #require(tail.pendingChoice)
            guard case let .choices(_, questions) = prompt else { Issue.record("expected choices"); return }
            let answers: [ChoiceAnswer] = questions.map { _ in manifest.kind == "other" ? .other("Purple") : .option(1) }
            draft = .choices(answers)
            expected = try #require(ReplyDriver.expectedRecord(prompt: prompt, draft: draft))
        }
        let session = AgentSession(
            key: SessionKey(providerId: "codex", sessionId: manifest.id), agentName: "Codex", title: "Fixture", cwd: "/tmp",
            status: .waiting, waitReason: manifest.kind == "text" ? .bodyQuestion : .question,
            statusSince: Date(), isStale: false, lastActivityAt: Date(), terminalApp: .other("tmux"),
            locator: .tmux(socket: manifest.socket, paneId: manifest.pane, pid: 1), prompt: prompt
        )
        let console = TmuxConsole(runner: ProcessCommandRunner(), executable: TmuxCLI.resolveExecutable())
        let delivery = ReplyDelivery(
            currentSessions: { [session] }, consoles: ConsoleRegistry([console]),
            answers: { _, id in (try? CodexTranscript.read(path: manifest.path, sessionID: manifest.id))?.records[id] }
        )
        let outcome = await delivery.deliver(draft, prompt: prompt, session: session, onStage: { _ in })
        #expect(outcome == .delivered(expected))
    }

    private struct Manifest: Decodable, Sendable {
        let id: String
        let path: String
        let socket: String
        let pane: String
        let kind: String
    }
}
