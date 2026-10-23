import Foundation
import Synchronization
import Testing
@testable import AgentFloatCore

/// 창 제목별로 정해 둔 화면을 돌려준다
private struct FakeScreenReader: GhosttyScreenReading {
    let isTrusted: Bool
    let screens: [String: [String]]

    func screen(windowTitle: String) throws -> [String] {
        guard let lines = screens[GhosttyMatcher.windowKey(windowTitle)] else { throw NavigationError.terminalNotFound }
        return lines
    }
}

private let terminalId = "A176D46E-0000-4000-8000-000000000001"
private let listing = "\(terminalId)\t✳ 캐시 만료 정책 정리\t/Users/me/work\nB0000000-0000-4000-8000-000000000002\t✳ 검색 색인 재구성\t/Users/me/work\n"

private func session(title: String? = "캐시 만료 정책 정리") -> AgentSession {
    AgentSession(
        key: SessionKey(providerId: "claude-code", sessionId: "s1"),
        agentName: "Claude",
        title: title ?? "이름 없는 세션",
        cwd: "/Users/me/work",
        status: .waiting,
        waitReason: .question,
        statusSince: Date(timeIntervalSince1970: 1_800_000_000),
        isStale: false,
        lastActivityAt: nil,
        terminalApp: .ghostty,
        locator: .ghostty(title: title, cwd: "/Users/me/work"),
        prompt: .choices(id: "toolu_01", questions: [expiryQuestion])
    )
}

/// 스크립트 종류로 응답을 고른다. 목록·위치·입력 스크립트는 내용으로 구분된다
private func runner(listing: String = listing, placement: String, input: String = "ok") -> FakeCommandRunner {
    FakeCommandRunner { call in
        let script = call.arguments.last ?? ""
        if script.contains("working directory of s") { return listing }
        if script.contains("selected of t") { return placement }
        return input
    }
}

@Suite struct GhosttyConsoleTests {
    private let dialog = ["❯ 1. 읽은 때부터 다시 세기 (Recommended)"]

    private func reader(trusted: Bool = true) -> FakeScreenReader {
        FakeScreenReader(isTrusted: trusted, screens: [GhosttyMatcher.windowKey("✳ 캐시 만료 정책 정리"): dialog])
    }

    @Test func readyWhenTabIsVisibleAndSingle() async {
        let console = GhosttyConsole(runner: runner(placement: "w1\t✳ 캐시 만료 정책 정리\ttrue\t1"), screenReader: reader())
        #expect(await console.availability(of: session()) == .ready)
    }

    @Test func hiddenTabIsReadOnly() async {
        let console = GhosttyConsole(runner: runner(placement: "w1\t✳ 검색 색인 재구성\tfalse\t1"), screenReader: reader())
        #expect(await console.availability(of: session()) == .readOnly(.hiddenTab))
    }

    @Test func windowOffScreenIsReadOnly() async {
        let empty = FakeScreenReader(isTrusted: true, screens: [:])
        let console = GhosttyConsole(runner: runner(placement: "w1\t✳ 캐시 만료 정책 정리\ttrue\t1"), screenReader: empty)
        #expect(await console.availability(of: session()) == .readOnly(.hiddenTab))
    }

    @Test func splitTabIsReadOnly() async {
        let console = GhosttyConsole(runner: runner(placement: "w1\t✳ 캐시 만료 정책 정리\ttrue\t2"), screenReader: reader())
        #expect(await console.availability(of: session()) == .readOnly(.splitTab))
    }

    @Test func untrustedIsAccessibilityNeeded() async {
        let console = GhosttyConsole(runner: runner(placement: "w1\t✳ 캐시 만료 정책 정리\ttrue\t1"), screenReader: reader(trusted: false))
        #expect(await console.availability(of: session()) == .readOnly(.accessibilityNeeded))
    }

    @Test func twinTitlesAreAmbiguous() async {
        let twins = "\(terminalId)\t✳ 캐시 만료 정책 정리\t/Users/me/work\nC0000000-0000-4000-8000-000000000003\t✳ 캐시 만료 정책 정리\t/Users/me/work\n"
        let console = GhosttyConsole(runner: runner(listing: twins, placement: "w1\t✳ 캐시 만료 정책 정리\ttrue\t1"), screenReader: reader())
        #expect(await console.availability(of: session()) == .readOnly(.ambiguousTab))
    }

    @Test func readsScreenOfThatWindow() async throws {
        let console = GhosttyConsole(runner: runner(placement: "w1\t◐ 캐시 만료 정책 정리\ttrue\t1"), screenReader: reader())
        let screen = try await console.readScreen(of: session())
        #expect(screen.lines == dialog)
        #expect(screen.faint == nil)
    }

    @Test func readRefusesHiddenTab() async {
        let console = GhosttyConsole(runner: runner(placement: "w1\t✳ 검색 색인 재구성\tfalse\t1"), screenReader: reader())
        await #expect(throws: NavigationError.terminalNotFound) { _ = try await console.readScreen(of: session()) }
    }

    @Test func inputTextEscapesQuotes() async throws {
        let fake = runner(placement: "w1\t✳ 캐시 만료 정책 정리\ttrue\t1")
        try await GhosttyConsole(runner: fake, screenReader: reader()).send(.text(#"say "hi" \ ok"#), to: session())
        let script = try #require(await fake.calls.last?.arguments.last)
        #expect(script.contains(#"input text "say \"hi\" \\ ok" to s"#))
        #expect(script.contains(terminalId))
    }

    @Test func sendKeyUsesMappedName() async throws {
        let fake = runner(placement: "w1\t✳ 캐시 만료 정책 정리\ttrue\t1")
        let console = GhosttyConsole(runner: fake, screenReader: reader())
        for key in ConsoleKey.allCases { try await console.send(.key(key), to: session()) }
        let scripts = await fake.calls.compactMap(\.arguments.last).filter { $0.contains("send key") }
        let names = ["enter", "arrowUp", "arrowDown", "arrowLeft", "arrowRight", "tab", "space"]
        #expect(scripts.count == names.count)
        for (script, name) in zip(scripts, names) { #expect(script.contains(#"send key "\#(name)" to s"#)) }
    }

    @Test func missingTerminalFails() async {
        let console = GhosttyConsole(runner: runner(placement: "w1\t✳ 캐시 만료 정책 정리\ttrue\t1", input: "missing\n"), screenReader: reader())
        await #expect(throws: NavigationError.terminalNotFound) { try await console.send(.key(.enter), to: session()) }
    }

    @Test func controlCharactersAreRefused() async {
        let fake = runner(placement: "w1\t✳ 캐시 만료 정책 정리\ttrue\t1")
        await #expect(throws: NavigationError.commandFailed("unsafe text")) {
            try await GhosttyConsole(runner: fake, screenReader: reader()).send(.text("a\u{1b}b"), to: session())
        }
        #expect(await fake.calls.isEmpty)
    }

    @Test func ghosttyCannotReadFaintText() {
        #expect(!GhosttyConsole(runner: runner(placement: ""), screenReader: reader()).readsFaintText)
    }
}
