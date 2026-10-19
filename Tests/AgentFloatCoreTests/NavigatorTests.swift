import Foundation
import Testing
@testable import AgentFloatCore

@Suite struct NavigatorTests {
    private let chain = FakeProcessInspector(parents: [100: 90, 90: 80])

    @Test func appActivationWalksAncestors() async throws {
        let received = CallLog<[Int32]>()
        let navigator = AppActivationNavigator(inspector: chain) { pids in
            received.append(pids)
            return true
        }

        try await navigator.navigate(to: makeSession(locator: .application(pid: 100)))

        #expect(received.entries == [[100, 90, 80]])
    }

    @Test func appActivationThrowsWhenNoAppFound() async {
        let navigator = AppActivationNavigator(inspector: chain) { _ in false }

        await #expect(throws: NavigationError.terminalNotFound) {
            try await navigator.navigate(to: makeSession(locator: .application(pid: 100)))
        }
    }

    @Test func ancestorWalkStopsAtThirtyTwoSteps() async throws {
        let long = FakeProcessInspector(parents: Dictionary(uniqueKeysWithValues: (1000..<1100).map { (Int32($0), Int32($0 + 1)) }))
        let received = CallLog<[Int32]>()
        let navigator = AppActivationNavigator(inspector: long) { pids in
            received.append(pids)
            return true
        }

        try await navigator.navigate(to: makeSession(locator: .application(pid: 1000)))

        #expect(received.entries.first == (1000..<1032).map { Int32($0) })
    }

    @Test func ancestorWalkSurvivesParentCycles() async throws {
        let cyclic = FakeProcessInspector(parents: [10: 20, 20: 10])
        let received = CallLog<[Int32]>()
        let navigator = AppActivationNavigator(inspector: cyclic) { pids in
            received.append(pids)
            return true
        }

        try await navigator.navigate(to: makeSession(locator: .application(pid: 10)))

        #expect(received.entries == [[10, 20]])
    }

    @Test func appActivationHandlesOnlyApplicationLocators() {
        let navigator = AppActivationNavigator(inspector: chain) { _ in true }
        #expect(navigator.canNavigate(makeSession(locator: .application(pid: 1))))
        #expect(!navigator.canNavigate(makeSession(locator: .orca(tabId: "t", leafId: "l"))))
        #expect(!navigator.canNavigate(makeSession(locator: .ghostty(title: nil, cwd: "/w"))))
        #expect(!navigator.canNavigate(makeSession(locator: .background(jobId: "fe50860d"))))
        #expect(!navigator.canNavigate(makeSession(locator: .none)))
    }

    @Test func registryRoutesByLocator() async throws {
        let orcaListing = #"{"ok":true,"result":{"terminals":[{"handle":"term_a","tabId":"t","leafId":"l"}]}}"#
        let fake = FakeCommandRunner { call in
            if call.executable == OrcaCLI.executable {
                return call.arguments.contains("list") ? orcaListing : ""
            }
            return call.arguments.last == GhosttyScripts.listTerminals ? "A\t✳ 위젯\t/w\n" : "ok"
        }
        let activatedOrca = CallLog<Void>()
        let activatedApps = CallLog<[Int32]>()
        let registry = NavigatorRegistry([
            GhosttyNavigator(runner: fake),
            OrcaNavigator(runner: fake) { activatedOrca.append(()) },
            AppActivationNavigator(inspector: chain) { pids in
                activatedApps.append(pids)
                return true
            },
        ])

        try await registry.navigate(to: makeSession(locator: .orca(tabId: "t", leafId: "l")))
        #expect(await fake.calls.map(\.executable) == [OrcaCLI.executable, OrcaCLI.executable])
        #expect(activatedOrca.entries.count == 1)

        try await registry.navigate(to: makeSession(locator: .ghostty(title: "위젯", cwd: "/w")))
        #expect(await fake.calls.suffix(2).map(\.executable) == ["/usr/bin/osascript", "/usr/bin/osascript"])

        try await registry.navigate(to: makeSession(locator: .application(pid: 100)))
        #expect(activatedApps.entries == [[100, 90, 80]])
        #expect(await fake.calls.count == 4)

        let unlocated = makeSession(locator: .none)
        #expect(!registry.canNavigate(unlocated))
        await #expect(throws: NavigationError.terminalNotFound) {
            try await registry.navigate(to: unlocated)
        }
    }

    // MARK: 제한 시간 (R23)

    @Test func timeoutCancelsAHangingNavigation() async {
        let sawCancellation = CallLog<Void>()
        let registry = NavigatorRegistry([ScriptedNavigator {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                sawCancellation.append(())
                throw CancellationError()
            }
        }])
        let started = ContinuousClock.now

        await #expect(throws: NavigationError.timedOut) {
            try await registry.navigate(to: makeSession(locator: .none), timeout: .milliseconds(100))
        }

        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(sawCancellation.entries.count == 1)
    }

    @Test func timeoutLetsAFastNavigationSucceed() async throws {
        let finished = CallLog<Void>()
        let registry = NavigatorRegistry([ScriptedNavigator { finished.append(()) }])

        try await registry.navigate(to: makeSession(locator: .none), timeout: .seconds(30))

        #expect(finished.entries.count == 1)
    }

    @Test func timeoutPassesNavigationErrorsThrough() async {
        let registry = NavigatorRegistry([ScriptedNavigator { throw NavigationError.commandFailed("not authorized") }])

        await #expect(throws: NavigationError.commandFailed("not authorized")) {
            try await registry.navigate(to: makeSession(locator: .none), timeout: .seconds(30))
        }
    }

    @Test func timeoutStillRefusesSessionsNobodyHandles() async {
        await #expect(throws: NavigationError.terminalNotFound) {
            try await NavigatorRegistry([]).navigate(to: makeSession(locator: .none), timeout: .seconds(30))
        }
    }

    @Test func registryCanNavigateReflectsAnyMember() {
        let registry = NavigatorRegistry([OrcaNavigator(runner: FakeCommandRunner { _ in "" }) {}])
        #expect(registry.canNavigate(makeSession(locator: .orca(tabId: "t", leafId: "l"))))
        #expect(!registry.canNavigate(makeSession(locator: .ghostty(title: nil, cwd: "/w"))))
        #expect(!NavigatorRegistry([]).canNavigate(makeSession(locator: .application(pid: 1))))
    }
}
