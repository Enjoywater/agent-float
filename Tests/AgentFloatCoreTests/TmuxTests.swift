import Foundation
import Testing
@testable import AgentFloatCore

@Suite struct TmuxTests {
    private struct OuterCall: Equatable, Sendable {
        let sessionPid: Int32
        let chain: [Int32]
        let clientTty: String
    }

    private static let socket = "/private/tmp/tmux-501/default"
    private static let clientFormat = "#{client_tty}\t#{client_pid}\t#{client_session}\t#{client_activity}"
    private static let pane = TerminalLocator.tmux(socket: socket, paneId: "%7", pid: 4013)

    private func navigator(
        runner: FakeCommandRunner,
        executable: String? = "/fake/tmux",
        outer: CallLog<OuterCall> = CallLog()
    ) -> TmuxNavigator {
        TmuxNavigator(runner: runner, inspector: FakeProcessInspector(parents: [502: 400, 400: 300]), executable: executable) { pid, chain, tty in
            outer.append(OuterCall(sessionPid: pid, chain: chain, clientTty: tty))
        }
    }

    private func tmux(_ arguments: String...) -> FakeCommandRunner.Call {
        FakeCommandRunner.Call(executable: "/fake/tmux", arguments: ["-S", Self.socket] + arguments)
    }

    // MARK: 출력 해석

    @Test func parsesClientList() {
        let output = "/dev/ttys001\t501\tmain\t1792370000\n/dev/ttys002\t502\twork\t1792370100\n"
        #expect(TmuxCLI.parseClients(output) == [
            TmuxClient(tty: "/dev/ttys001", pid: 501, session: "main", activity: 1_792_370_000),
            TmuxClient(tty: "/dev/ttys002", pid: 502, session: "work", activity: 1_792_370_100),
        ])
    }

    @Test func parseSkipsMalformedLines() {
        #expect(TmuxCLI.parseClients("\n/dev/ttys001\tabc\tmain\t1\nshort\n").isEmpty)
    }

    @Test func prefersClientOnPaneSession() {
        let main = TmuxClient(tty: "/dev/ttys001", pid: 501, session: "main", activity: 200)
        let work = TmuxClient(tty: "/dev/ttys002", pid: 502, session: "work", activity: 100)
        #expect(TmuxCLI.chooseClient(for: "work", among: [main, work]) == work)
        // 그 세션을 보는 클라이언트가 없으면 사용자가 가장 최근에 만진 클라이언트로 데려간다
        #expect(TmuxCLI.chooseClient(for: "other", among: [work, main]) == main)
        #expect(TmuxCLI.chooseClient(for: "work", among: []) == nil)
    }

    @Test(arguments: ["/private/tmp/tmux-501/default", "/tmp/a.b_c-d/x"])
    func safeSocketPaths(path: String) {
        #expect(TmuxCLI.isSafeSocketPath(path))
    }

    @Test(arguments: ["", "relative/sock", "/tmp/a b", "/tmp/a\"b", "/tmp/a;b", "/tmp/$x", "/tmp/a'b"])
    func unsafeSocketPaths(path: String) {
        #expect(!TmuxCLI.isSafeSocketPath(path))
    }

    @Test func resolvesFirstExistingExecutable() {
        #expect(TmuxCLI.candidatePaths == ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"])
        let resolved = TmuxCLI.resolveExecutable()
        #expect(resolved == TmuxCLI.candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) })
    }

    // MARK: 이동

    @Test func attachedPaneSwitchesClientThenOuterTerminal() async throws {
        let fake = FakeCommandRunner { call in
            if call.arguments.contains("display-message") { return "work\n" }
            if call.arguments.contains("list-clients") { return "/dev/ttys001\t501\tmain\t200\n/dev/ttys002\t502\twork\t100\n" }
            return ""
        }
        let outer = CallLog<OuterCall>()

        try await navigator(runner: fake, outer: outer).navigate(to: makeSession(locator: Self.pane))

        #expect(await fake.calls == [
            tmux("display-message", "-p", "-t", "%7", "#{session_name}"),
            tmux("list-clients", "-F", Self.clientFormat),
            tmux("switch-client", "-c", "/dev/ttys002", "-t", "%7"),
        ])
        #expect(outer.entries == [OuterCall(sessionPid: 4013, chain: [502, 400, 300], clientTty: "/dev/ttys002")])
    }

    @Test func detachedPaneOpensGhosttyAttachTab() async throws {
        let fake = FakeCommandRunner { call in
            call.arguments.contains("display-message") ? "work\n" : ""
        }
        let outer = CallLog<OuterCall>()

        try await navigator(runner: fake, outer: outer).navigate(to: makeSession(locator: Self.pane))

        let calls = await fake.calls
        #expect(Array(calls.prefix(4)) == [
            tmux("display-message", "-p", "-t", "%7", "#{session_name}"),
            tmux("list-clients", "-F", Self.clientFormat),
            tmux("select-window", "-t", "%7"),
            tmux("select-pane", "-t", "%7"),
        ])
        #expect(calls.count == 5)
        #expect(calls.last?.executable == "/usr/bin/osascript")
        #expect(calls.last?.arguments.last?.contains("/fake/tmux -S \(Self.socket) attach -t %7") == true)
        #expect(outer.entries.isEmpty)
    }

    @Test func missingPaneIsNotFound() async {
        let fake = FakeCommandRunner { _ in throw NavigationError.commandFailed("can't find pane: %7") }
        await #expect(throws: NavigationError.terminalNotFound) {
            try await navigator(runner: fake).navigate(to: makeSession(locator: Self.pane))
        }
        #expect(await fake.calls.count == 1)
    }

    @Test(arguments: [
        TerminalLocator.tmux(socket: "/tmp/a b", paneId: "%7", pid: 4013),
        .tmux(socket: "/private/tmp/tmux-501/default", paneId: "%7;x", pid: 4013),
        .tmux(socket: "/private/tmp/tmux-501/default", paneId: "7", pid: 4013),
    ])
    func unsafeAttachInputIsRejected(locator: TerminalLocator) async {
        let fake = FakeCommandRunner { _ in "" }
        await #expect(throws: NavigationError.terminalNotFound) {
            try await navigator(runner: fake).navigate(to: makeSession(locator: locator))
        }
        #expect(await fake.calls.isEmpty)
    }

    @Test func missingExecutableIsNotFound() async {
        let fake = FakeCommandRunner { _ in "" }
        await #expect(throws: NavigationError.terminalNotFound) {
            try await navigator(runner: fake, executable: nil).navigate(to: makeSession(locator: Self.pane))
        }
        #expect(await fake.calls.isEmpty)
    }

    @Test func tmuxNavigatorHandlesOnlyTmux() {
        let tmux = navigator(runner: FakeCommandRunner { _ in "" })
        #expect(tmux.canNavigate(makeSession(locator: Self.pane)))
        for locator in [TerminalLocator.ghostty(title: nil, cwd: "/w"), .appleTerminal(tty: "/dev/ttys004"), .iTerm(tty: "/dev/ttys004"), .application(pid: 1), .none] {
            #expect(!tmux.canNavigate(makeSession(locator: locator)))
        }
    }
}
