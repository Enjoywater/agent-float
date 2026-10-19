import Foundation
import Testing
@testable import AgentFloatCore

@Suite struct TranscriptReaderTests {
    private let epoch = Date(timeIntervalSince1970: 0)

    private func parse(_ lines: [String]) -> TranscriptTail {
        TranscriptReader.parse(lines: lines.map { Substring($0) }, modifiedAt: epoch)
    }

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
    }

    /// 꼬리 창(256KB)보다 큰 파일을 만들기 위한 한 줄 잡음. 줄 하나가 약 1KB
    private func noise(bytes: Int) -> String {
        let line = #"{"type":"system","subtype":"filler","content":""# + String(repeating: "x", count: 1_000) + #""}"# + "\n"
        return String(repeating: line, count: bytes / line.utf8.count + 1)
    }

    private func writeTemp(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-float-\(UUID().uuidString).jsonl")
        try Data(text.utf8).write(to: url)
        return url
    }

    private let aiTitleFront = #"{"type":"ai-title","aiTitle":"앞쪽 제목","sessionId":"00000000-0000-4000-8000-000000000001"}"# + "\n"

    // MARK: 제목

    @Test func titleIsLastAITitle() throws {
        let tail = try TranscriptReader.read(url: fixture("transcript-titles"))
        #expect(tail.aiTitle == "새 제목")
    }

    @Test func titleFoundBeyondTailWindow() throws {
        let url = try writeTemp(aiTitleFront + noise(bytes: 300_000))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try TranscriptReader.read(url: url).aiTitle == "앞쪽 제목")
    }

    @Test func titleScanIsBounded() throws {
        let beyondLimit = noise(bytes: 8_500_000)
        let url = try writeTemp(beyondLimit + aiTitleFront + noise(bytes: 300_000))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try TranscriptReader.read(url: url).aiTitle == nil)
    }

    @Test func headScanCanBeSkipped() throws {
        let url = try writeTemp(aiTitleFront + noise(bytes: 300_000))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try TranscriptReader.read(url: url, scanHeadForTitle: false).aiTitle == nil)
        #expect(try TranscriptReader.read(url: url).aiTitle == "앞쪽 제목")
    }

    @Test func skippingHeadScanStillReadsTitleInsideTailWindow() throws {
        let tail = try TranscriptReader.read(url: fixture("transcript-titles"), scanHeadForTitle: false)
        #expect(tail.aiTitle == "새 제목")
    }

    @Test func firstLineIsKeptWhenFileFitsInWindow() throws {
        let url = try writeTemp(aiTitleFront)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try TranscriptReader.read(url: url).aiTitle == "앞쪽 제목")
    }

    // MARK: 마지막 답변과 사용자 입력

    @Test func lastAssistantTextAndNoPromptAfter() {
        let tail = parse([
            #"{"type":"user","message":{"role":"user","content":"결정이 필요한 부분을 정리해줘"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"먼저 이 내용을 읽어봐."},{"type":"text","text":"어느 쪽이 나을지 알려줘."}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{}}]}}"#,
            #"{"type":"system","subtype":"turn_duration"}"#,
        ])
        #expect(tail.lastAssistantText == "어느 쪽이 나을지 알려줘.")
        #expect(tail.userPromptAfterLastAssistant == false)
    }

    @Test func metaAndToolResultAreNotPrompts() {
        let tail = parse([
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"확인해볼게요."},{"type":"tool_use","name":"Bash","input":{}}]}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"스킬 본문 주입"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_sample","content":"ok"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"<local-command-caveat>The command below was run locally.</local-command-caveat>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<task-notification>\n<task-id>zzz</task-id>\n<status>completed</status>\n</task-notification>"}}"#,
        ])
        #expect(tail.userPromptAfterLastAssistant == false)
    }

    @Test func realPromptAfterAssistant() {
        let tail = parse([
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"A안과 B안 중 고르세요."}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"A안 채택"}}"#,
        ])
        #expect(tail.userPromptAfterLastAssistant == true)
    }

    @Test func promptWithTextBlocksArrayCounts() {
        let tail = parse([
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"답변"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"이어서 해줘"}]}}"#,
        ])
        #expect(tail.userPromptAfterLastAssistant == true)
    }

    @Test func slashCommandNameCountsAsPrompt() {
        let tail = parse([
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"완료했습니다."}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/sample-skill</command-name>\n<command-message>sample-skill</command-message>"}}"#,
        ])
        #expect(tail.userPromptAfterLastAssistant == true)
    }

    private static let localCommandCaveat = #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>The command below was run locally.</local-command-caveat>"}}"#
    private static let effortCommand = #"{"type":"user","message":{"role":"user","content":"<command-name>/effort</command-name>\n<command-message>effort</command-message>\n<command-args></command-args>"}}"#
    private static let effortStdout = #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Effort stays xhigh.</local-command-stdout>"}}"#

    @Test func localCommandWithStdoutIsNotAPrompt() {
        let tail = parse([
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"어느 쪽으로 할까요?"}]}}"#,
            Self.localCommandCaveat, Self.effortCommand, Self.effortStdout,
        ])
        #expect(tail.userPromptAfterLastAssistant == false)
    }

    @Test func localCommandKeepsAnEarlierPromptAndWake() {
        let tail = parse([
            #"{"type":"user","message":{"role":"user","content":"주기적으로 확인해줘"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":270}}]}}"#,
            Self.localCommandCaveat, Self.effortCommand, Self.effortStdout,
        ])
        #expect(tail.pendingWake == true)
        #expect(tail.userPromptAfterLastAssistant == true)
    }

    @Test func commandNameWithoutStdoutStaysAPrompt() {
        let assistant = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"완료했습니다."}]}}"#
        let skillBody = #"{"type":"user","isMeta":true,"message":{"role":"user","content":"스킬 본문 주입"}}"#

        #expect(parse([assistant, Self.effortCommand]).userPromptAfterLastAssistant == true)
        #expect(parse([assistant, Self.effortCommand, skillBody]).userPromptAfterLastAssistant == true)
    }

    // MARK: 백그라운드 작업

    @Test func backgroundBashPendingUntilNotified() {
        var lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_sample","content":"Command running in background with ID: bpt6oenrd. Output is being written to: /sample/tasks/bpt6oenrd.output"}]}}"#,
        ]
        #expect(parse(lines).pendingBackgroundTaskIds == ["bpt6oenrd"])

        lines.append(#"{"type":"queue-operation","operation":"enqueue","content":"<task-notification>\n<task-id>bpt6oenrd</task-id>\n<status>completed</status>\n</task-notification>"}"#)
        #expect(parse(lines).pendingBackgroundTaskIds.isEmpty)
    }

    @Test func asyncAgentPendingUntilNotified() {
        var lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_sample","content":[{"type":"text","text":"Async agent launched successfully.\nagentId: acf1dcf882625c809 (use SendMessage to continue)"}]}]}}"#,
        ]
        #expect(parse(lines).pendingBackgroundTaskIds == ["acf1dcf882625c809"])

        lines.append(#"{"type":"user","message":{"role":"user","content":"<task-notification>\n<task-id>acf1dcf882625c809</task-id>\n<status>completed</status>\n</task-notification>"}}"#)
        #expect(parse(lines).pendingBackgroundTaskIds.isEmpty)
    }

    @Test(arguments: ["failed", "killed", "stopped"])
    func terminalStatusesAllClearPending(status: String) {
        let tail = parse([
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_sample","content":"Command running in background with ID: bgsample01."}]}}"#,
            #"{"type":"attachment","attachment":{"type":"queued_command","prompt":"<task-notification>\n<task-id>bgsample01</task-id>\n<status>"# + status + #"</status>\n</task-notification>"}}"#,
        ])
        #expect(tail.pendingBackgroundTaskIds.isEmpty)
    }

    @Test func nonTerminalStatusKeepsPending() {
        let tail = parse([
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_sample","content":"Command running in background with ID: bgsample01."}]}}"#,
            #"{"type":"queue-operation","operation":"enqueue","content":"<task-notification>\n<task-id>bgsample01</task-id>\n<status>running</status>\n</task-notification>"}"#,
        ])
        #expect(tail.pendingBackgroundTaskIds == ["bgsample01"])
    }

    @Test func synchronousAgentResultIsNotPending() {
        let tail = parse([
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_sample","content":[{"type":"text","text":"조사를 마쳤습니다.\nagentId: a0123456789abcdef (use SendMessage to continue)"}]}]}}"#,
        ])
        #expect(tail.pendingBackgroundTaskIds.isEmpty)
    }

    @Test func quotedStartPhraseInFileContentIsNotPending() {
        let tail = parse([
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_sample","content":"     1\t예: Command running in background with ID: bgquoted01."}]}}"#,
        ])
        #expect(tail.pendingBackgroundTaskIds.isEmpty)
    }

    @Test func mentionsInsideOtherRecordTypesAreIgnored() {
        let tail = parse([
            #"{"type":"api-request-shape","shape":{"system":[{"type":"text","text":"ScheduleWakeup and <task-notification> are described here. Command running in background with ID: ghost. Scheduled recurring job ghost2."}]}}"#,
        ])
        #expect(tail.pendingWake == false)
        #expect(tail.cronLiveUntil == nil)
        #expect(tail.pendingBackgroundTaskIds.isEmpty)
    }

    // MARK: 예약된 재개

    @Test func scheduleWakeupAfterLastPromptIsPending() {
        let prompt = #"{"type":"user","message":{"role":"user","content":"주기적으로 확인해줘"}}"#
        let wake = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":270,"prompt":"확인"}}]}}"#
        let wakeStop = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"stop":true}}]}}"#

        #expect(parse([prompt, wake]).pendingWake == true)
        #expect(parse([prompt, wake, #"{"type":"user","message":{"role":"user","content":"그만하고 다른 거 해줘"}}"#]).pendingWake == false)
        #expect(parse([prompt, wakeStop]).pendingWake == false)
    }

    @Test func lastScheduleWakeupAfterPromptWins() {
        let prompt = #"{"type":"user","message":{"role":"user","content":"주기적으로 확인해줘"}}"#
        let wake = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":270}}]}}"#
        let wakeStop = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"ScheduleWakeup","input":{"stop":true}}]}}"#

        #expect(parse([prompt, wake, wakeStop]).pendingWake == false)
        #expect(parse([prompt, wakeStop, wake]).pendingWake == true)
    }

    // MARK: cron

    /// 2.1.302 실측 CronCreate 결과 문구. 반복은 "recurring job", 한 번은 "one-shot task"
    private func cronScheduled(_ id: String, recurring: Bool = true, at timestamp: String? = "2026-10-17T04:24:11Z") -> String {
        let kind = recurring ? "recurring job" : "one-shot task"
        return #"{"type":"user""# + stamped(timestamp)
            + #","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_cron","content":"Scheduled "#
            + kind + " " + id + #" (Every 5 minutes). Next run: Oct 17 1:29pm. Session-only (not written to disk, dies when Claude exits)."}]}}"#
    }

    private func cronDelete(_ id: String, at timestamp: String? = nil) -> String {
        #"{"type":"assistant""# + stamped(timestamp)
            + #","message":{"role":"assistant","content":[{"type":"tool_use","name":"CronDelete","input":{"id":""# + id + #""}}]}}"#
    }

    private func cronFire(_ id: String) -> String {
        #"{"type":"system","subtype":"scheduled_task_fire","content":"Running scheduled task (Oct 17 1:31pm)","taskId":""# + id + #""}"#
    }

    @Test func cronIsLiveUntilDeleted() {
        let prompt = #"{"type":"user","message":{"role":"user","content":"다음 요청"}}"#

        #expect(parse([cronScheduled("c1")]).cronLiveUntil != nil)
        #expect(parse([cronScheduled("c1"), prompt]).cronLiveUntil != nil)
        #expect(parse([cronScheduled("c1"), cronDelete("c1")]).cronLiveUntil == nil)
    }

    @Test func deletingOneCronKeepsTheOther() {
        #expect(parse([cronScheduled("c1"), cronScheduled("c2"), cronDelete("c1")]).cronLiveUntil != nil)
        #expect(parse([cronScheduled("c1"), cronDelete("other")]).cronLiveUntil != nil)
    }

    @Test func oneShotCronEndsWhenItFires() {
        #expect(parse([cronScheduled("o1", recurring: false), cronFire("o1")]).cronLiveUntil == nil)
        #expect(parse([cronScheduled("r1"), cronFire("r1")]).cronLiveUntil != nil)
    }

    @Test func recurringCronExpiresSevenDaysAfterScheduling() throws {
        let scheduledAt = try Date("2026-10-17T04:24:11Z", strategy: .iso8601)
        let tail = parse([cronScheduled("c1", at: "2026-10-17T04:24:11Z")])

        #expect(tail.cronLiveUntil == scheduledAt.addingTimeInterval(7 * 24 * 3600))
        #expect(tail.hasLiveCron(at: scheduledAt.addingTimeInterval(6 * 24 * 3600)) == true)
        #expect(tail.hasLiveCron(at: scheduledAt.addingTimeInterval(8 * 24 * 3600)) == false)
    }

    @Test func oneShotOrUnstampedCronHasNoExpiry() {
        #expect(parse([cronScheduled("o1", recurring: false)]).cronLiveUntil == .distantFuture)
        #expect(parse([cronScheduled("c1", at: nil)]).cronLiveUntil == .distantFuture)
    }

    @Test func quotedCronResultInFileContentIsNotLive() {
        let tail = parse([
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_sample","content":"     1\t예: Scheduled recurring job quoted1 (Every 5 minutes)."}]}}"#,
        ])
        #expect(tail.cronLiveUntil == nil)
    }

    // MARK: 앞 프로세스가 남긴 일 (--resume)

    private static let processStart = Date(timeIntervalSince1970: 1_792_123_930)
    private static let beforeStart = "2026-10-16T04:12:09.900Z"
    private static let afterStart = "2026-10-16T04:12:12.221Z"

    private func stamped(_ timestamp: String?) -> String {
        timestamp.map { #","timestamp":""# + $0 + #"""# } ?? ""
    }

    private func backgroundStart(_ id: String, at timestamp: String?) -> String {
        #"{"type":"user""# + stamped(timestamp)
            + #","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_sample","content":"Command running in background with ID: "#
            + id + #"."}]}}"#
    }

    private func assistantToolUse(_ name: String, at timestamp: String?) -> String {
        #"{"type":"assistant""# + stamped(timestamp)
            + #","message":{"role":"assistant","content":[{"type":"tool_use","name":""# + name + #"","input":{}}]}}"#
    }

    private func parse(_ lines: [String], since: Date?) -> TranscriptTail {
        TranscriptReader.parse(lines: lines.map { Substring($0) }, modifiedAt: epoch, since: since)
    }

    @Test func backgroundStartBeforeProcessStartIsNotPending() {
        let lines = [backgroundStart("bgold01", at: Self.beforeStart), backgroundStart("bgnew01", at: Self.afterStart)]

        #expect(parse(lines, since: Self.processStart).pendingBackgroundTaskIds == ["bgnew01"])
        #expect(parse(lines, since: nil).pendingBackgroundTaskIds == ["bgold01", "bgnew01"])
    }

    @Test func recordWithoutReadableTimestampIsKept() {
        let lines = [backgroundStart("bgnots01", at: nil), backgroundStart("bgodd01", at: "어제 저녁")]

        #expect(parse(lines, since: Self.processStart).pendingBackgroundTaskIds == ["bgnots01", "bgodd01"])
    }

    @Test func wholeSecondTimestampIsCompared() {
        let lines = [backgroundStart("bgold01", at: "2026-10-16T04:12:09Z")]

        #expect(parse(lines, since: Self.processStart).pendingBackgroundTaskIds.isEmpty)
    }

    @Test func wakeBeforeProcessStartIsNotPending() {
        let prompt = #"{"type":"user","timestamp":"2026-10-16T04:00:00.000Z","message":{"role":"user","content":"주기적으로 확인해줘"}}"#

        #expect(parse([prompt, assistantToolUse("ScheduleWakeup", at: Self.beforeStart)], since: Self.processStart).pendingWake == false)
        #expect(parse([prompt, assistantToolUse("ScheduleWakeup", at: Self.afterStart)], since: Self.processStart).pendingWake == true)
    }

    @Test func cronFromBeforeProcessStartStaysLive() {
        let before = [cronScheduled("c1", at: Self.beforeStart)]

        #expect(parse(before, since: Self.processStart).cronLiveUntil != nil)
        #expect(parse(before + [cronDelete("c1", at: Self.beforeStart)], since: Self.processStart).cronLiveUntil == nil)
    }

    @Test func questionFromBeforeProcessStartStillCounts() {
        let question = #"{"type":"assistant","timestamp":"2026-10-16T04:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"어느 쪽으로 할까요?"}]}}"#
        let answer = #"{"type":"user","timestamp":"2026-10-16T04:01:00.000Z","message":{"role":"user","content":"A안"}}"#

        let unanswered = parse([question], since: Self.processStart)
        #expect(unanswered.lastAssistantText == "어느 쪽으로 할까요?")
        #expect(unanswered.userPromptAfterLastAssistant == false)
        #expect(parse([question, answer], since: Self.processStart).userPromptAfterLastAssistant == true)
    }

    @Test func readPassesProcessStartThrough() throws {
        let text = [backgroundStart("bgold01", at: Self.beforeStart), backgroundStart("bgnew01", at: Self.afterStart)]
            .joined(separator: "\n") + "\n"
        let url = try writeTemp(text)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try TranscriptReader.read(url: url, since: Self.processStart).pendingBackgroundTaskIds == ["bgnew01"])
        #expect(try TranscriptReader.read(url: url).pendingBackgroundTaskIds == ["bgold01", "bgnew01"])
    }

    // MARK: 끝부분 읽기

    @Test func truncatedFirstLineIsIgnored() throws {
        let tail = try TranscriptReader.read(url: fixture("transcript-truncated-head"))
        #expect(tail.lastAssistantText == "진행했습니다. 이어서 할까요?")
        #expect(tail.userPromptAfterLastAssistant == false)
    }

    @Test func windowCutInsideLineDropsOnlyThatLine() throws {
        let hugeAssistantLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"긴 줄"#
            + String(repeating: "y", count: 400_000) + #""}]}}"# + "\n"
        let following = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"창 안쪽의 마지막 답변"}]}}"# + "\n"
        let url = try writeTemp(hugeAssistantLine + following)
        defer { try? FileManager.default.removeItem(at: url) }

        let tail = try TranscriptReader.read(url: url)
        #expect(tail.lastAssistantText == "창 안쪽의 마지막 답변")
    }

    @Test func fixtureReadsPendingWorkEndToEnd() throws {
        let tail = try TranscriptReader.read(url: fixture("transcript-pending-work"))
        #expect(tail.pendingBackgroundTaskIds == ["bgsample01"])
        #expect(tail.pendingWake == true)
        #expect(tail.lastAssistantText == "점검은 끝났고 빌드는 진행 중입니다.")
        #expect(tail.userPromptAfterLastAssistant == false)
    }

    @Test func modifiedAtComesFromTheFile() throws {
        let url = try writeTemp(aiTitleFront)
        defer { try? FileManager.default.removeItem(at: url) }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)

        #expect(try TranscriptReader.read(url: url).modifiedAt == stamp)
    }
}
