import Foundation
import Testing
@testable import AgentFloatCore

struct HerdrInspector: ProcessInspecting {
    var alive = true
    var parents: [Int32: Int32] = [42: 40, 40: 30]
    var ttys: [Int32: String] = [42: "/dev/ttys001", 40: "/dev/ttys001"]
    var paths: [Int32: String] = [30: "/Users/me/.local/bin/herdr-core"]
    var env: [String: String] = ["TERM_PROGRAM": "ghostty", "HC_TERMINAL_ID": "t2", "HC_TERMINAL_SOCKET": "/tmp/core.sock"]
    func isAlive(pid: Int32, procStart: String?) -> Bool { alive }
    func environment(pid: Int32) -> [String: String] { env }
    func parentPid(of pid: Int32) -> Int32? { parents[pid] }
    func tty(pid: Int32) -> String? { ttys[pid] }
    func executablePath(pid: Int32) -> String? { paths[pid] }
}

@Suite struct HerdrTests {
    static let target = HerdrTarget(terminal: "t2", socket: "/tmp/core.sock", pid: 42, procStart: nil, appHome: nil)
    static let terminalJSON = #"{"address":"t2","pid":40,"state":"live","title":"Task | project","labels":{"herdr.space":"space2","herdr.tab":"tab2"}}"#
    static let listing = #"{"spaces":[{"id":"space2","machine":null,"tabs":[{"id":"tab2","terminals":[{"terminal":"t2"}]}]}]}"#
    static let status = #"{"agent":"t2","space":"space2","tab":"tab2"}"#

    @Test func detectsCoreDespiteGhosttyEnvironment() {
        let inspector = HerdrInspector()
        #expect(HerdrTarget.detect(pid: 42, environment: inspector.env, inspector: inspector) == Self.target)
    }

    @Test func inheritedEnvironmentInAnotherTerminalIsNotHerdr() {
        var inspector = HerdrInspector()
        inspector.paths[30] = "/Applications/Ghostty.app/Contents/MacOS/ghostty"
        #expect(HerdrTarget.detect(pid: 42, environment: inspector.env, inspector: inspector) == nil)
        inspector.paths[30] = "/Users/me/.local/bin/herdr-core"
        inspector.ttys.removeValue(forKey: 40)
        inspector.paths[40] = "/Applications/Other.app/Contents/MacOS/Other"
        #expect(HerdrTarget.detect(pid: 42, environment: inspector.env, inspector: inspector) == nil)
    }

    @Test func nestedPtyStillResolvesToHerdrInsteadOfGhostty() throws {
        var inspector = HerdrInspector()
        inspector.ttys[42] = "/dev/ttys009"
        #expect(HerdrTarget.detect(pid: 42, environment: inspector.env, inspector: inspector) == Self.target)
        let terminal = try JSONDecoder().decode(HerdrTerminal.self, from: Data(Self.terminalJSON.utf8))
        #expect(terminal.belongs(to: Self.target, inspector: inspector))
    }

    @Test(arguments: ["", "--help", "remote/t2", "t2\n", "t２"])
    func rejectsInvalidAddress(address: String) {
        #expect(!HerdrTarget.isAddress(address))
    }

    @Test func terminalMustStillBelongToLiveProcess() throws {
        let terminal = try JSONDecoder().decode(HerdrTerminal.self, from: Data(Self.terminalJSON.utf8))
        var inspector = HerdrInspector()
        #expect(terminal.belongs(to: Self.target, inspector: inspector))
        inspector.alive = false
        #expect(!terminal.belongs(to: Self.target, inspector: inspector))
        inspector.alive = true
        inspector.parents = [:]
        #expect(!terminal.belongs(to: Self.target, inspector: inspector))
    }

