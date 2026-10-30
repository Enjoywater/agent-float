import Foundation
import Synchronization
import Testing
@testable import AgentFloatCore

private struct ScriptedCodexRPC: CodexRPC, Sendable {
    let handler: @Sendable (String, Data) throws -> Data
    func call(_ method: String, params: Data) throws -> Data { try handler(method, params) }
    func notify(_ method: String) throws { #expect(method == "initialized") }
}

struct CodexCodeProviderTests {
    private static let home = URL(fileURLWithPath: "/nonexistent/agent-float-codex-test")
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func thread(_ id: String, status: String, extra: String = "") -> Data {
        Data("""
        {"thread":{"id":"\(id)","name":"Codex test","preview":"preview","cwd":"/project","updatedAt":1700000000,"source":"cli","status":\(status)\(extra)}}
        """.utf8)
    }

    @Test func mapsAuthoritativeRuntimeStates() throws {
        let cases: [(String, AgentStatus, WaitReason?)] = [
            (#"{"type":"active","activeFlags":[]}"#, .running, nil),
            (#"{"type":"active","activeFlags":["waitingOnApproval"]}"#, .waiting, .permission),
            (#"{"type":"active","activeFlags":["waitingOnUserInput"]}"#, .waiting, .question),
            (#"{"type":"active","activeFlags":["waitingOnUserInput","waitingOnApproval"]}"#, .waiting, .permission),
            (#"{"type":"idle"}"#, .done, nil),
            (#"{"type":"systemError"}"#, .unknown, nil),
            (#"{"type":"futureStatus"}"#, .unknown, nil),
            (#"{"type":"active","activeFlags":["futureFlag"]}"#, .unknown, nil),
            (#"{"type":"active"}"#, .unknown, nil),
        ]
        for (status, expected, reason) in cases {
            let client = ScriptedCodexRPC { method, _ in
                switch method {
                case "initialize": return Data("{}".utf8)
                case "thread/loaded/list": return Data(#"{"data":["a"]}"#.utf8)
                default: return Self.thread("a", status: status)
                }
            }
            let provider = CodexCodeProvider(codexHome: Self.home, makeClient: { client })
            let sessions = try provider.snapshot(now: Self.now)
            let session = try #require(sessions.first)
            #expect(provider.lastError == nil)
            #expect(session.key == SessionKey(providerId: "codex", sessionId: "a"))
            #expect(session.agentName == "Codex")
            #expect(session.status == expected)
            #expect(session.waitReason == reason)
            #expect((session.prompt != nil) == (reason == .permission))
            #expect(session.locator == .none)
            // 오래된 updatedAt으로 실행이 멈췄다고 추정하지 않는다.
            #expect(!session.isStale)
            #expect(try provider.snapshot(now: Self.now.addingTimeInterval(10)) == sessions)
        }
    }

    @Test func paginatesDeduplicatesAndExcludesUnloadedAndSubagents() throws {
        let client = ScriptedCodexRPC { method, params in
            if method == "initialize" { return Data("{}".utf8) }
            let args = try #require(JSONSerialization.jsonObject(with: params) as? [String: Any])
            if method == "thread/loaded/list" {
                if args["cursor"] == nil { return Data(#"{"data":["a","gone","child"],"nextCursor":"page2"}"#.utf8) }
                #expect(args["cursor"] as? String == "page2")
                return Data(#"{"data":["a","b","unloaded","subagent"]}"#.utf8)
            }
            #expect(method == "thread/read")
            #expect(args["includeTurns"] as? Bool == false)
            let id = try #require(args["threadId"] as? String)
            if id == "gone" { throw CodexRPCError.server(-32602) }
            if id == "unloaded" { return Self.thread(id, status: #"{"type":"notLoaded"}"#) }
            if id == "child" { return Self.thread(id, status: #"{"type":"idle"}"#, extra: #", "parentThreadId":"a""#) }
            if id == "subagent" {
                return Data(#"{"thread":{"id":"subagent","cwd":"/project","updatedAt":0,"source":{"subAgent":"review"},"status":{"type":"idle"}}}"#.utf8)
            }
            return Self.thread(id, status: #"{"type":"idle"}"#)
        }
        let provider = CodexCodeProvider(codexHome: Self.home, makeClient: { client })
        #expect(try provider.snapshot(now: Self.now).map(\.key.sessionId) == ["a", "b"])
        #expect(provider.lastError == nil)
    }

    @Test func disconnectDemotesOldStateAndMissingSocketClearsIt() throws {
        let stage = Mutex(0)
        let client = ScriptedCodexRPC { method, _ in
            switch method {
            case "initialize": return Data("{}".utf8)
            case "thread/loaded/list": return Data(#"{"data":["a"]}"#.utf8)
            default: return Self.thread("a", status: #"{"type":"active","activeFlags":[]}"#)
            }
        }
        let provider = CodexCodeProvider(codexHome: Self.home) {
            switch stage.withLock({ $0 }) {
            case 0: return client
            case 1: throw CodexRPCError.timeout
            default: return nil
            }
        }
        #expect(try provider.snapshot(now: Self.now).first?.status == .running)
        stage.withLock { $0 = 1 }
        let disconnected = try #require(provider.snapshot(now: Self.now.addingTimeInterval(5)).first)
        #expect(disconnected.status == .unknown)
        #expect(disconnected.isStale)
        #expect(provider.lastError != nil)
        stage.withLock { $0 = 0 }
        #expect(try provider.snapshot(now: Self.now.addingTimeInterval(10)).first?.status == .running)
        #expect(provider.lastError == nil)
        stage.withLock { $0 = 2 }
        #expect(try provider.snapshot(now: Self.now).isEmpty)
    }

    @Test func noInstalledCodexDoesNotStartServer() throws {
        let provider = CodexCodeProvider(codexHome: Self.home)
        #expect(try provider.snapshot(now: Self.now).isEmpty)
        #expect(provider.lastError == nil)
    }

    @Test func repeatedCursorDoesNotLoopForever() throws {
        let client = ScriptedCodexRPC { method, _ in
            Data((method == "initialize" ? "{}" : #"{"data":[],"nextCursor":"same"}"#).utf8)
        }
        let provider = CodexCodeProvider(codexHome: Self.home, makeClient: { client })
        #expect(try provider.snapshot(now: Self.now).isEmpty)
        #expect(provider.lastError != nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_FLOAT_TEST_LIVE_CODEX"] == "1"))
    func liveSharedDaemonReadOnlySmoke() throws {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        let provider = CodexCodeProvider(codexHome: URL(fileURLWithPath: home))
        let sessions = try provider.snapshot(now: Date())
        #expect(provider.lastError == nil)
        #expect(!sessions.isEmpty)
        #expect(sessions.contains { $0.status == .running })
        #expect(sessions.allSatisfy { $0.locator != .none })
        print("Codex live detection: \(sessions.count) loaded sessions; statuses=\(sessions.map(\.status.rawValue))")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_FLOAT_TEST_LIVE_NAVIGATION"] == "1"))
    func liveDetectedGhosttySessionCanBeFocused() async throws {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        let provider = CodexCodeProvider(codexHome: URL(fileURLWithPath: home))
        let sessions = try provider.snapshot(now: Date())
        let session = try #require(sessions.first { if case .ghostty = $0.locator { return true }; return false })
        let runner = ProcessCommandRunner()
        let navigator = GhosttyNavigator(runner: runner)
        #expect(navigator.canNavigate(session))
        try await navigator.navigate(to: session)
        #expect(try await GhosttyFocusProbe(runner: runner).focusedSessions(among: sessions).contains(session.key))
    }
}
