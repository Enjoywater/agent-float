import Foundation
import Testing
@testable import AgentFloatCore

@Suite struct NavigationConfirmationTests {
    // MARK: 이동 확인 (R37)

    @Test func expectedAppFollowsTheLocator() {
        #expect(ExpectedFrontmost.expected(for: .ghostty(title: "위젯", cwd: "/w"), activatedPid: nil) == .bundle(TerminalBundle.ghostty))
        #expect(ExpectedFrontmost.expected(for: .background(jobId: "fe50860d"), activatedPid: nil) == .bundle(TerminalBundle.ghostty))
        #expect(ExpectedFrontmost.expected(for: .orca(tabId: "t", leafId: "l"), activatedPid: nil) == .bundle(TerminalBundle.orca))
        #expect(ExpectedFrontmost.expected(for: .application(pid: 100), activatedPid: 80) == .process(80))
    }

    @Test func ttyTerminalsAndTmuxExpectTheirApp() {
        #expect(ExpectedFrontmost.expected(for: .appleTerminal(tty: "/dev/ttys004"), activatedPid: nil) == .bundle(TerminalBundle.appleTerminal))
        #expect(ExpectedFrontmost.expected(for: .iTerm(tty: "/dev/ttys005"), activatedPid: nil) == .bundle(TerminalBundle.iTerm))
        // 바깥 터미널은 실행해 봐야 알므로 실제로 올린 앱을, 그런 앱이 없으면 분리된 세션을 붙인 Ghostty 를 기대한다
        #expect(ExpectedFrontmost.expected(for: .tmux(socket: "/s", paneId: "%1", pid: 9), activatedPid: 77) == .process(77))
        #expect(ExpectedFrontmost.expected(for: .tmux(socket: "/s", paneId: "%1", pid: 9), activatedPid: nil) == .bundle(TerminalBundle.ghostty))
    }

    @Test func fallbackWithoutAChosenAppHasNothingToConfirm() {
        #expect(ExpectedFrontmost.expected(for: .application(pid: 100), activatedPid: nil) == nil)
        #expect(ExpectedFrontmost.expected(for: .none, activatedPid: 80) == nil)
    }

    @Test func bundleTargetIsReachedOnlyByThatApp() {
        let ghostty = ExpectedFrontmost.bundle(TerminalBundle.ghostty)
        #expect(ghostty.isReached(byBundle: TerminalBundle.ghostty, pid: 1234))
        #expect(!ghostty.isReached(byBundle: TerminalBundle.orca, pid: 1234))
        #expect(!ghostty.isReached(byBundle: nil, pid: 1234))
    }

    @Test func processTargetIsReachedOnlyByThatProcess() {
        let terminal = ExpectedFrontmost.process(80)
        #expect(terminal.isReached(byBundle: "com.apple.Terminal", pid: 80))
        #expect(!terminal.isReached(byBundle: "com.apple.Terminal", pid: 81))
        #expect(!terminal.isReached(byBundle: nil, pid: nil))
    }

    // MARK: 직접 선택 감시 주기 (R38)

    @Test func failuresBackOffExponentiallyUpToAMinute() {
        var schedule = FocusWatchSchedule()
        #expect(schedule.interval == .seconds(3))
        var intervals: [Duration] = []
        for _ in 0..<7 {
            schedule.recordFailure(NavigationError.commandFailed("Ghostty got an error: Can’t get window 1. (-1728)"))
            intervals.append(schedule.interval)
        }
        #expect(intervals == [.seconds(6), .seconds(12), .seconds(24), .seconds(48), .seconds(60), .seconds(60), .seconds(60)])
        #expect(!schedule.isSuspended)
    }

    @Test func successResetsTheInterval() {
        var schedule = FocusWatchSchedule()
        schedule.recordFailure(NavigationError.commandFailed("timeout"))
        schedule.recordFailure(NavigationError.commandFailed("timeout"))
        schedule.recordSuccess()
        #expect(schedule.interval == .seconds(3))
    }

    @Test func deniedAutomationSuspendsUntilResumed() {
        let denials = [
            "36:62: execution error: Not authorized to send Apple events to Ghostty. (-1743)",
            "execution error: Ghostty got an error: A privacy consent request is required. (-1744)",
        ]
        for message in denials {
            var schedule = FocusWatchSchedule()
            schedule.recordFailure(NavigationError.commandFailed(message))
            #expect(schedule.isSuspended, "\(message)")
            schedule.resume()
            #expect(!schedule.isSuspended)
            #expect(schedule.interval == .seconds(3))
        }
    }

    @Test func cancellationIsNotAFailure() {
        var schedule = FocusWatchSchedule()
        schedule.recordFailure(CancellationError())
        #expect(schedule.interval == .seconds(3))
        #expect(!schedule.isSuspended)
    }

    @Test func otherErrorsAreNotTreatedAsDenial() {
        #expect(!FocusWatchSchedule.isAutomationDenied(NavigationError.commandFailed("exit status 1")))
        #expect(!FocusWatchSchedule.isAutomationDenied(NavigationError.terminalNotFound))
        #expect(FocusWatchSchedule.isAutomationDenied(NavigationError.commandFailed("Not authorized to send Apple events to Ghostty.")))
    }
}
