import AgentFloatCore
import Foundation

/// `AGENT_FLOAT_FAKE_SESSIONS=<n>` 일 때 실제 세션 대신 쓰는 시각 검증용 provider.
/// 많은 줄(넘침·스크롤)과 긴 제목(말줄임)을 사람이 세션을 띄우지 않고도 재현하려는 것이다 (Review Focus 2)
struct FakeProvider: AgentProvider {
    let id = "fake"
    let count: Int
    let startedAt: Date
    /// 촬영 시나리오는 가짜 세션 모드에서만 적용한다. 일반 가짜 세션의 넘침 검사는 그대로 둔다.
    var mediaScene: MediaScene? = nil
    var mediaAgent: MediaAgent = .claude

    enum MediaScene: String, CaseIterable { case mixed, choice, multi, body, permission, ask, running, new, unknown }
    enum MediaAgent: String, CaseIterable {
        case claude, codex
        var name: String { self == .claude ? "Claude" : "Codex" }
        var other: Self { self == .claude ? .codex : .claude }
    }

    var watchedDirectories: [URL] { [] }

    /// NEW 는 "켜져 있는 동안 진행 → 완료" 전환에서만 생기므로(spec 4.6), 한 줄을 실행 직후 잠시 진행으로 두었다가 완료로 바꾼다
    private static let finishAfter: TimeInterval = 6

    private static let titles = [
        "에이전트 상태 플로팅 위젯 Liquid Glass 펼침 전환과 테두리 빛 회전 다듬기",
        "feat-checkout-retry: 결제 재시도 backoff 정책을 exponential jitter로 바꾸기",
        "빌드 캐시 설정 조사 (Gradle configuration cache + remote build cache)",
        "로그 분석 스크립트 개선 — Loki query 결과를 CSV로 내보내고 요약하기",
        "API 문서 초안 정리",
        "Refactor SessionStore so that provider failures never blank the widget",
        "릴리스 노트 작성",
        "Investigate flaky CommandRunnerTests under parallel swift test runs",
        "온보딩 화면 카피 다듬기와 다크 모드 대비 점검",
        "Migrate CI from macOS 15 runners to macOS 26 with Xcode 26.4",
        "검색 결과 페이지네이션 버그 재현 및 수정",
        "Write a migration plan for the legacy notification service",
    ]

    private static let folders = ["agent-float", "sample-app", "~", "infra-scripts", "docs-site"]
    private static let reasons: [WaitReason] = [.question, .permission, .bodyQuestion, .worker]

    func snapshot(now: Date) throws -> [AgentSession] {
        if let mediaScene { return mediaSnapshot(scene: mediaScene, now: now) }
        return (0..<count).map { index in
            let status = status(of: index, now: now)
            return AgentSession(
                key: SessionKey(providerId: id, sessionId: "fake-\(index)"),
                agentName: index % 2 == 0 ? "Claude" : "Codex",
                title: Self.titles[index % Self.titles.count],
                cwd: folder(of: index),
                status: status,
                waitReason: status == .waiting ? Self.reasons[index / 4 % Self.reasons.count] : nil,
                statusSince: startedAt.addingTimeInterval(-Double(index) * 420),
                isStale: status == .running && index % 3 == 2,
                lastActivityAt: startedAt.addingTimeInterval(-Double(index) * 420 - 840),
                terminalApp: index % 2 == 0 ? .ghostty : .orca,
                locator: .none,
                prompt: status == .waiting ? Self.prompt(for: index) : nil
            )
        }
    }