    @Test func appMappingRejectsOtherCoresRemoteAndDuplicatePanes() throws {
        let terminal = try JSONDecoder().decode(HerdrTerminal.self, from: Data(Self.terminalJSON.utf8))
        #expect(try HerdrCLI.contains(terminal, in: Data(Self.listing.utf8)))
        for invalid in [
            Self.listing.replacingOccurrences(of: "space2", with: "another-core"),
            Self.listing.replacingOccurrences(of: "null", with: "\"remote\""),
            Self.listing.replacingOccurrences(of: #"{"terminal":"t2"}"#, with: #"{"terminal":"t2"},{"terminal":"t2"}"#),
        ] {
            #expect(try !HerdrCLI.contains(terminal, in: Data(invalid.utf8)))
        }
    }

    @Test func navigationValidatesFocusBeforeActivating() async throws {
        let runner = FakeCommandRunner { call in
            if call.arguments.contains("get") { return Self.terminalJSON }
            if call.arguments.last == "ls" { return Self.listing }
            if call.arguments.last == "status" { return Self.status }
            return "{}"
        }
        let activated = CallLog<Void>()
        let navigator = HerdrNavigator(runner: runner, inspector: HerdrInspector(), coreExecutable: "/bin/core", appExecutable: "/bin/app") { activated.append(()) }
        try await navigator.navigate(to: makeSession(locator: .herdr(Self.target)))
        #expect(activated.entries.count == 1)
        #expect(await runner.calls.map(\.arguments) == [
            ["HC_TERMINAL_SOCKET=/tmp/core.sock", "/bin/core", "get", "t2", "--json"],
            ["/bin/app", "ls"], ["/bin/app", "do", "agent.focus", "--terminal", "t2"], ["/bin/app", "status"],
        ])
        #expect(ExpectedFrontmost.expected(for: .herdr(Self.target), activatedPid: nil) == .bundle(TerminalBundle.herdr))
        #expect(!GhosttyNavigator(runner: runner).canNavigate(makeSession(locator: .herdr(Self.target))))
    }

    @Test(arguments: ["core", "listing", "focus", "status", "missing-cli"])
    func failureNeverActivatesOrFallsBack(stage: String) async {
        let runner = FakeCommandRunner { call in
            if call.arguments.contains("get") {
                if stage == "core" { throw NavigationError.commandFailed("unavailable") }
                return Self.terminalJSON
            }
            if call.arguments.last == "ls" { return stage == "listing" ? #"{"spaces":[]}"# : Self.listing }
            if call.arguments.last == "status" { return stage == "status" ? #"{"agent":"t3"}"# : Self.status }
            if stage == "focus" { throw NavigationError.commandFailed("closed") }
            return "{}"
        }
        let activated = CallLog<Void>()
        let navigator = HerdrNavigator(runner: runner, inspector: HerdrInspector(), coreExecutable: stage == "missing-cli" ? nil : "/bin/core", appExecutable: "/bin/app") { activated.append(()) }
        await #expect(throws: (any Error).self) { try await navigator.navigate(to: makeSession(locator: .herdr(Self.target))) }
        #expect(activated.entries.isEmpty)
    }

    @Test func codexHerdrAndGhosttyAreMatchedIndependently() throws {
        let terminal = try JSONDecoder().decode(HerdrTerminal.self, from: Data(Self.terminalJSON.utf8))
        let herdr = CodexProcess(pid: 42, cwd: "/project", environment: ["TERM_PROGRAM": "ghostty"], tty: "/dev/ttys001", herdr: Self.target)
        let ghostty = CodexProcess(pid: 99, cwd: "/project", environment: ["TERM_PROGRAM": "ghostty"], tty: "/dev/ttys002")
        var inventory = CodexTerminalInventory(processes: [herdr, ghostty], ghostty: [GhosttyTerminal(id: "surface", title: "Other", cwd: "/project")], titlesByTTY: [:], tmuxTitles: [:], orcaTitles: [:], herdrTerminals: [Self.target: terminal])
        #expect(inventory.placement(title: "Task", cwd: "/project")?.locator == .herdr(Self.target))
        #expect(inventory.placement(title: "Other", cwd: "/project")?.app == .ghostty)
        inventory.herdrTerminals = [:]
        #expect(inventory.placement(title: "Task", cwd: "/project") == nil)
        #expect(inventory.placement(title: "Other", cwd: "/project")?.app == .ghostty)
    }

    @Test func customAppHomeIsPassedWithoutShellInterpolation() {
        let target = HerdrTarget(terminal: "t2", socket: "/tmp/a b.sock", pid: 42, procStart: nil, appHome: "/tmp/a $(bad)")
        #expect(HerdrCLI.appArguments(target, executable: "/bin/app", command: ["ls"]) == ["HERDR_APP_HOME=/tmp/a $(bad)", "/bin/app", "ls"])
    }

    @Test func closedTerminalIsRejectedBeforeAppCommands() async throws {
        let runner = FakeCommandRunner { _ in Self.terminalJSON.replacingOccurrences(of: "live", with: "finished") }
        let activated = CallLog<Void>()
        let navigator = HerdrNavigator(runner: runner, inspector: HerdrInspector(), coreExecutable: "/bin/core", appExecutable: "/bin/app") { activated.append(()) }
        await #expect(throws: NavigationError.terminalNotFound) { try await navigator.focus(Self.target) }
        #expect(await runner.calls.count == 1)
        #expect(activated.entries.isEmpty)
    }

    @Test func duplicateCodexTitlesInSameDirectoryAreAmbiguous() throws {
        let second = HerdrTarget(terminal: "t3", socket: "/tmp/core.sock", pid: 43, procStart: nil, appHome: nil)
        let terminal = try JSONDecoder().decode(HerdrTerminal.self, from: Data(Self.terminalJSON.utf8))
        let processes = [Self.target, second].map {
            CodexProcess(pid: $0.pid, cwd: "/project", environment: ["TERM_PROGRAM": "ghostty"], tty: "/dev/ttys001", herdr: $0)
        }
        let inventory = CodexTerminalInventory(processes: processes, ghostty: [], titlesByTTY: [:], tmuxTitles: [:], orcaTitles: [:], herdrTerminals: [Self.target: terminal, second: terminal])
        #expect(inventory.placement(title: "Task", cwd: "/project") == nil)
    }

    @Test func tmuxPlacementKeepsPriorityOverHerdr() {
        let process = CodexProcess(pid: 42, cwd: "/project", environment: ["TERM_PROGRAM": "tmux", "TMUX": "/tmp/tmux,30,0", "TMUX_PANE": "%2"], tty: "/dev/ttys001", herdr: Self.target)
        let inventory = CodexTerminalInventory(processes: [process], ghostty: [], titlesByTTY: [:], tmuxTitles: ["/tmp/tmux\t%2": "Task"], orcaTitles: [:])
        #expect(inventory.placement(title: "Task", cwd: "/project")?.locator == .tmux(socket: "/tmp/tmux", paneId: "%2", pid: 42))
    }

    @Test func registryTimeoutCancelsHerdrWithoutActivating() async {
        struct SlowRunner: CommandRunning {
            func run(_ executable: String, _ arguments: [String]) async throws -> String {
                try await Task.sleep(for: .seconds(60))
                return "{}"
            }
        }
        let activated = CallLog<Void>()
        let navigator = HerdrNavigator(runner: SlowRunner(), inspector: HerdrInspector(), coreExecutable: "/bin/core", appExecutable: "/bin/app") { activated.append(()) }
        await #expect(throws: NavigationError.timedOut) {
            try await NavigatorRegistry([navigator]).navigate(to: makeSession(locator: .herdr(Self.target)), timeout: .milliseconds(20))
        }
        #expect(activated.entries.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_FLOAT_TEST_LIVE_HERDR"] == "1"))
    func liveClaudeAndCodexDetectionAndNavigation() async throws {
        let claude = try ClaudeCodeProvider.live().snapshot(now: Date()).filter { $0.terminalApp == .herdr }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        let provider = CodexCodeProvider(codexHome: URL(fileURLWithPath: home))
        let codex = try provider.snapshot(now: Date()).filter { $0.terminalApp == .herdr }
        #expect(provider.lastError == nil)
        #expect(!claude.isEmpty)
        #expect(!codex.isEmpty)
        let navigator = HerdrNavigator(runner: ProcessCommandRunner(), activateHerdr: {})
        for session in claude + codex {
            try await NavigatorRegistry([navigator]).navigate(to: session, timeout: .seconds(8))
        }
        print("Herdr live: Claude=\(claude.count), Codex=\(codex.count); all detected terminals focused and verified")
    }
}
