import AgentFloatCore
import Testing
@testable import AgentFloat

@MainActor
struct ProviderRegistrationTests {
    @Test func registersClaudeAndCodexWithHomeOverrides() {
        let providers = AppDelegate.makeProviders([
            "AGENT_FLOAT_CLAUDE_HOME": "/test/claude",
            "AGENT_FLOAT_CODEX_HOME": "/test/codex",
            "CODEX_HOME": "/test/ignored",
        ])
        #expect(providers.map(\.id) == ["claude-code", "codex"])
        #expect(providers[0].watchedDirectories.first?.path == "/test/claude/sessions")
        #expect(providers[1].watchedDirectories.first?.path == "/test/codex/app-server-control")
        let fallback = AppDelegate.makeProviders(["CODEX_HOME": "/test/fallback"])
        #expect(fallback[1].watchedDirectories.first?.path == "/test/fallback/app-server-control")
    }

    @Test func fakeModeDoesNotConnectToRealProviders() {
        let providers = AppDelegate.makeProviders(["AGENT_FLOAT_FAKE_SESSIONS": "2"])
        #expect(providers.count == 1)
        #expect(providers.first is FakeProvider)
    }
}
