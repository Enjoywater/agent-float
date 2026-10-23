import Foundation
import Testing
@testable import AgentFloatCore

@Suite struct ClaudeStatusDeriverTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func tail(
        text: String? = nil,
        promptAfter: Bool = false,
        pendingIds: Set<String> = [],
        pendingWake: Bool = false,
        cronLiveUntil: Date? = nil,
        age: TimeInterval = 5
    ) -> TranscriptTail {
        TranscriptTail(
            aiTitle: nil,
            lastAssistantText: text,
            userPromptAfterLastAssistant: promptAfter,
            pendingBackgroundTaskIds: pendingIds,
            pendingWake: pendingWake,
            cronLiveUntil: cronLiveUntil,
            modifiedAt: now.addingTimeInterval(-age)
        )
    }

    private static func file(status: String?, waitingFor: String? = nil) -> ClaudeSessionFile {
        ClaudeSessionFile(
            pid: 4242, sessionId: "00000000-0000-4000-8000-0000000000a1",
            cwd: "/Users/me", kind: "interactive", status: status, waitingFor: waitingFor,
            name: nil, statusUpdatedAt: nil, procStart: nil, jobId: nil
        )
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    // MARK: 도출 표 (행 하나 = 케이스 하나)

    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let file: ClaudeSessionFile
        let tail: TranscriptTail?
        let expected: DerivedStatus

        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(
            name: "waiting → 대기, waitingFor 로 사유 결정",
            file: file(status: "waiting", waitingFor: "input needed"),
            tail: tail(),
            expected: DerivedStatus(status: .waiting, waitReason: .question, isStale: false)
        ),
        Row(
            name: "waiting 은 tail 이 없어도 대기",
            file: file(status: "waiting", waitingFor: "sandbox request"),
            tail: nil,
            expected: DerivedStatus(status: .waiting, waitReason: .sandbox, isStale: false)
        ),
        Row(
            name: "busy + 트랜스크립트가 10분 넘게 정지 → 실행(정체)",
            file: file(status: "busy"),
            tail: tail(age: ClaudeStatusDeriver.staleAfter + 1),
            expected: DerivedStatus(status: .running, waitReason: nil, isStale: true)
        ),
        Row(
            name: "busy + 정확히 10분 → 아직 정체 아님",
            file: file(status: "busy"),
            tail: tail(age: ClaudeStatusDeriver.staleAfter),
            expected: DerivedStatus(status: .running, waitReason: nil, isStale: false)
        ),
        Row(
            name: "busy + 최근 갱신 → 실행",
            file: file(status: "busy"),
            tail: tail(age: 30),
            expected: DerivedStatus(status: .running, waitReason: nil, isStale: false)
        ),
        Row(
            name: "busy + tail 없음 → 정체 근거가 없으니 실행",
            file: file(status: "busy"),
            tail: nil,
            expected: DerivedStatus(status: .running, waitReason: nil, isStale: false)
        ),
        Row(
            name: "idle + 질문으로 끝난 답변 + 이후 입력 없음 → 본문 질문 대기",
            file: file(status: "idle"),
            tail: tail(text: "어느 쪽으로 진행할까요?"),
            expected: DerivedStatus(status: .waiting, waitReason: .bodyQuestion, isStale: false)
        ),
        Row(
            name: "idle + 질문이지만 이후 사용자 입력 있음 → 완료",
            file: file(status: "idle"),
            tail: tail(text: "어느 쪽으로 진행할까요?", promptAfter: true),
            expected: DerivedStatus(status: .done, waitReason: nil, isStale: false)
        ),
        Row(
            name: "idle + 백그라운드 작업 남음 → 실행(정체 아님)",
            file: file(status: "idle"),
            tail: tail(text: "빌드를 돌려 두었습니다.", pendingIds: ["task-1"], age: 3_600),
            expected: DerivedStatus(status: .running, waitReason: nil, isStale: false)
        ),
        Row(
            name: "idle + 예약된 재개 → 실행(정체 아님)",
            file: file(status: "idle"),
            tail: tail(text: "잠시 후 다시 확인합니다.", pendingWake: true, age: 3_600),
            expected: DerivedStatus(status: .running, waitReason: nil, isStale: false)
        ),
        Row(
            name: "idle + 만료 전 cron → 실행(정체 아님)",
            file: file(status: "idle"),
            tail: tail(text: "5분마다 확인합니다.", cronLiveUntil: now.addingTimeInterval(3_600), age: 3_600),
            expected: DerivedStatus(status: .running, waitReason: nil, isStale: false)
        ),
        Row(
            name: "idle + 만료된 cron → 완료",
            file: file(status: "idle"),
            tail: tail(text: "5분마다 확인합니다.", cronLiveUntil: now.addingTimeInterval(-60), age: 3_600),
            expected: DerivedStatus(status: .done, waitReason: nil, isStale: false)
        ),
        Row(
            name: "idle + 남은 일 없음 → 완료",
            file: file(status: "idle"),
            tail: tail(text: "작업을 마쳤습니다."),
            expected: DerivedStatus(status: .done, waitReason: nil, isStale: false)
        ),
        Row(
            name: "shell(백그라운드 셸이 남은 idle) + tail 없음 → 실행(정체 아님)",
            file: file(status: "shell"),
            tail: nil,
            expected: DerivedStatus(status: .running, waitReason: nil, isStale: false)
        ),
        Row(
            name: "shell + 트랜스크립트에 남은 일 흔적 없음 → 그래도 실행",
            file: file(status: "shell"),
            tail: tail(text: "감시를 걸어 두었습니다.", age: 86_400),
            expected: DerivedStatus(status: .running, waitReason: nil, isStale: false)
        ),
        Row(
            name: "shell + 질문으로 끝난 답변 → 본문 질문 대기",
            file: file(status: "shell"),
            tail: tail(text: "어느 쪽으로 진행할까요?"),
            expected: DerivedStatus(status: .waiting, waitReason: .bodyQuestion, isStale: false)
        ),
        Row(
            name: "idle + tail 없음 → 완료",
            file: file(status: "idle"),
            tail: nil,
            expected: DerivedStatus(status: .done, waitReason: nil, isStale: false)
        ),
        Row(
            name: "모르는 status → 알 수 없음",
            file: file(status: "thinking"),
            tail: tail(),
            expected: DerivedStatus(status: .unknown, waitReason: nil, isStale: false)
        ),
        Row(
            name: "status 없음 → 알 수 없음",
            file: file(status: nil),
            tail: tail(),
            expected: DerivedStatus(status: .unknown, waitReason: nil, isStale: false)
        ),
    ]

    @Test(arguments: rows)
    func derivesDisplayStatus(row: Row) {
        let derived = ClaudeStatusDeriver.derive(file: row.file, tail: row.tail, now: Self.now)
        #expect(derived == row.expected)
    }

    // MARK: waitingFor → WaitReason

    @Test(arguments: [
        ("input needed", WaitReason.question),
        ("permission needed", .permission),
        ("Permission prompt", .permission),
        ("worker request", .worker),
        ("sandbox request", .sandbox),
        ("dialog open", .dialog),
        ("", .other("대기")),
        ("   ", .other("대기")),
        ("something new", .other("something new")),
    ])
    func mapsWaitingFor(raw: String, expected: WaitReason) {
        #expect(ClaudeStatusDeriver.waitReason(from: raw) == expected)
    }

    @Test func missingWaitingForFallsBackToGenericLabel() {
        #expect(ClaudeStatusDeriver.waitReason(from: nil) == .other("대기"))
    }

    // MARK: 세션 파일 파싱

    @Test func parsesRealBusyFile() throws {
        let file = try #require(ClaudeSessionFile.parse(fixture("session-busy")))
        #expect(file.pid == 4242)
        #expect(file.sessionId == "00000000-0000-4000-8000-0000000000a1")
        #expect(file.cwd == "/Users/me")
        #expect(file.kind == "interactive")
        #expect(file.status == "busy")
        #expect(file.statusUpdatedAt == 1_792_124_258_017)
        #expect(file.procStart == "Fri Oct 16 04:12:10 2026")
        #expect(file.waitingFor == nil)
        #expect(file.jobId == nil)
    }

    @Test func parsesWaitingFile() throws {
        let file = try #require(ClaudeSessionFile.parse(fixture("session-waiting")))
        #expect(file.status == "waiting")
        #expect(file.waitingFor == "input needed")
    }

    @Test func parsesBackgroundFile() throws {
        let file = try #require(ClaudeSessionFile.parse(fixture("session-bg")))
        #expect(file.kind == "bg")
        #expect(file.jobId == "fe50860d")
        #expect(file.name == "nightly-check")
    }

    @Test func rejectsGarbage() {
        #expect(ClaudeSessionFile.parse(Data(#"{"pid": 12"#.utf8)) == nil)
        #expect(ClaudeSessionFile.parse(Data("[]".utf8)) == nil)
    }

    @Test func rejectsFilesMissingIdentity() {
        #expect(ClaudeSessionFile.parse(Data(#"{"sessionId":"s","status":"idle"}"#.utf8)) == nil)
        #expect(ClaudeSessionFile.parse(Data(#"{"pid":7,"status":"idle"}"#.utf8)) == nil)
    }

    @Test func oddOptionalFieldDoesNotDropTheSession() throws {
        let data = Data(#"{"pid":7,"sessionId":"s","status":5,"statusUpdatedAt":"later","cwd":"/Users/me"}"#.utf8)
        let file = try #require(ClaudeSessionFile.parse(data))
        #expect(file.status == nil)
        #expect(file.statusUpdatedAt == nil)
        #expect(file.cwd == "/Users/me")
    }

    // MARK: 파일 → 상태 (픽스처 통합)

    @Test func unknownStatusIsGrayNotRunning() throws {
        let file = try #require(ClaudeSessionFile.parse(fixture("session-unknown-status")))
        #expect(file.status == "thinking")
        let derived = ClaudeStatusDeriver.derive(file: file, tail: Self.tail(), now: Self.now)
        #expect(derived.status == .unknown)
    }

    @Test func questionBeatsPendingWork() throws {
        let file = try #require(ClaudeSessionFile.parse(fixture("session-idle")))
        let tail = Self.tail(text: "배포를 진행할까요?", pendingIds: ["task-1"])
        let derived = ClaudeStatusDeriver.derive(file: file, tail: tail, now: Self.now)
        #expect(derived.status == .waiting)
        #expect(derived.waitReason == .bodyQuestion)
    }


    // MARK: 대기 사유 → 질문

    private static let question = ChoiceQuestion(
        text: "만료 방식을 어떻게 할까요?",
        header: "만료 방식",
        multiSelect: false,
        options: [ChoiceOption(label: "고정 10분 유지", description: nil, hasPreview: false)]
    )

    @Test func questionReasonUsesOpenQuestion() {
        var tail = Self.tail()
        tail.openQuestion = .choices(id: "toolu_01", questions: [Self.question])
        #expect(ClaudeStatusDeriver.prompt(for: .question, tail: tail) == .choices(id: "toolu_01", questions: [Self.question]))
    }

    @Test func bodyQuestionUsesLastAssistantText() {
        var tail = Self.tail(text: "다음 작업을 진행할까요?")
        tail.lastAssistantId = "a-2"
        #expect(ClaudeStatusDeriver.prompt(for: .bodyQuestion, tail: tail) == .text(id: "a-2", message: "다음 작업을 진행할까요?"))

        tail.lastAssistantId = nil
        #expect(ClaudeStatusDeriver.prompt(for: .bodyQuestion, tail: tail) == nil)
    }

    @Test func permissionUsesOpenToolUse() {
        var tail = Self.tail()
        tail.openToolUse = OpenToolUse(id: "toolu_02", name: "Bash", summary: "swift test")
        #expect(ClaudeStatusDeriver.prompt(for: .permission, tail: tail) == .permission(id: "toolu_02", tool: "Bash", summary: "swift test"))
    }

    @Test func otherReasonsHaveNoPrompt() {
        var tail = Self.tail(text: "다음 작업을 진행할까요?")
        tail.lastAssistantId = "a-2"
        tail.openToolUse = OpenToolUse(id: "toolu_02", name: "Bash", summary: "swift test")
        #expect(ClaudeStatusDeriver.prompt(for: .worker, tail: tail) == nil)
        #expect(ClaudeStatusDeriver.prompt(for: nil, tail: tail) == nil)
        #expect(ClaudeStatusDeriver.prompt(for: .question, tail: nil) == nil)
    }
}
