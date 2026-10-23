import Foundation
import Synchronization
import Testing
@testable import AgentFloatCore

/// pid 별 생존·환경변수를 지정하고 `environment` 호출 횟수를 센다. 캐시가 실제로 호출을 줄이는지 확인하기 위함
private final class FakeInspector: ProcessInspecting, Sendable {
    private struct State {
        var alive: Set<Int32>
        var environments: [Int32: [String: String]]
        var ttys: [Int32: String]
        var parents: [Int32: Int32]
        var environmentCalls = 0
    }

    private let state: Mutex<State>

    init(
        alive: Set<Int32> = [],
        environments: [Int32: [String: String]] = [:],
        ttys: [Int32: String] = [:],
        parents: [Int32: Int32] = [:]
    ) {
        state = Mutex(State(alive: alive, environments: environments, ttys: ttys, parents: parents))
    }

    var environmentCalls: Int { state.withLock { $0.environmentCalls } }

    func kill(_ pid: Int32) {
        state.withLock { _ = $0.alive.remove(pid) }
    }

    func isAlive(pid: Int32, procStart: String?) -> Bool {
        state.withLock { $0.alive.contains(pid) }
    }

    func environment(pid: Int32) -> [String: String] {
        state.withLock {
            $0.environmentCalls += 1
            return $0.environments[pid] ?? [:]
        }
    }

    func parentPid(of pid: Int32) -> Int32? {
        state.withLock { $0.parents[pid] }
    }

    func tty(pid: Int32) -> String? {
        state.withLock { $0.ttys[pid] }
    }
}

