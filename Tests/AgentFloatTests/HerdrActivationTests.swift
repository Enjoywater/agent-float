import AgentFloatCore
import AppKit
import Testing
@testable import AgentFloat

@MainActor
struct HerdrActivationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_FLOAT_TEST_LIVE_HERDR_ACTIVATION"] == "1"))
    func focusesDetectedTerminalAndActivatesHerdr() async throws {
        let sessions = try await Task.detached { try ClaudeCodeProvider.live().snapshot(now: Date()) }.value
        let session = try #require(sessions.first { $0.terminalApp == .herdr })
        let activator = AppActivator()
        let navigator = HerdrNavigator(runner: ProcessCommandRunner()) {
            activator.activate(bundleIdentifier: TerminalBundle.herdr)
        }
        try await NavigatorRegistry([navigator]).navigate(to: session, timeout: .seconds(8))
        for _ in 0..<30 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TerminalBundle.herdr { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TerminalBundle.herdr)
    }
}
