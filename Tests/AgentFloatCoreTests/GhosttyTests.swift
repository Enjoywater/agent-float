import Foundation
import Testing
@testable import AgentFloatCore

@Suite struct GhosttyTests {
    private static let osascript = "/usr/bin/osascript"

    private func terminal(_ id: String, _ title: String, _ cwd: String) -> GhosttyTerminal {
        GhosttyTerminal(id: id, title: title, cwd: cwd)
    }

    // MARK: 제목 정리·목록 해석

    @Test func stripsClaudeGlyphs() {
        #expect(GhosttyMatcher.strippedTitle("◐ 플로팅 위젯") == "플로팅 위젯")
        #expect(GhosttyMatcher.strippedTitle("◑ 플로팅 위젯") == "플로팅 위젯")
        #expect(GhosttyMatcher.strippedTitle("✳ Slack") == "Slack")
        #expect(GhosttyMatcher.strippedTitle("plain") == "plain")
    }

    @Test func keepsGlyphsThatAreNotLeadingOrNotClaudeOnes() {
        #expect(GhosttyMatcher.strippedTitle("a ✳ b") == "a ✳ b")
        #expect(GhosttyMatcher.strippedTitle("★ 별") == "★ 별")
        #expect(GhosttyMatcher.strippedTitle("✳") == "")
    }

