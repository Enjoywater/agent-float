import Foundation
import Testing
@testable import AgentFloatCore

@Suite struct CommandRunnerTests {
    private let runner = ProcessCommandRunner()

    @Test func returnsStandardOutput() async throws {
        #expect(try await runner.run("/bin/echo", ["hi", "there"]) == "hi there\n")
    }

    @Test func nonZeroExitCarriesStandardError() async {
        await #expect(throws: NavigationError.commandFailed("boom")) {
            try await runner.run("/bin/sh", ["-c", "echo boom >&2; exit 3"])
        }
    }

    @Test func nonZeroExitWithoutStandardErrorNamesTheStatus() async {
        await #expect(throws: NavigationError.commandFailed("exit status 3")) {
            try await runner.run("/bin/sh", ["-c", "exit 3"])
        }
    }

    @Test func missingExecutableIsACommandFailure() async {
        do {
            _ = try await runner.run("/nonexistent/agent-float-tool", [])
            Issue.record("expected a failure")
        } catch let error as NavigationError {
            guard case .commandFailed = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func outputBeyondPipeCapacityDoesNotDeadlock() async throws {
        // 두 파이프 모두 64KiB 버퍼를 넘기므로 하나라도 종료 뒤에 읽으면 자식이 쓰기에서 멈춘다
        let script = "head -c 300000 /dev/zero | tr '\\0' 'a'; head -c 300000 /dev/zero | tr '\\0' 'b' >&2"
        let output = try await runner.run("/bin/sh", ["-c", script])
        #expect(output.count == 300_000)
        #expect(output.allSatisfy { $0 == "a" })
    }

    @Test func standardInputIsClosedSoReadersFinish() async throws {
        #expect(try await runner.run("/bin/cat", []) == "")
    }

    @Test func backgroundChildHoldingThePipeDoesNotHangTheCall() async throws {
        let started = ContinuousClock.now
        let output = try await runner.run("/bin/sh", ["-c", "sleep 4 & echo done"])
        #expect(output == "done\n")
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func concurrentCallsKeepEveryByteOfOutput() async {
        // 병렬로 도는 테스트와 앱의 동시 호출이 같은 조건이다: 프로세스가 먼저 끝나도 이미 쓴 출력은 모두 돌려받아야 한다
        let runner = self.runner
        let failures = await withTaskGroup(of: String?.self) { group in
            for index in 0..<48 {
                group.addTask {
                    let output = try? await runner.run("/bin/sh", ["-c", "echo out-\(index); echo err-\(index) >&2"])
                    return output == "out-\(index)\n" ? nil : "success call \(index) returned \(String(describing: output))"
                }
                group.addTask {
                    do {
                        _ = try await runner.run("/bin/sh", ["-c", "echo err-\(index) >&2; exit 3"])
                        return "failing call \(index) succeeded"
                    } catch {
                        return (error as? NavigationError) == .commandFailed("err-\(index)") ? nil : "failing call \(index) threw \(error)"
                    }
                }
            }
            for _ in 0..<4 {
                group.addTask {
                    let output = try? await runner.run("/bin/sh", ["-c", "sleep 2 & echo bg"])
                    return output == "bg\n" ? nil : "background-child call returned \(String(describing: output))"
                }
            }
            var collected: [String] = []
            for await failure in group {
                if let failure { collected.append(failure) }
            }
            return collected
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    @Test func signalDeathIsReportedAsSignal() async {
        await #expect(throws: NavigationError.commandFailed("terminated by signal 9")) {
            try await runner.run("/bin/sh", ["-c", "kill -9 $$"])
        }
    }

    @Test func cancellingEndsTheRunPromptlyAndTheProcessDies() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("agent-float-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let runner = self.runner
        let task = Task { try await runner.run("/bin/sh", ["-c", "echo $$ > '\(pidFile.path)'; exec sleep 5"]) }

        var pid: Int32?
        for _ in 0..<100 where pid == nil {
            try await Task.sleep(for: .milliseconds(20))
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let child = try #require(pid)

        let cancelledAt = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - cancelledAt < .seconds(1))

        var alive = true
        for _ in 0..<100 where alive {
            try await Task.sleep(for: .milliseconds(20))
            // 신호 0 은 존재 여부만 묻는다. ESRCH 면 프로세스가 정리된 것이다
            alive = kill(child, 0) == 0
        }
        #expect(!alive)
    }

    @Test func cancellingEscalatesWhenTheProcessIgnoresTerminate() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("agent-float-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let runner = self.runner
        let task = Task { try await runner.run("/bin/sh", ["-c", "echo $$ > '\(pidFile.path)'; trap '' TERM; while true; do sleep 0.1; done"]) }

        var pid: Int32?
        for _ in 0..<100 where pid == nil {
            try await Task.sleep(for: .milliseconds(20))
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let child = try #require(pid)

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        // SIGTERM 을 무시하므로 SIGKILL 로 넘어가는 시간(2초)을 넉넉히 기다린다
        var alive = true
        for _ in 0..<200 where alive {
            try await Task.sleep(for: .milliseconds(25))
            alive = kill(child, 0) == 0
        }
        #expect(!alive)
    }

    @Test func alreadyCancelledCallNeverLaunchesTheCommand() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("agent-float-\(UUID().uuidString).marker")
        defer { try? FileManager.default.removeItem(at: marker) }
        let runner = self.runner
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await runner.run("/usr/bin/touch", [marker.path])
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func giveUpOnALingeringChildClosesOurEndOfThePipe() async throws {
        // 유예 시간이 지나 반환한 뒤에도 읽는 쪽이 열려 있으면 파이프를 쥔 자식의 쓰기가 계속 성공한다.
        // 닫혔다면 쓰기가 실패하므로 자식이 남긴 종료 코드가 0 이 아니다
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("agent-float-\(UUID().uuidString).status")
        defer { try? FileManager.default.removeItem(at: marker) }
        let script = "(trap '' PIPE; sleep 2; echo late 2>/dev/null; echo $? > '\(marker.path)') & echo done"

        #expect(try await runner.run("/bin/sh", ["-c", script]) == "done\n")

        var status: String?
        for _ in 0..<100 where status == nil {
            try await Task.sleep(for: .milliseconds(50))
            status = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let written = try #require(status)
        #expect(written != "0", "the runner kept reading after it returned")
    }
}
