import Foundation
import Testing
@testable import AgentFloatCore

@Suite struct OrcaTests {
    private static let sample = """
    {"id":"req_1","ok":true,"result":{"terminals":[
      {"handle":"term_aaa","ptyId":"pty_1","worktreeId":"wt_1","tabId":"tab-1","leafId":"leaf-1","title":"shell","connected":true},
      {"handle":"term_bbb","ptyId":"pty_2","worktreeId":"wt_1","tabId":"tab-2","leafId":"leaf-2","title":"agent","connected":true,"extra":{"nested":[1,2]}}
    ]}}
    """

    private func json(_ text: String) -> Data { Data(text.utf8) }

    @Test func parsesOrcaTerminalList() throws {
        let terminals = try OrcaCLI.parseTerminalList(json(Self.sample))
        #expect(terminals == [
            OrcaTerminal(handle: "term_aaa", tabId: "tab-1", leafId: "leaf-1"),
            OrcaTerminal(handle: "term_bbb", tabId: "tab-2", leafId: "leaf-2"),
        ])
    }

    @Test func parseSkipsEntriesWithoutRoutingFields() throws {
        let text = #"{"ok":true,"result":{"terminals":[{"handle":"term_x","tabId":"t"},{"handle":"term_y","tabId":"t","leafId":"l"}]}}"#
        #expect(try OrcaCLI.parseTerminalList(json(text)) == [OrcaTerminal(handle: "term_y", tabId: "t", leafId: "l")])
    }

    @Test func parseRejectsUnusableOutput() {
        #expect(throws: NavigationError.self) { try OrcaCLI.parseTerminalList(json("not json")) }
        #expect(throws: NavigationError.self) { try OrcaCLI.parseTerminalList(json(#"{"ok":false,"error":{"message":"runtime down"}}"#)) }
        #expect(throws: NavigationError.self) { try OrcaCLI.parseTerminalList(json(#"{"ok":true,"result":{}}"#)) }
    }

    @Test func matchRequiresBothTabAndLeaf() {
        let terminals = [
            OrcaTerminal(handle: "h1", tabId: "t1", leafId: "l1"),
            OrcaTerminal(handle: "h2", tabId: "t1", leafId: "l2"),
            OrcaTerminal(handle: "h3", tabId: "t2", leafId: "l1"),
        ]
        #expect(OrcaCLI.match(tabId: "t1", leafId: "l2", in: terminals)?.handle == "h2")
        #expect(OrcaCLI.match(tabId: "t2", leafId: "l2", in: terminals) == nil)
    }

    @Test func matchPrefersHandleAndFallsBackToTabAndLeaf() {
        let terminals = [
            OrcaTerminal(handle: "h1", tabId: "t1", leafId: "l1"),
            OrcaTerminal(handle: "h2", tabId: "t2", leafId: "l2"),
        ]
        #expect(OrcaCLI.match(tabId: "t9", leafId: "l9", handle: "h1", in: terminals)?.handle == "h1")
        #expect(OrcaCLI.match(tabId: "t2", leafId: "l2", handle: "gone", in: terminals)?.handle == "h2")
        #expect(OrcaCLI.match(tabId: "t9", leafId: "l9", handle: "gone", in: terminals) == nil)
    }

    /// Orca 를 다시 켠 뒤 아직 열지 않은 워크트리의 터미널은 목록에 탭 id 대신 임시 id 로 나온다 (1.4.224 실측)
    @Test func orphanedTerminalIsReachedByHandle() async throws {
        let orphaned = """
        {"ok":true,"result":{"terminals":[
          {"handle":"term_ccc","tabId":"pty:444e","leafId":"pty:444e","orphaned":true,"connected":true},
          {"handle":"term_ddd","tabId":"pty:444e","leafId":"pty:444e","orphaned":true,"connected":true}
        ]}}
        """
        let fake = FakeCommandRunner { call in
            call.arguments.contains("list") ? orphaned : ""
        }
        let activations = CallLog<Void>()
        let navigator = OrcaNavigator(runner: fake) { activations.append(()) }

        try await navigator.navigate(to: makeSession(locator: .orca(tabId: "tab-7", leafId: "leaf-7", handle: "term_ddd")))

        #expect(await fake.calls.last == .init(executable: OrcaCLI.executable, arguments: ["terminal", "switch", "--terminal", "term_ddd"]))
        #expect(activations.entries.count == 1)
    }

    @Test func orcaNavigateSwitchesAndActivates() async throws {
        let fake = FakeCommandRunner { call in
            call.arguments.contains("list") ? Self.sample : ""
        }
        let activations = CallLog<Void>()
        let navigator = OrcaNavigator(runner: fake) { activations.append(()) }

        try await navigator.navigate(to: makeSession(locator: .orca(tabId: "tab-2", leafId: "leaf-2")))

        #expect(await fake.calls == [
            .init(executable: OrcaCLI.executable, arguments: ["terminal", "list", "--json", "--limit", "1000"]),
            .init(executable: OrcaCLI.executable, arguments: ["terminal", "switch", "--terminal", "term_bbb"]),
        ])
        #expect(activations.entries.count == 1)
    }

    @Test func orcaNavigateThrowsWhenNoTerminalMatches() async {
        let fake = FakeCommandRunner { _ in Self.sample }
        let activations = CallLog<Void>()
        let navigator = OrcaNavigator(runner: fake) { activations.append(()) }

        await #expect(throws: NavigationError.terminalNotFound) {
            try await navigator.navigate(to: makeSession(locator: .orca(tabId: "tab-9", leafId: "leaf-9")))
        }
        #expect(await fake.calls.count == 1)
        #expect(activations.entries.isEmpty)
    }

    @Test func failedSwitchDoesNotActivate() async {
        let fake = FakeCommandRunner { call in
            if call.arguments.contains("switch") { throw NavigationError.commandFailed("no such terminal") }
            return Self.sample
        }
        let activations = CallLog<Void>()
        let navigator = OrcaNavigator(runner: fake) { activations.append(()) }

        await #expect(throws: NavigationError.commandFailed("no such terminal")) {
            try await navigator.navigate(to: makeSession(locator: .orca(tabId: "tab-1", leafId: "leaf-1")))
        }
        #expect(activations.entries.isEmpty)
    }

    @Test func orcaNavigatorHandlesOnlyOrcaLocators() {
        let navigator = OrcaNavigator(runner: FakeCommandRunner { _ in "" }) {}
        #expect(navigator.canNavigate(makeSession(locator: .orca(tabId: "t", leafId: "l"))))
        #expect(!navigator.canNavigate(makeSession(locator: .ghostty(title: nil, cwd: "/w"))))
        #expect(!navigator.canNavigate(makeSession(locator: .application(pid: 10))))
        #expect(!navigator.canNavigate(makeSession(locator: .none)))
    }
}