    @Test func parsesListOutput() {
        let output = "A\t◑ 제목\t/Users/me\nB\t~\t/tmp\n"
        #expect(GhosttyMatcher.parseList(output) == [
            GhosttyTerminal(id: "A", title: "◑ 제목", cwd: "/Users/me"),
            GhosttyTerminal(id: "B", title: "~", cwd: "/tmp"),
        ])
    }

    @Test func parseListSkipsMalformedLinesAndKeepsTabsInsideTitle() {
        let output = "\nA\tonly-two\nB\ta\tb\t/tmp\n\t제목\t/x\nC\t\t/home\n"
        #expect(GhosttyMatcher.parseList(output) == [
            GhosttyTerminal(id: "B", title: "a\tb", cwd: "/tmp"),
            GhosttyTerminal(id: "C", title: "", cwd: "/home"),
        ])
    }

    // MARK: 매칭

    @Test func uniqueTitleWinsEvenWhenCwdDiffers() {
        let terminals = [terminal("A", "✳ 위젯", "/a"), terminal("B", "✳ 다른 일", "/b")]
        #expect(GhosttyMatcher.match(title: "위젯", cwd: "/b", in: terminals)?.id == "A")
    }

    @Test func duplicateTitlesTieBreakByCwd() {
        let terminals = [
            terminal("A", "◐ 위젯", "/a"),
            terminal("B", "✳ 위젯", "/b"),
            terminal("C", "위젯", "/b"),
        ]
        #expect(GhosttyMatcher.match(title: "위젯", cwd: "/b", in: terminals)?.id == "B")
        // cwd 가 하나도 맞지 않으면 후보의 첫 번째로 물러선다
        #expect(GhosttyMatcher.match(title: "위젯", cwd: "/zzz", in: terminals)?.id == "A")
    }

    @Test func missingTitleMatchesUniqueClaudeTabInCwd() {
        let one = [terminal("A", "✳ 아무 제목", "/w"), terminal("B", "~", "/w"), terminal("C", "✳ 다른 곳", "/x")]
        #expect(GhosttyMatcher.match(title: nil, cwd: "/w", in: one)?.id == "A")

        let two = one + [terminal("D", "◑ 또 하나", "/w")]
        #expect(GhosttyMatcher.match(title: nil, cwd: "/w", in: two) == nil)
    }

    @Test func titleWithoutCandidatesFallsBackToClaudeTabInCwd() {
        let terminals = [terminal("A", "✳ 바뀐 제목", "/w"), terminal("B", "zsh", "/w")]
        #expect(GhosttyMatcher.match(title: "옛 제목", cwd: "/w", in: terminals)?.id == "A")
    }

    @Test func plainShellsInCwdDoNotMatch() {
        let terminals = [terminal("A", "zsh", "/w"), terminal("B", "~/w", "/w")]
        #expect(GhosttyMatcher.match(title: nil, cwd: "/w", in: terminals) == nil)
        #expect(GhosttyMatcher.match(title: "없는 제목", cwd: "/w", in: terminals) == nil)
        #expect(GhosttyMatcher.match(title: nil, cwd: "/w", in: []) == nil)
    }

    // MARK: 스크립트

    @Test func escapesQuotesInScripts() {
        #expect(GhosttyScripts.focus(terminalId: "a\"b").contains("a\\\"b"))
        #expect(GhosttyScripts.focus(terminalId: "a\\b").contains("a\\\\b"))
        let newTab = GhosttyScripts.newTab(initialInput: "echo \"hi\"")
        #expect(newTab.contains("echo \\\"hi\\\""))
        #expect(newTab.contains("& return"))
    }

    @Test func scriptsUseTheMeasuredSyntax() {
        let list = GhosttyScripts.listTerminals
        #expect(list.contains("terminals of t"))
        #expect(list.contains("(id of s) & sep & (name of s) & sep & (working directory of s) & linefeed"))
        // tell 안에서 `tab` 을 쓰면 Ghostty 의 tab 클래스로 읽혀 실물에서 구분자가 사라졌다
        #expect(!list.contains("& tab &"))
        #expect(list.hasPrefix("set sep to character id 9"))
        let focus = GhosttyScripts.focus(terminalId: "X")
        #expect(focus.contains("focus s"))
        #expect(focus.contains("activate"))
        #expect(focus.contains("\"ok\""))
        #expect(focus.contains("\"missing\""))
        #expect(GhosttyScripts.focusedTerminalId.contains("focused terminal of selected tab of front window"))
        let newTab = GhosttyScripts.newTab(initialInput: "x")
        #expect(newTab.contains("new surface configuration"))
        #expect(newTab.contains("new tab in front window with configuration cfg"))
        #expect(newTab.contains("new window with configuration cfg"))
    }

    // MARK: 이동

    private static let listing = "A\t✳ 위젯\t/w\nB\tzsh\t/x\n"

    private func runner(focusResult: String = "ok") -> FakeCommandRunner {
        FakeCommandRunner { call in
            call.arguments.last == GhosttyScripts.listTerminals ? Self.listing : focusResult
        }
    }

    @Test func ghosttyNavigateRunsListThenFocus() async throws {
        let fake = runner()
        let navigator = GhosttyNavigator(runner: fake)

        try await navigator.navigate(to: makeSession(locator: .ghostty(title: "위젯", cwd: "/w")))

        #expect(await fake.calls == [
            .init(executable: Self.osascript, arguments: ["-e", GhosttyScripts.listTerminals]),
            .init(executable: Self.osascript, arguments: ["-e", GhosttyScripts.focus(terminalId: "A")]),
        ])
    }

    @Test func navigateThrowsWhenNoTerminalMatches() async {
        let fake = runner()
        let navigator = GhosttyNavigator(runner: fake)

        await #expect(throws: NavigationError.terminalNotFound) {
            try await navigator.navigate(to: makeSession(locator: .ghostty(title: "없음", cwd: "/nowhere")))
        }
        #expect(await fake.calls.count == 1)
    }

    @Test func navigateThrowsWhenTheTabVanishedBeforeFocus() async {
        let navigator = GhosttyNavigator(runner: runner(focusResult: "missing\n"))

        await #expect(throws: NavigationError.terminalNotFound) {
            try await navigator.navigate(to: makeSession(locator: .ghostty(title: "위젯", cwd: "/w")))
        }
    }

    @Test func commandFailureSurfacesUnchanged() async {
        let navigator = GhosttyNavigator(runner: FakeCommandRunner { _ in throw NavigationError.commandFailed("not authorized") })

        await #expect(throws: NavigationError.commandFailed("not authorized")) {
            try await navigator.navigate(to: makeSession(locator: .ghostty(title: "위젯", cwd: "/w")))
        }
    }

    @Test func backgroundOpensAttachTab() async throws {
        let fake = FakeCommandRunner { _ in "" }
        let navigator = GhosttyNavigator(runner: fake)

        try await navigator.navigate(to: makeSession(locator: .background(jobId: "fe50860d")))

        let calls = await fake.calls
        #expect(calls == [.init(executable: Self.osascript, arguments: ["-e", GhosttyScripts.newTab(initialInput: "claude attach fe50860d")])])
        #expect(calls.first?.arguments.last?.contains("claude attach fe50860d") == true)
    }

    @Test func backgroundJobIdWithShellMetacharactersIsRefused() async {
        let fake = FakeCommandRunner { _ in "" }
        let navigator = GhosttyNavigator(runner: fake)
        let hostile = makeSession(locator: .background(jobId: "x; rm -rf ~"))

        #expect(!navigator.canNavigate(hostile))
        await #expect(throws: NavigationError.terminalNotFound) {
            try await navigator.navigate(to: hostile)
        }
        #expect(await fake.calls.isEmpty)
    }

    @Test(arguments: ["-fe50860d", "--help", "_fe50860d", "é50860d"])
    func backgroundJobIdThatCouldReadAsAnOptionIsRefused(jobId: String) async {
        let fake = FakeCommandRunner { _ in "" }
        let navigator = GhosttyNavigator(runner: fake)
        let suspicious = makeSession(locator: .background(jobId: jobId))

        #expect(!navigator.canNavigate(suspicious))
        await #expect(throws: NavigationError.terminalNotFound) {
            try await navigator.navigate(to: suspicious)
        }
        #expect(await fake.calls.isEmpty)
    }

    @Test(arguments: ["fe50860d", "0b7-job_2", "A"])
    func backgroundJobIdStartingWithLetterOrDigitIsAccepted(jobId: String) {
        let navigator = GhosttyNavigator(runner: FakeCommandRunner { _ in "" })
        #expect(navigator.canNavigate(makeSession(locator: .background(jobId: jobId))))
    }

    // MARK: 직접 선택 감지 (spec 4.6 해제 조건 2)

    private static let watchListing = "A\t✳ 위젯\t/w\nB\t◐ 리뷰\t/w\nC\tzsh\t/x\n"

    private func focusRunner(focused: String) -> FakeCommandRunner {
        FakeCommandRunner { call in
            call.arguments.last == GhosttyScripts.focusedTerminalId ? focused : Self.watchListing
        }
    }

    @Test func probeReportsTheSessionWhoseTabIsFocused() async throws {
        let fake = focusRunner(focused: "B\n")
        let probe = GhosttyFocusProbe(runner: fake)
        let widget = makeSession(locator: .ghostty(title: "위젯", cwd: "/w"), sessionId: "widget")
        let review = makeSession(locator: .ghostty(title: "리뷰", cwd: "/w"), sessionId: "review")

        let shown = try await probe.focusedSessions(among: [widget, review])

        #expect(shown == [review.key])
        #expect(await fake.calls == [
            .init(executable: Self.osascript, arguments: ["-e", GhosttyScripts.focusedTerminalId]),
            .init(executable: Self.osascript, arguments: ["-e", GhosttyScripts.listTerminals]),
        ])
    }

    @Test func probeIgnoresSessionsOutsideGhosttyAndUnmatchedTabs() async throws {
        let probe = GhosttyFocusProbe(runner: focusRunner(focused: "C"))
        let sessions = [
            makeSession(locator: .ghostty(title: "위젯", cwd: "/w"), sessionId: "widget"),
            makeSession(locator: .orca(tabId: "t", leafId: "l"), sessionId: "orca"),
            makeSession(locator: .background(jobId: "fe50860d"), sessionId: "bg"),
        ]

        #expect(try await probe.focusedSessions(among: sessions).isEmpty)
    }

    @Test func probeRunsNothingWithoutGhosttySessions() async throws {
        let fake = focusRunner(focused: "A")
        let probe = GhosttyFocusProbe(runner: fake)

        let shown = try await probe.focusedSessions(among: [makeSession(locator: .orca(tabId: "t", leafId: "l"))])

        #expect(shown.isEmpty)
        #expect(await fake.calls.isEmpty)
    }

    @Test func probeSkipsTheListWhenNothingIsFocused() async throws {
        let fake = focusRunner(focused: "\n")
        let probe = GhosttyFocusProbe(runner: fake)

        let shown = try await probe.focusedSessions(among: [makeSession(locator: .ghostty(title: "위젯", cwd: "/w"))])

        #expect(shown.isEmpty)
        #expect(await fake.calls.count == 1)
    }

    @Test func probeSurfacesScriptFailures() async {
        let probe = GhosttyFocusProbe(runner: FakeCommandRunner { _ in throw NavigationError.commandFailed("not authorized") })

        await #expect(throws: NavigationError.commandFailed("not authorized")) {
            try await probe.focusedSessions(among: [makeSession(locator: .ghostty(title: "위젯", cwd: "/w"))])
        }
    }

    @Test func ghosttyNavigatorHandlesOnlyItsLocators() {
        let navigator = GhosttyNavigator(runner: FakeCommandRunner { _ in "" })
        #expect(navigator.canNavigate(makeSession(locator: .ghostty(title: nil, cwd: "/w"))))
        #expect(navigator.canNavigate(makeSession(locator: .background(jobId: "fe50860d"))))
        #expect(!navigator.canNavigate(makeSession(locator: .orca(tabId: "t", leafId: "l"))))
        #expect(!navigator.canNavigate(makeSession(locator: .application(pid: 10))))
        #expect(!navigator.canNavigate(makeSession(locator: .none)))
    }

    // MARK: 보내기용 엄격한 짝짓기 (v1.2 설계 4.1)

    @Test func uniqueMatchRefusesTitleTwins() {
        let terminals = [terminal("A", "✳ 캐시 만료 정책 정리", "/Users/me/work"), terminal("B", "◐ 캐시 만료 정책 정리", "/Users/me/work")]
        #expect(GhosttyMatcher.match(title: "캐시 만료 정책 정리", cwd: "/Users/me/work", in: terminals)?.id == "A")
        #expect(GhosttyMatcher.uniqueMatch(title: "캐시 만료 정책 정리", cwd: "/Users/me/work", in: terminals) == nil)
    }

    @Test func uniqueMatchUsesCwdToBreakTies() {
        let terminals = [terminal("A", "✳ 캐시 만료 정책 정리", "/Users/me/other"), terminal("B", "✳ 캐시 만료 정책 정리", "/Users/me/work")]
        #expect(GhosttyMatcher.uniqueMatch(title: "캐시 만료 정책 정리", cwd: "/Users/me/work", in: terminals)?.id == "B")
    }

    @Test func uniqueMatchKeepsSingleTitle() {
        let terminals = [terminal("A", "✳ 캐시 만료 정책 정리", "/Users/me/other"), terminal("B", "✳ 검색 색인 재구성", "/Users/me/work")]
        #expect(GhosttyMatcher.uniqueMatch(title: "캐시 만료 정책 정리", cwd: "/Users/me/work", in: terminals)?.id == "A")
        #expect(GhosttyMatcher.uniqueMatch(title: nil, cwd: "/Users/me/work", in: terminals)?.id == "B")
    }

    @Test func windowKeyIgnoresGlyphAndNormalization() {
        let decomposed = "캐시".decomposedStringWithCanonicalMapping
        #expect(GhosttyMatcher.windowKey("◑ \(decomposed) 정리") == GhosttyMatcher.windowKey("✳ 캐시 정리"))
        #expect(GhosttyMatcher.windowKey("✳ 캐시 정리") != GhosttyMatcher.windowKey("✳ 색인 정리"))
    }
}