    private func mediaSnapshot(scene: MediaScene, now: Date) -> [AgentSession] {
        func session(_ id: String, _ agent: MediaAgent, _ title: String, _ status: AgentStatus,
                     reason: WaitReason? = nil, prompt: PendingPrompt? = nil) -> AgentSession {
            AgentSession(
                key: SessionKey(providerId: self.id, sessionId: "fake-media-\(id)"),
                agentName: agent.name, title: title, cwd: "/demo/\(agent == .claude ? "sample-app" : "agent-float")",
                status: status, waitReason: reason, statusSince: startedAt.addingTimeInterval(-120),
                isStale: false, lastActivityAt: startedAt, terminalApp: agent == .claude ? .ghostty : .orca,
                locator: .none, prompt: prompt
            )
        }
        func question(_ id: String) -> PendingPrompt {
            .choices(id: "media-question-\(id)", questions: [ChoiceQuestion(
                text: "에이전트 이름 표시를 어디까지 적용할까요?",
                header: "적용 범위", multiSelect: false,
                options: [
                    ChoiceOption(label: "목록과 답장 화면 (Recommended)", description: "두 화면에서 같은 배지를 사용합니다", hasPreview: false),
                    ChoiceOption(label: "목록부터 적용", description: "답장 화면은 다음 단계로 진행합니다", hasPreview: false),
                ]
            )])
        }
        switch scene {
        case .mixed:
            return [
                session("claude", .claude, "결제 화면 개선", .waiting, reason: .question, prompt: question("claude")),
                session("codex", .codex, "세션 탐지 기능 추가", .waiting, reason: .question, prompt: question("codex")),
                session("running", .codex, "API 응답 처리", .running),
                session("done", .claude, "회귀 테스트 보완", .done),
            ]
        case .ask:
            return [session("target", mediaAgent, "적용 범위 확인", .waiting, reason: .question, prompt: question("target"))]
        case .running, .unknown, .new:
            let status: AgentStatus = scene == .unknown ? .unknown :
                (scene == .new && now.timeIntervalSince(startedAt) >= Self.finishAfter ? .done : .running)
            return [session("target", mediaAgent, "회귀 테스트 보완", status)]
        case .choice, .multi, .body, .permission:
            let prompt: PendingPrompt = switch scene {
            case .multi: .choices(id: "media-multi", questions: [Self.deployQuestion, Self.cadenceQuestion])
            case .body: .text(id: "media-body", message: Self.bodyMessage)
            case .permission: .permission(id: "media-permission", tool: "Bash", summary: "swift test --parallel")
            default: question("target")
            }
            let reason: WaitReason = scene == .body ? .bodyQuestion : scene == .permission ? .permission : .question
            return [
                session("target", mediaAgent, scene == .permission ? "테스트 실행 승인" : "에이전트 배지 적용", .waiting, reason: reason, prompt: prompt),
                session("running", mediaAgent.other, "API 응답 처리", .running),
                session("done", mediaAgent.other, "회귀 테스트 보완", .done),
            ]
        }
    }

    /// 답장 화면 시안(v1.2 `reply-flow-c.html`)과 같은 가상 질문. 대기 세션은 0, 4, 8, 12, 16… 번째다
    private static func prompt(for index: Int) -> PendingPrompt? {
        switch index {
        case 0:
            .choices(id: "fake-q-\(index)", questions: [expiryQuestion])
        case 4:
            .permission(id: "fake-p-\(index)", tool: "Bash", summary: "swift test --parallel")
        case 8:
            .text(id: "fake-t-\(index)", message: bodyMessage)
        case 16:
            .choices(id: "fake-q-\(index)", questions: [deployQuestion, cadenceQuestion])
        default:
            nil
        }
    }

    private static let expiryQuestion = ChoiceQuestion(
        text: "만료 시간을 지금처럼 고정 10분으로 둘지, 마지막으로 읽은 때부터 다시 세는 방식으로 바꿀지 정해야 합니다. 바꾼 코드는 커밋하지 않고 대기 중입니다. 어느 쪽으로 할까요?",
        header: "만료 방식",
        multiSelect: false,
        options: [
            ChoiceOption(label: "읽은 때부터 다시 세기 (Recommended)", description: "읽을 때마다 만료가 10분 늘어남, 자주 쓰는 항목이 오래 남음", hasPreview: false),
            ChoiceOption(label: "고정 10분 유지", description: "방금 바꾼 코드를 되돌림", hasPreview: false),
            ChoiceOption(label: "둘 다 지원 (설정으로 선택)", description: "설정 항목이 하나 늘어남", hasPreview: false),
        ]
    )

    private static let deployQuestion = ChoiceQuestion(
        text: "서버와 앱 중 어느 쪽을 먼저 내보낼까요?",
        header: "배포 순서",
        multiSelect: false,
        options: [
            ChoiceOption(label: "서버 먼저 (Recommended)", description: "구 앱도 새 응답을 무시하므로 안전", hasPreview: false),
            ChoiceOption(label: "동시에", description: "심사 시점에 따라 어긋날 수 있음", hasPreview: false),
        ]
    )

    private static let cadenceQuestion = ChoiceQuestion(
        text: "색인을 얼마나 자주 다시 만들까요?",
        header: "색인 주기",
        multiSelect: false,
        options: [
            ChoiceOption(label: "매일", description: nil, hasPreview: false),
            ChoiceOption(label: "매주", description: nil, hasPreview: false),
        ]
    )

    private static let bodyMessage = """
    재시도 간격을 1초 → 2초 → 4초로 늘리고, 세 번 실패하면 동기화 실패 안내를 띄우도록 바꿨습니다. 테스트 12개 모두 통과합니다.

    남은 것은 `SyncRetryPolicy`를 서버 설정값으로 뺄지 여부입니다. 지금은 앱에 고정값으로 두었습니다.

    다음 작업(서버 설정값으로 분리)을 진행할까요?
    """

    private func status(of index: Int, now: Date) -> AgentStatus {
        if index == 2, now.timeIntervalSince(startedAt) < Self.finishAfter {
            return .running
        }
        return AgentStatus.allCases[index % AgentStatus.allCases.count]
    }

    private func folder(of index: Int) -> String {
        let name = Self.folders[index % Self.folders.count]
        if name == "~" { return NSHomeDirectory() }
        return NSHomeDirectory() + "/Documents/" + name
    }
}
