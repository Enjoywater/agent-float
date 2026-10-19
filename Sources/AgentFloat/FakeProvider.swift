import AgentFloatCore
import Foundation

/// `AGENT_FLOAT_FAKE_SESSIONS=<n>` 일 때 실제 세션 대신 쓰는 시각 검증용 provider.
/// 많은 줄(넘침·스크롤)과 긴 제목(말줄임)을 사람이 세션을 띄우지 않고도 재현하려는 것이다 (Review Focus 2)
struct FakeProvider: AgentProvider {
    let id = "fake"
    let count: Int
    let startedAt: Date

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
        (0..<count).map { index in
            let status = status(of: index, now: now)
            return AgentSession(
                key: SessionKey(providerId: id, sessionId: "fake-\(index)"),
                agentName: "Fake",
                title: Self.titles[index % Self.titles.count],
                cwd: folder(of: index),
                status: status,
                waitReason: status == .waiting ? Self.reasons[index / 4 % Self.reasons.count] : nil,
                statusSince: startedAt.addingTimeInterval(-Double(index) * 420),
                isStale: status == .running && index % 3 == 2,
                lastActivityAt: startedAt.addingTimeInterval(-Double(index) * 420 - 840),
                terminalApp: index % 2 == 0 ? .ghostty : .orca,
                locator: .none
            )
        }
    }

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
