import Foundation
import Testing
@testable import AgentFloatCore

@Suite struct TtyTerminalsTests {
    private static let otherLocators: [TerminalLocator] = [
        .ghostty(title: "세션", cwd: "/Users/me"),
        .orca(tabId: "t", leafId: "l"),
        .background(jobId: "fe50860d"),
        .tmux(socket: "/private/tmp/tmux-501/default", paneId: "%7", pid: 4013),
        .application(pid: 10),
        .none,
    ]

    private func script(of call: FakeCommandRunner.Call?) -> String {
        guard let call, call.arguments.count == 2, call.arguments[0] == "-e" else { return "" }
        return call.arguments[1]
    }

    // MARK: tty 형식

    @Test(arguments: ["/dev/ttys0", "/dev/ttys012"])
    func ttyFormatAcceptsDevicePaths(tty: String) {
        #expect(TtyFormat.isDevicePath(tty))
    }

    @Test(arguments: ["", "/dev/ttys", "ttys003", "/dev/ttys003\"", "/dev/ttys003 x", "/dev/tty.usb", "/dev/ttys003\n"])
    func ttyFormatRejectsEverythingElse(tty: String) {
        #expect(!TtyFormat.isDevicePath(tty))
    }

    // MARK: 이동

    @Test func appleTerminalSelectsTabByTty() async throws {
        let fake = FakeCommandRunner { _ in "ok\n" }
        try await AppleTerminalNavigator(runner: fake).navigate(to: makeSession(locator: .appleTerminal(tty: "/dev/ttys004")))

        let calls = await fake.calls
        #expect(calls.count == 1)
        #expect(calls.first?.executable == "/usr/bin/osascript")
        let text = script(of: calls.first)
        #expect(text.contains("tell application id \"com.apple.Terminal\""))
        #expect(text.contains("\"/dev/ttys004\""))
        #expect(text.contains("set selected of"))
        #expect(text.contains("set frontmost of"))
        #expect(text.contains("activate"))
    }

    @Test func iTermSelectsSessionByTty() async throws {
        let fake = FakeCommandRunner { _ in "ok" }
        try await ITermNavigator(runner: fake).navigate(to: makeSession(locator: .iTerm(tty: "/dev/ttys005")))

        let text = script(of: await fake.calls.first)
        #expect(text.contains("tell application id \"com.googlecode.iterm2\""))
        #expect(text.contains("\"/dev/ttys005\""))
        #expect(text.contains("select"))
        #expect(text.contains("activate"))
    }

    @Test func missingTabIsNotFound() async {
        let fake = FakeCommandRunner { _ in "missing" }
        await #expect(throws: NavigationError.terminalNotFound) {
            try await AppleTerminalNavigator(runner: fake).navigate(to: makeSession(locator: .appleTerminal(tty: "/dev/ttys004")))
        }
        await #expect(throws: NavigationError.terminalNotFound) {
            try await ITermNavigator(runner: fake).navigate(to: makeSession(locator: .iTerm(tty: "/dev/ttys004")))
        }
    }

    @Test func invalidTtyIsRejectedWithoutRunning() async {
        let fake = FakeCommandRunner { _ in "ok" }
        await #expect(throws: NavigationError.terminalNotFound) {
            try await AppleTerminalNavigator(runner: fake).navigate(to: makeSession(locator: .appleTerminal(tty: "/dev/ttys1\" & x")))
        }
        await #expect(throws: NavigationError.terminalNotFound) {
            try await ITermNavigator(runner: fake).selectTab(tty: "/dev/ttys1 x")
        }
        #expect(await fake.calls.isEmpty)
    }

    @Test func ttyNavigatorsHandleOnlyTheirLocators() {
        let terminal = AppleTerminalNavigator(runner: FakeCommandRunner { _ in "" })
        let iTerm = ITermNavigator(runner: FakeCommandRunner { _ in "" })
        #expect(terminal.canNavigate(makeSession(locator: .appleTerminal(tty: "/dev/ttys004"))))
        #expect(!terminal.canNavigate(makeSession(locator: .iTerm(tty: "/dev/ttys004"))))
        #expect(iTerm.canNavigate(makeSession(locator: .iTerm(tty: "/dev/ttys004"))))
        #expect(!iTerm.canNavigate(makeSession(locator: .appleTerminal(tty: "/dev/ttys004"))))
        for locator in Self.otherLocators {
            #expect(!terminal.canNavigate(makeSession(locator: locator)))
            #expect(!iTerm.canNavigate(makeSession(locator: locator)))
        }
    }

    // MARK: 직접 선택 감지

    @Test func appleTerminalProbeMatchesSelectedTty() async throws {
        let fake = FakeCommandRunner { _ in "/dev/ttys004\n" }
        let shown = makeSession(locator: .appleTerminal(tty: "/dev/ttys004"), sessionId: "a")
        let hidden = makeSession(locator: .appleTerminal(tty: "/dev/ttys009"), sessionId: "b")

        let found = try await AppleTerminalFocusProbe(runner: fake).focusedSessions(among: [shown, hidden])

        #expect(found == [shown.key])
        #expect(script(of: await fake.calls.first).contains("tty of selected tab of front window"))
    }

    @Test func iTermProbeMatchesCurrentSessionTty() async throws {
        let fake = FakeCommandRunner { _ in "/dev/ttys005" }
        let shown = makeSession(locator: .iTerm(tty: "/dev/ttys005"), sessionId: "a")

        let found = try await ITermFocusProbe(runner: fake).focusedSessions(among: [shown])

        #expect(found == [shown.key])
        #expect(script(of: await fake.calls.first).contains("tty of current session of current window"))
    }

    @Test func probeSkipsWhenNoCandidates() async throws {
        let fake = FakeCommandRunner { _ in "/dev/ttys004" }
        let found = try await AppleTerminalFocusProbe(runner: fake).focusedSessions(among: [makeSession(locator: .ghostty(title: nil, cwd: "/w"))])
        #expect(found.isEmpty)
        #expect(await fake.calls.isEmpty)
    }

    @Test func canProbeOnlyOwnLocators() {
        let runner = FakeCommandRunner { _ in "" }
        let probes: [any FocusProbe] = [GhosttyFocusProbe(runner: runner), AppleTerminalFocusProbe(runner: runner), ITermFocusProbe(runner: runner)]
        #expect(probes.map(\.bundleIdentifier) == [TerminalBundle.ghostty, TerminalBundle.appleTerminal, TerminalBundle.iTerm])
        #expect(probes[0].canProbe(makeSession(locator: .ghostty(title: nil, cwd: "/w"))))
        #expect(probes[1].canProbe(makeSession(locator: .appleTerminal(tty: "/dev/ttys004"))))
        #expect(!probes[1].canProbe(makeSession(locator: .iTerm(tty: "/dev/ttys004"))))
        #expect(probes[2].canProbe(makeSession(locator: .iTerm(tty: "/dev/ttys004"))))
        for locator in [TerminalLocator.orca(tabId: "t", leafId: "l"), .tmux(socket: "/s", paneId: "%1", pid: 1), .application(pid: 1), .none] {
            for probe in probes {
                #expect(!probe.canProbe(makeSession(locator: locator)))
            }
        }
    }
}