@Suite final class ClaudeCodeProviderTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let homeDirectory = "/Users/me"
    private static let workDirectory = "/Users/me/work"

    private let claudeHome: URL
    private var sessionsDirectory: URL { claudeHome.appendingPathComponent("sessions", isDirectory: true) }
    private var projectsDirectory: URL { claudeHome.appendingPathComponent("projects", isDirectory: true) }

    init() throws {
        claudeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-float-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: claudeHome)
    }

    // MARK: 도우미

    private func provider(_ inspector: FakeInspector) -> ClaudeCodeProvider {
        ClaudeCodeProvider(claudeHome: claudeHome, homeDirectory: Self.homeDirectory, inspector: inspector)
    }

    private static func sessionId(_ n: Int) -> String {
        "00000000-0000-4000-8000-0000000000b\(n)"
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @discardableResult
    private func writeSession(
        pid: Int32,
        sessionId: String,
        cwd: String? = ClaudeCodeProviderTests.workDirectory,
        kind: String = "interactive",
        status: String = "idle",
        waitingFor: String? = nil,
        name: String? = nil,
        statusUpdatedAt: Double? = nil,
        procStart: String? = nil,
        jobId: String? = nil
    ) throws -> URL {
        var object: [String: Any] = ["pid": pid, "sessionId": sessionId, "kind": kind, "status": status]
        object["cwd"] = cwd
        object["waitingFor"] = waitingFor
        object["name"] = name
        object["statusUpdatedAt"] = statusUpdatedAt
        object["procStart"] = procStart
        object["jobId"] = jobId
        let url = sessionsDirectory.appendingPathComponent("\(pid).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    @discardableResult
    private func writeTranscript(
        sessionId: String,
        project: String = "-Users-me-work",
        title: String? = nil,
        modifiedAt: Date = ClaudeCodeProviderTests.now.addingTimeInterval(-5)
    ) throws -> URL {
        var lines = [
            try jsonLine(["type": "user", "message": ["role": "user", "content": "작업을 시작해줘"]]),
            try jsonLine([
                "type": "assistant",
                "message": ["role": "assistant", "content": [["type": "text", "text": "정리했습니다."]]],
            ]),
        ]
        if let title {
            lines.append(try jsonLine(["type": "ai-title", "aiTitle": title, "sessionId": sessionId]))
        }
        return try writeTranscriptFile(
            sessionId: sessionId, project: project, text: lines.joined(separator: "\n") + "\n", modifiedAt: modifiedAt
        )
    }

    @discardableResult
    private func writeTranscriptFile(
        sessionId: String,
        project: String = "-Users-me-work",
        text: String,
        modifiedAt: Date
    ) throws -> URL {
        let directory = projectsDirectory.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(sessionId).jsonl")
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }

    /// transcript 꼬리 창(256KB)을 넘기려는 잡음. 한 줄이 약 1KB
    private func noise(bytes: Int) -> String {
        let line = #"{"type":"system","subtype":"filler","content":""# + String(repeating: "x", count: 1_000) + #""}"# + "\n"
        return String(repeating: line, count: bytes / line.utf8.count + 1)
    }

    private func titleLine(_ title: String, sessionId: String) throws -> String {
        try jsonLine(["type": "ai-title", "aiTitle": title, "sessionId": sessionId]) + "\n"
    }

    @discardableResult
    private func writeSubagentFile(
        sessionId: String,
        project: String = "-Users-me-work",
        relativePath: String = "agent-a1.jsonl",
        modifiedAt: Date
    ) throws -> URL {
        let url = projectsDirectory
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }

    private func session(_ sessions: [AgentSession], _ sessionId: String) throws -> AgentSession {
        try #require(sessions.first { $0.key.sessionId == sessionId })
    }

    // MARK: 터미널·제목 판별

    @Test func ghosttySessionGetsTitleAndLocator() throws {
        let id = Self.sessionId(1)
        try writeSession(pid: 4001, sessionId: id, status: "busy", name: "refactor-notes")
        try writeTranscript(sessionId: id, title: "플로팅 위젯")
        let inspector = FakeInspector(alive: [4001], environments: [4001: ["TERM_PROGRAM": "ghostty"]])

        let sessions = try provider(inspector).snapshot(now: Self.now)

        let found = try session(sessions, id)
        #expect(found.key == SessionKey(providerId: "claude-code", sessionId: id))
        #expect(found.agentName == "Claude")
        #expect(found.title == "플로팅 위젯")
        #expect(found.cwd == Self.workDirectory)
        #expect(found.status == .running)
        #expect(found.terminalApp == .ghostty)
        #expect(found.locator == .ghostty(title: "플로팅 위젯", cwd: Self.workDirectory))
        #expect(found.lastActivityAt == Self.now.addingTimeInterval(-5))
    }

    @Test func orcaSessionParsesPaneKey() throws {
        let id = Self.sessionId(2)
        let tabId = "11111111-1111-4111-8111-111111111111"
        let leafId = "22222222-2222-4222-8222-222222222222"
        try writeSession(pid: 4002, sessionId: id)
        try writeTranscript(sessionId: id, title: "문서 정리")
        let inspector = FakeInspector(
            alive: [4002],
            environments: [4002: ["TERM_PROGRAM": "Orca", "ORCA_PANE_KEY": "\(tabId):\(leafId)"]]
        )

        let found = try session(try provider(inspector).snapshot(now: Self.now), id)

        #expect(found.terminalApp == .orca)
        #expect(found.locator == .orca(tabId: tabId, leafId: leafId))
    }

    @Test func orcaSessionKeepsTerminalHandle() throws {
        let id = Self.sessionId(10)
        try writeSession(pid: 4010, sessionId: id)
        try writeTranscript(sessionId: id, title: "문서 정리")
        let inspector = FakeInspector(
            alive: [4010],
            environments: [4010: ["TERM_PROGRAM": "Orca", "ORCA_PANE_KEY": "tab-1:leaf-1", "ORCA_TERMINAL_HANDLE": "term_eee"]]
        )

        let found = try session(try provider(inspector).snapshot(now: Self.now), id)

        #expect(found.locator == .orca(tabId: "tab-1", leafId: "leaf-1", handle: "term_eee"))
    }

    // MARK: Terminal.app · iTerm2 · tmux

    private func placedSession(
        pid: Int32,
        n: Int,
        environment: [String: String],
        tty: String? = nil,
        ttys: [Int32: String] = [:],
        parents: [Int32: Int32] = [:]
    ) throws -> AgentSession {
        let id = Self.sessionId(n)
        try writeSession(pid: pid, sessionId: id)
        try writeTranscript(sessionId: id, title: "터미널 세션")
        var allTtys = ttys
        if let tty { allTtys[pid] = tty }
        let inspector = FakeInspector(alive: [pid], environments: [pid: environment], ttys: allTtys, parents: parents)
        return try session(try provider(inspector).snapshot(now: Self.now), id)
    }

    @Test func appleTerminalSessionUsesTty() throws {
        let found = try placedSession(pid: 4011, n: 11, environment: ["TERM_PROGRAM": "Apple_Terminal"], tty: "/dev/ttys004")
        #expect(found.terminalApp == .other("Apple_Terminal"))
        #expect(found.locator == .appleTerminal(tty: "/dev/ttys004"))
    }

    @Test func iTermSessionUsesTty() throws {
        let found = try placedSession(pid: 4014, n: 14, environment: ["TERM_PROGRAM": "iTerm.app"], tty: "/dev/ttys005")
        #expect(found.terminalApp == .other("iTerm.app"))
        #expect(found.locator == .iTerm(tty: "/dev/ttys005"))
    }

    @Test func terminalSessionWithoutTtyFallsBack() throws {
        let found = try placedSession(pid: 4012, n: 12, environment: ["TERM_PROGRAM": "Apple_Terminal"])
        #expect(found.locator == .application(pid: 4012))
    }

    /// nvim `:terminal` 처럼 안쪽 pty 를 만드는 프로그램은 TERM_PROGRAM 을 덮지 않아, 세션의 tty 는 탭의 tty 가 아니다
    @Test func nestedPtyUsesOutermostTty() throws {
        // 세션 4016(안쪽 pty) → 셸 600(안쪽) → nvim 601(탭의 pty) → 셸 602(탭) → Terminal 603(tty 없음)
        let found = try placedSession(
            pid: 4016, n: 16, environment: ["TERM_PROGRAM": "Apple_Terminal"],
            ttys: [4016: "/dev/ttys020", 600: "/dev/ttys020", 601: "/dev/ttys004", 602: "/dev/ttys004"],
            parents: [4016: 600, 600: 601, 601: 602, 602: 603]
        )
        #expect(found.locator == .appleTerminal(tty: "/dev/ttys004"))
    }

    @Test func nonDeviceTtyFallsBack() throws {
        let found = try placedSession(pid: 4017, n: 17, environment: ["TERM_PROGRAM": "iTerm.app"], tty: "/dev/console")
        #expect(found.locator == .application(pid: 4017))
    }

    /// tmux 에서 CLI 로 띄운 IDE 는 TMUX 를 물려받지만 그 안의 세션은 tmux 서버 아래에 있지 않다
    @Test func inheritedTmuxEnvironmentIsIgnored() throws {
        let environment = ["TERM_PROGRAM": "vscode", "TMUX": "/private/tmp/tmux-501/default,4242,0", "TMUX_PANE": "%7"]
        let found = try placedSession(pid: 4018, n: 18, environment: environment, parents: [4018: 700, 700: 701])
        #expect(found.terminalApp == .other("vscode"))
        #expect(found.locator == .application(pid: 4018))
    }

    @Test func tmuxSessionUsesPaneFromEnvironment() throws {
        let environment = ["TERM_PROGRAM": "tmux", "TMUX": "/private/tmp/tmux-501/default,4242,0", "TMUX_PANE": "%7"]
        // 세션 → pane 의 셸 → tmux 서버(4242)
        let found = try placedSession(pid: 4013, n: 13, environment: environment, tty: "/dev/ttys006", parents: [4013: 800, 800: 4242])
        #expect(found.terminalApp == .other("tmux"))
        #expect(found.locator == .tmux(socket: "/private/tmp/tmux-501/default", paneId: "%7", pid: 4013))
    }

    @Test(arguments: [
        ["TERM_PROGRAM": "tmux", "TMUX": "", "TMUX_PANE": "%7"],
        ["TERM_PROGRAM": "tmux", "TMUX": "/private/tmp/tmux-501/default,4242,0", "TMUX_PANE": "7"],
        ["TERM_PROGRAM": "tmux", "TMUX": "relative/socket,4242,0", "TMUX_PANE": "%7"],
        ["TERM_PROGRAM": "tmux", "TMUX_PANE": "%7"],
    ])
    func tmuxWithMalformedEnvironmentFallsBack(environment: [String: String]) throws {
        let found = try placedSession(pid: 4015, n: 15, environment: environment)
        #expect(found.locator == .application(pid: 4015))
    }

    @Test func backgroundSessionUsesJobId() throws {
        let id = Self.sessionId(3)
        try writeSession(pid: 4003, sessionId: id, kind: "bg", status: "busy", name: "nightly-check", jobId: "fe50860d")
        let inspector = FakeInspector(alive: [4003], environments: [4003: ["TERM_PROGRAM": "ghostty"]])

        let found = try session(try provider(inspector).snapshot(now: Self.now), id)

        #expect(found.terminalApp == .unknown)
        #expect(found.locator == .background(jobId: "fe50860d"))
        #expect(inspector.environmentCalls == 0)
    }

    @Test func otherTerminalFallsBackToApplication() throws {
        let id = Self.sessionId(4)
        try writeSession(pid: 4004, sessionId: id)
        let inspector = FakeInspector(alive: [4004], environments: [4004: ["TERM_PROGRAM": "Apple_Terminal"]])

        let found = try session(try provider(inspector).snapshot(now: Self.now), id)

        #expect(found.terminalApp == .other("Apple_Terminal"))
        #expect(found.locator == .application(pid: 4004))
    }

    @Test func unknownTerminalWhenTermProgramIsAbsent() throws {
        let id = Self.sessionId(5)
        try writeSession(pid: 4005, sessionId: id)
        let inspector = FakeInspector(alive: [4005], environments: [4005: ["SHELL": "/bin/zsh"]])

        let found = try session(try provider(inspector).snapshot(now: Self.now), id)

        #expect(found.terminalApp == .unknown)
        #expect(found.locator == .application(pid: 4005))
    }

    @Test(arguments: [nil, "no-colon-here", "only-tab:", ":only-leaf", "a:b:c"] as [String?])
    func orcaWithoutUsablePaneKeyFallsBackToApplication(paneKey: String?) throws {
        let id = Self.sessionId(6)
        try writeSession(pid: 4006, sessionId: id)
        var environment = ["TERM_PROGRAM": "Orca"]
        environment["ORCA_PANE_KEY"] = paneKey
        let inspector = FakeInspector(alive: [4006], environments: [4006: environment])

        let found = try session(try provider(inspector).snapshot(now: Self.now), id)

        #expect(found.terminalApp == .orca)
        #expect(found.locator == .application(pid: 4006))
    }

    @Test func missingTranscriptFallsBackToName() throws {
        let id = Self.sessionId(7)
        try writeSession(pid: 4007, sessionId: id, status: "idle", name: "refactor-notes")
        let inspector = FakeInspector(alive: [4007])

        let found = try session(try provider(inspector).snapshot(now: Self.now), id)

        #expect(found.title == "refactor-notes")
        #expect(found.status == .done)
        #expect(found.lastActivityAt == nil)
    }

    @Test func sessionWithoutAnyNameGetsPlaceholderTitle() throws {
        let id = Self.sessionId(8)
        try writeSession(pid: 4008, sessionId: id, name: "")
        let inspector = FakeInspector(alive: [4008])

        let found = try session(try provider(inspector).snapshot(now: Self.now), id)

        #expect(found.title == "이름 없는 세션")
    }

    @Test func missingCwdFallsBackToHomeDirectory() throws {
        let id = Self.sessionId(9)
        try writeSession(pid: 4009, sessionId: id, cwd: nil)
        let inspector = FakeInspector(alive: [4009])

        let found = try session(try provider(inspector).snapshot(now: Self.now), id)

        #expect(found.cwd == Self.homeDirectory)
    }

    @Test func statusSinceComesFromSessionFileOrFallsBackToNow() throws {
        let stamped = Self.sessionId(1)
        let unstamped = Self.sessionId(2)
        let updatedAt = Self.now.addingTimeInterval(-120)
        try writeSession(pid: 4101, sessionId: stamped, statusUpdatedAt: updatedAt.timeIntervalSince1970 * 1000)
        try writeSession(pid: 4102, sessionId: unstamped)
        let inspector = FakeInspector(alive: [4101, 4102])

        let sessions = try provider(inspector).snapshot(now: Self.now)

        #expect(try session(sessions, stamped).statusSince == updatedAt)
        #expect(try session(sessions, unstamped).statusSince == Self.now)
    }

    @Test func statusSinceWithoutStampStaysAtFirstSightingAcrossPolls() throws {
        let id = Self.sessionId(5)
        try writeSession(pid: 4105, sessionId: id, status: "idle")
        let subject = provider(FakeInspector(alive: [4105]))

        let first = try session(try subject.snapshot(now: Self.now), id)
        let later = try session(try subject.snapshot(now: Self.now.addingTimeInterval(5)), id)

        #expect(first.statusSince == Self.now)
        #expect(later == first)

        try writeSession(pid: 4105, sessionId: id, status: "busy")
        let changed = try session(try subject.snapshot(now: Self.now.addingTimeInterval(10)), id)
        #expect(changed.status == .running)
        #expect(changed.statusSince == Self.now.addingTimeInterval(10))
    }

    @Test func statusSinceWithoutStampRestartsWhenTheSessionReturns() throws {
        let id = Self.sessionId(6)
        let url = try writeSession(pid: 4106, sessionId: id, status: "idle")
        let subject = provider(FakeInspector(alive: [4106]))
        _ = try subject.snapshot(now: Self.now)

        try FileManager.default.removeItem(at: url)
        #expect(try subject.snapshot(now: Self.now.addingTimeInterval(5)).isEmpty)
        try writeSession(pid: 4106, sessionId: id, status: "idle")

        #expect(try session(try subject.snapshot(now: Self.now.addingTimeInterval(10)), id).statusSince == Self.now.addingTimeInterval(10))
    }

    @Test func busySessionWithSilentTranscriptIsStale() throws {
        let quiet = Self.sessionId(3)
        let active = Self.sessionId(4)
        try writeSession(pid: 4103, sessionId: quiet, status: "busy")
        try writeTranscript(sessionId: quiet, modifiedAt: Self.now.addingTimeInterval(-1_200))
        try writeSession(pid: 4104, sessionId: active, status: "busy")
        try writeTranscript(sessionId: active, modifiedAt: Self.now.addingTimeInterval(-5))
        let inspector = FakeInspector(alive: [4103, 4104])

        let sessions = try provider(inspector).snapshot(now: Self.now)

        #expect(try session(sessions, quiet).isStale)
        #expect(try !session(sessions, active).isStale)
    }

    // MARK: 생존·파일 열거

    @Test func deadPidIsDropped() throws {
        let alive = Self.sessionId(1)
        let dead = Self.sessionId(2)
        try writeSession(pid: 4201, sessionId: alive)
        try writeSession(pid: 4202, sessionId: dead)
        let inspector = FakeInspector(alive: [4201])

        let sessions = try provider(inspector).snapshot(now: Self.now)

        #expect(sessions.map(\.key.sessionId) == [alive])
    }

    @Test func missingSessionsDirectoryYieldsEmptyList() throws {
        try FileManager.default.removeItem(at: sessionsDirectory)

        let sessions = try provider(FakeInspector()).snapshot(now: Self.now)

        #expect(sessions.isEmpty)
    }

    @Test func unreadableSessionsDirectoryThrows() throws {
        try FileManager.default.removeItem(at: sessionsDirectory)
        try Data().write(to: sessionsDirectory)

        #expect(throws: (any Error).self) {
            try provider(FakeInspector()).snapshot(now: Self.now)
        }
    }

    @Test func watchesTheSessionsDirectory() {
        #expect(provider(FakeInspector()).id == "claude-code")
        #expect(provider(FakeInspector()).watchedDirectories == [sessionsDirectory])
    }

    @Test func filesOtherThanJsonAreIgnored() throws {
        let id = Self.sessionId(1)
        try writeSession(pid: 4301, sessionId: id)
        try Data("not a session".utf8).write(to: sessionsDirectory.appendingPathComponent("4301.0a1b2c.key"))
        try Data("{}".utf8).write(to: sessionsDirectory.appendingPathComponent("notes.txt"))
        let inspector = FakeInspector(alive: [4301])

        let sessions = try provider(inspector).snapshot(now: Self.now)

        #expect(sessions.map(\.key.sessionId) == [id])
    }

    @Test func orderFollowsFileNamesRegardlessOfEnumerationOrder() throws {
        let ids = (1...3).map(Self.sessionId)
        try writeSession(pid: 4403, sessionId: ids[2])
        try writeSession(pid: 4401, sessionId: ids[0])
        try writeSession(pid: 4402, sessionId: ids[1])
        let inspector = FakeInspector(alive: [4401, 4402, 4403])

        let sessions = try provider(inspector).snapshot(now: Self.now)

        #expect(sessions.map(\.key.sessionId) == ids)
    }

    // MARK: transcript 위치

    @Test(arguments: ["-Users-me-alpha", "-Users-me-beta"])
    func transcriptLookupPrefersNewestWhenDuplicated(newerProject: String) throws {
        let id = Self.sessionId(1)
        let olderProject = newerProject == "-Users-me-alpha" ? "-Users-me-beta" : "-Users-me-alpha"
        try writeSession(pid: 4501, sessionId: id)
        try writeTranscript(
            sessionId: id, project: olderProject, title: "오래된 제목",
            modifiedAt: Self.now.addingTimeInterval(-600)
        )
        try writeTranscript(
            sessionId: id, project: newerProject, title: "최근 제목",
            modifiedAt: Self.now.addingTimeInterval(-30)
        )
        let inspector = FakeInspector(alive: [4501])

        let found = try session(try provider(inspector).snapshot(now: Self.now), id)

        #expect(found.title == "최근 제목")
    }

    @Test func transcriptCreatedAfterFirstSnapshotIsPickedUp() throws {
        let id = Self.sessionId(2)
        try writeSession(pid: 4502, sessionId: id, name: "refactor-notes")
        let subject = provider(FakeInspector(alive: [4502]))

        #expect(try session(try subject.snapshot(now: Self.now), id).title == "refactor-notes")

        try writeTranscript(sessionId: id, title: "새로 생긴 제목")

        #expect(try session(try subject.snapshot(now: Self.now), id).title == "새로 생긴 제목")
    }

    @Test func unchangedTranscriptIsNotReread() throws {
        let id = Self.sessionId(3)
        let stamp = Self.now.addingTimeInterval(-60)
        try writeSession(pid: 4503, sessionId: id)
        let url = try writeTranscript(sessionId: id, title: "제목A", modifiedAt: stamp)
        let subject = provider(FakeInspector(alive: [4503]))

        #expect(try session(try subject.snapshot(now: Self.now), id).title == "제목A")

        // 크기와 수정 시각이 같으면 내용이 바뀌었어도 다시 읽지 않아야 한다
        try writeTranscript(sessionId: id, title: "제목B", modifiedAt: stamp)
        #expect(try session(try subject.snapshot(now: Self.now), id).title == "제목A")

        try FileManager.default.setAttributes([.modificationDate: stamp.addingTimeInterval(10)], ofItemAtPath: url.path)
        let refreshed = try session(try subject.snapshot(now: Self.now), id)
        #expect(refreshed.title == "제목B")
        #expect(refreshed.lastActivityAt == stamp.addingTimeInterval(10))
    }

    // MARK: 환경변수 캐시

    @Test func environmentIsReadOncePerProcess() throws {
        let id = Self.sessionId(1)
        try writeSession(pid: 4601, sessionId: id, procStart: "Fri Oct 16 04:12:10 2026")
        let inspector = FakeInspector(alive: [4601], environments: [4601: ["TERM_PROGRAM": "ghostty"]])
        let subject = provider(inspector)

        _ = try subject.snapshot(now: Self.now)
        _ = try subject.snapshot(now: Self.now)
        #expect(inspector.environmentCalls == 1)

        // 같은 pid 라도 시작 시각이 다르면 다른 프로세스다
        try writeSession(pid: 4601, sessionId: id, procStart: "Fri Oct 16 05:30:00 2026")
        _ = try subject.snapshot(now: Self.now)
        #expect(inspector.environmentCalls == 2)
    }

    @Test func emptyEnvironmentIsRetriedInsteadOfCached() throws {
        let id = Self.sessionId(2)
        try writeSession(pid: 4602, sessionId: id)
        let inspector = FakeInspector(alive: [4602])
        let subject = provider(inspector)

        _ = try subject.snapshot(now: Self.now)
        _ = try subject.snapshot(now: Self.now)

        #expect(inspector.environmentCalls == 2)
    }

    @Test func endedSessionReleasesItsCachedEnvironment() throws {
        let id = Self.sessionId(3)
        let url = try writeSession(pid: 4603, sessionId: id)
        let inspector = FakeInspector(alive: [4603], environments: [4603: ["TERM_PROGRAM": "ghostty"]])
        let subject = provider(inspector)

        _ = try subject.snapshot(now: Self.now)
        try FileManager.default.removeItem(at: url)
        #expect(try subject.snapshot(now: Self.now).isEmpty)
        try writeSession(pid: 4603, sessionId: id)
        _ = try subject.snapshot(now: Self.now)

        #expect(inspector.environmentCalls == 2)
    }

    // MARK: 쓰는 도중 읽기 (Review Focus 1)

    @Test func partialWriteKeepsLastGoodState() throws {
        let id = Self.sessionId(1)
        let url = try writeSession(pid: 4701, sessionId: id, status: "busy", name: "refactor-notes")
        try writeTranscript(sessionId: id, title: "플로팅 위젯")
        let inspector = FakeInspector(alive: [4701], environments: [4701: ["TERM_PROGRAM": "ghostty"]])
        let subject = provider(inspector)
        let before = try subject.snapshot(now: Self.now)
        #expect(before.count == 1)

        try Data("{\"pid\": 12".utf8).write(to: url)
        let during = try subject.snapshot(now: Self.now)

        #expect(during == before)
    }

    @Test func partialWriteOfDeadProcessDropsSession() throws {
        let id = Self.sessionId(2)
        let url = try writeSession(pid: 4702, sessionId: id, status: "busy")
        let inspector = FakeInspector(alive: [4702])
        let subject = provider(inspector)
        #expect(try subject.snapshot(now: Self.now).count == 1)

        try Data("{\"pid\": 12".utf8).write(to: url)
        inspector.kill(4702)

        #expect(try subject.snapshot(now: Self.now).isEmpty)
    }

    @Test func partialWriteWithoutPriorStateSkipsFile() throws {
        try Data("{\"pid\": 12".utf8).write(to: sessionsDirectory.appendingPathComponent("4703.json"))

        #expect(try provider(FakeInspector(alive: [4703])).snapshot(now: Self.now).isEmpty)
    }

    @Test func recoveredFileReplacesLastGoodState() throws {
        let id = Self.sessionId(3)
        let url = try writeSession(pid: 4704, sessionId: id, status: "busy")
        let inspector = FakeInspector(alive: [4704])
        let subject = provider(inspector)
        _ = try subject.snapshot(now: Self.now)
        try Data("{\"pid\": 12".utf8).write(to: url)
        _ = try subject.snapshot(now: Self.now)

        try writeSession(pid: 4704, sessionId: id, status: "idle")

        #expect(try session(try subject.snapshot(now: Self.now), id).status == .done)
    }

    // MARK: 중복 sessionId (R16)

    @Test(arguments: [true, false])
    func duplicateSessionIdKeepsNewestStatusUpdate(newerHasLargerPid: Bool) throws {
        let id = Self.sessionId(1)
        let newerPid: Int32 = newerHasLargerPid ? 4802 : 4801
        let olderPid: Int32 = newerHasLargerPid ? 4801 : 4802
        let newer = Self.now.addingTimeInterval(-10)
        try writeSession(pid: olderPid, sessionId: id, status: "busy", statusUpdatedAt: Self.now.addingTimeInterval(-100).timeIntervalSince1970 * 1000)
        try writeSession(pid: newerPid, sessionId: id, status: "idle", statusUpdatedAt: newer.timeIntervalSince1970 * 1000)
        let inspector = FakeInspector(alive: [4801, 4802])

        let sessions = try provider(inspector).snapshot(now: Self.now)

        #expect(sessions.count == 1)
        #expect(sessions.first?.status == .done)
        #expect(sessions.first?.statusSince == newer)
    }

    @Test(arguments: [nil, 1_799_999_900_000.0] as [Double?])
    func duplicateSessionIdWithSameTimestampKeepsLargerPid(statusUpdatedAt: Double?) throws {
        let id = Self.sessionId(2)
        // 파일 이름순으로는 999 가 뒤라서, 규칙이 이름 순서에 기대면 결과가 뒤집힌다
        try writeSession(pid: 999, sessionId: id, status: "busy", statusUpdatedAt: statusUpdatedAt)
        try writeSession(pid: 1000, sessionId: id, status: "idle", statusUpdatedAt: statusUpdatedAt)
        let inspector = FakeInspector(alive: [999, 1000])

        let sessions = try provider(inspector).snapshot(now: Self.now)

        #expect(sessions.count == 1)
        #expect(sessions.first?.status == .done)
    }

    @Test func deadDuplicateDoesNotShadowLiveOne() throws {
        let id = Self.sessionId(3)
        try writeSession(pid: 4811, sessionId: id, status: "busy", statusUpdatedAt: Self.now.addingTimeInterval(-100).timeIntervalSince1970 * 1000)
        try writeSession(pid: 4812, sessionId: id, status: "idle", statusUpdatedAt: Self.now.addingTimeInterval(-10).timeIntervalSince1970 * 1000)
        let inspector = FakeInspector(alive: [4811])

        let sessions = try provider(inspector).snapshot(now: Self.now)

        #expect(sessions.count == 1)
        #expect(sessions.first?.status == .running)
    }

    // MARK: 제목 기억 (R17)

    @Test func rememberedTitleSurvivesWhenLaterTailHasNone() throws {
        let id = Self.sessionId(1)
        try writeSession(pid: 4901, sessionId: id, name: "refactor-notes")
        try writeTranscript(sessionId: id, title: "제목A", modifiedAt: Self.now.addingTimeInterval(-60))
        let subject = provider(FakeInspector(alive: [4901]))
        #expect(try session(try subject.snapshot(now: Self.now), id).title == "제목A")

        try writeTranscriptFile(sessionId: id, text: noise(bytes: 300_000), modifiedAt: Self.now.addingTimeInterval(-30))

        #expect(try session(try subject.snapshot(now: Self.now), id).title == "제목A")
    }

    @Test func headScanIsSkippedOnceATitleIsKnown() throws {
        let id = Self.sessionId(2)
        try writeSession(pid: 4902, sessionId: id)
        try writeTranscript(sessionId: id, title: "제목A", modifiedAt: Self.now.addingTimeInterval(-60))
        let subject = provider(FakeInspector(alive: [4902]))
        _ = try subject.snapshot(now: Self.now)

        // 앞쪽 제목이 달라졌어도 이미 아는 제목이 있으면 8MB 앞부분을 다시 훑지 않는다
        try writeTranscriptFile(
            sessionId: id, text: try titleLine("제목B", sessionId: id) + noise(bytes: 300_000),
            modifiedAt: Self.now.addingTimeInterval(-30)
        )

        #expect(try session(try subject.snapshot(now: Self.now), id).title == "제목A")
    }

    @Test func newTitleInTailReplacesRememberedOne() throws {
        let id = Self.sessionId(3)
        try writeSession(pid: 4903, sessionId: id)
        try writeTranscript(sessionId: id, title: "제목A", modifiedAt: Self.now.addingTimeInterval(-60))
        let subject = provider(FakeInspector(alive: [4903]))
        _ = try subject.snapshot(now: Self.now)

        try writeTranscript(sessionId: id, title: "제목C", modifiedAt: Self.now.addingTimeInterval(-30))

        #expect(try session(try subject.snapshot(now: Self.now), id).title == "제목C")
    }

    @Test func titleWithoutAnyRecordStillScansHeadUntilOneIsFound() throws {
        let id = Self.sessionId(4)
        try writeSession(pid: 4904, sessionId: id, name: "refactor-notes")
        try writeTranscriptFile(sessionId: id, text: noise(bytes: 300_000), modifiedAt: Self.now.addingTimeInterval(-60))
        let subject = provider(FakeInspector(alive: [4904]))
        #expect(try session(try subject.snapshot(now: Self.now), id).title == "refactor-notes")

        try writeTranscriptFile(
            sessionId: id, text: try titleLine("늦게 생긴 제목", sessionId: id) + noise(bytes: 300_000),
            modifiedAt: Self.now.addingTimeInterval(-30)
        )

        #expect(try session(try subject.snapshot(now: Self.now), id).title == "늦게 생긴 제목")
    }

    // MARK: --resume 한 세션

    /// 앞 프로세스가 띄운 백그라운드 작업은 끝 알림 없이 사라진다. 그 시작 기록만 남은 transcript
    private func writeTranscriptWithBackgroundStart(sessionId: String, startedAt: String) throws {
        let lines = [
            try jsonLine([
                "type": "user", "timestamp": "2026-10-16T03:59:00.000Z",
                "message": ["role": "user", "content": "빌드를 돌려줘"],
            ]),
            try jsonLine([
                "type": "user", "timestamp": startedAt,
                "message": ["role": "user", "content": [[
                    "type": "tool_result", "tool_use_id": "toolu_sample",
                    "content": "Command running in background with ID: bgresume01.",
                ]]],
            ]),
            try jsonLine([
                "type": "assistant", "timestamp": startedAt,
                "message": ["role": "assistant", "content": [["type": "text", "text": "빌드를 돌려 두었습니다."]]],
            ]),
        ]
        try writeTranscriptFile(
            sessionId: sessionId, text: lines.joined(separator: "\n") + "\n", modifiedAt: Self.now.addingTimeInterval(-60)
        )
    }

    @Test func resumedSessionDoesNotInheritEarlierBackgroundWork() throws {
        let id = Self.sessionId(1)
        try writeSession(pid: 5101, sessionId: id, status: "idle", procStart: "Fri Oct 16 04:12:10 2026")
        try writeTranscriptWithBackgroundStart(sessionId: id, startedAt: "2026-10-16T04:00:00.000Z")

        let found = try session(try provider(FakeInspector(alive: [5101])).snapshot(now: Self.now), id)

        #expect(found.status == .done)
    }

    @Test func backgroundWorkStartedByTheCurrentProcessStaysRunning() throws {
        let id = Self.sessionId(2)
        try writeSession(pid: 5102, sessionId: id, status: "idle", procStart: "Fri Oct 16 04:12:10 2026")
        try writeTranscriptWithBackgroundStart(sessionId: id, startedAt: "2026-10-16T04:20:00.000Z")

        let found = try session(try provider(FakeInspector(alive: [5102])).snapshot(now: Self.now), id)

        #expect(found.status == .running)
    }

    @Test func resumeIsNoticedBeforeTheTranscriptChanges() throws {
        let id = Self.sessionId(3)
        try writeSession(pid: 5103, sessionId: id, status: "idle", procStart: "Fri Oct 16 03:00:00 2026")
        try writeTranscriptWithBackgroundStart(sessionId: id, startedAt: "2026-10-16T04:00:00.000Z")
        let subject = provider(FakeInspector(alive: [5103]))
        #expect(try session(try subject.snapshot(now: Self.now), id).status == .running)

        try writeSession(pid: 5103, sessionId: id, status: "idle", procStart: "Fri Oct 16 04:12:10 2026")

        #expect(try session(try subject.snapshot(now: Self.now), id).status == .done)
    }

    // MARK: 서브에이전트 활동 (R18)

    @Test(arguments: ["agent-a1.jsonl", "workflows/wf_1/agent-b2.jsonl"])
    func subagentActivityKeepsWaitingParentFromGoingStale(relativePath: String) throws {
        let id = Self.sessionId(1)
        let written = Self.now.addingTimeInterval(-60)
        try writeSession(pid: 5001, sessionId: id, status: "busy")
        try writeTranscript(sessionId: id, modifiedAt: Self.now.addingTimeInterval(-1_200))
        try writeSubagentFile(sessionId: id, relativePath: relativePath, modifiedAt: written)
        let inspector = FakeInspector(alive: [5001])

        let found = try session(try provider(inspector).snapshot(now: Self.now), id)

        #expect(!found.isStale)
        #expect(found.lastActivityAt == written)
    }

    @Test func parentStaysStaleWhenSubagentsAreQuietToo() throws {
        let id = Self.sessionId(2)
        let written = Self.now.addingTimeInterval(-900)
        try writeSession(pid: 5002, sessionId: id, status: "busy")
        try writeTranscript(sessionId: id, modifiedAt: Self.now.addingTimeInterval(-1_200))
        try writeSubagentFile(sessionId: id, modifiedAt: written)
        let inspector = FakeInspector(alive: [5002])

        let found = try session(try provider(inspector).snapshot(now: Self.now), id)

        #expect(found.isStale)
        #expect(found.lastActivityAt == written)
    }

    @Test func subagentFileOlderThanTranscriptDoesNotRewindActivity() throws {
        let id = Self.sessionId(3)
        let transcriptTime = Self.now.addingTimeInterval(-1_200)
        try writeSession(pid: 5003, sessionId: id, status: "busy")
        try writeTranscript(sessionId: id, modifiedAt: transcriptTime)
        try writeSubagentFile(sessionId: id, modifiedAt: Self.now.addingTimeInterval(-1_500))
        let inspector = FakeInspector(alive: [5003])

        let found = try session(try provider(inspector).snapshot(now: Self.now), id)

        #expect(found.isStale)
        #expect(found.lastActivityAt == transcriptTime)
    }

    @Test func subagentDirectoryIsNotConsultedWhileTranscriptIsFresh() throws {
        let id = Self.sessionId(4)
        let transcriptTime = Self.now.addingTimeInterval(-5)
        try writeSession(pid: 5004, sessionId: id, status: "busy")
        try writeTranscript(sessionId: id, modifiedAt: transcriptTime)
        try writeSubagentFile(sessionId: id, modifiedAt: Self.now.addingTimeInterval(-1))
        let inspector = FakeInspector(alive: [5004])

        let found = try session(try provider(inspector).snapshot(now: Self.now), id)

        #expect(found.lastActivityAt == transcriptTime)
    }

    @Test func subagentActivityIsOnlyCountedForBusySessions() throws {
        let id = Self.sessionId(5)
        let transcriptTime = Self.now.addingTimeInterval(-1_200)
        try writeSession(pid: 5005, sessionId: id, status: "idle")
        try writeTranscript(sessionId: id, modifiedAt: transcriptTime)
        try writeSubagentFile(sessionId: id, modifiedAt: Self.now.addingTimeInterval(-60))
        let inspector = FakeInspector(alive: [5005])

        let found = try session(try provider(inspector).snapshot(now: Self.now), id)

        #expect(found.lastActivityAt == transcriptTime)
    }


    // MARK: 질문과 기록된 답

    private static let askLine = #"{"type":"assistant","uuid":"a-q","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"AskUserQuestion","input":{"questions":[{"question":"만료 방식을 어떻게 할까요?","header":"만료 방식","multiSelect":false,"options":[{"label":"고정 10분 유지"}]}]}}]}}"#
    private static let askResultLine = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"The user answered"}]},"toolUseResult":{"answers":{"만료 방식을 어떻게 할까요?":"고정 10분 유지"}}}"#

    @Test func waitingSessionCarriesPrompt() throws {
        let id = Self.sessionId(7)
        try writeSession(pid: 4071, sessionId: id, status: "waiting", waitingFor: "input needed")
        try writeTranscriptFile(sessionId: id, text: Self.askLine + "\n", modifiedAt: Self.now.addingTimeInterval(-5))
        let inspector = FakeInspector(alive: [4071], environments: [4071: ["TERM_PROGRAM": "ghostty"]])

        let found = try session(try provider(inspector).snapshot(now: Self.now), id)

        #expect(found.status == .waiting)
        #expect(found.prompt?.id == "toolu_01")
    }

    @Test func runningSessionHasNoPrompt() throws {
        let id = Self.sessionId(8)
        try writeSession(pid: 4081, sessionId: id, status: "busy")
        try writeTranscriptFile(sessionId: id, text: Self.askLine + "\n", modifiedAt: Self.now.addingTimeInterval(-5))
        let inspector = FakeInspector(alive: [4081], environments: [4081: ["TERM_PROGRAM": "ghostty"]])

        #expect(try session(try provider(inspector).snapshot(now: Self.now), id).prompt == nil)
    }

    @Test func providerReadsRecordedAnswer() throws {
        let id = Self.sessionId(9)
        try writeSession(pid: 4091, sessionId: id, status: "busy")
        try writeTranscriptFile(
            sessionId: id, text: Self.askLine + "\n" + Self.askResultLine + "\n", modifiedAt: Self.now.addingTimeInterval(-5)
        )
        let reader = provider(FakeInspector(alive: [4091]))

        #expect(reader.recordedAnswer(sessionId: id, promptId: "toolu_01") == .choices(["만료 방식을 어떻게 할까요?": "고정 10분 유지"]))
        #expect(reader.recordedAnswer(sessionId: Self.sessionId(1), promptId: "toolu_01") == nil)
    }
}
