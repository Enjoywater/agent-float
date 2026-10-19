import AgentFloatCore
import SwiftUI

/// 펼친 패널의 요약 줄 아래 부분. 높이 상한은 `PanelController` 가 창 크기와 함께 정해 넘긴다
struct ExpandedPanelView: View {
    let groups: [SessionGroup]
    let unseen: Set<SessionKey>
    let listHeight: CGFloat
    let canNavigate: (AgentSession) -> Bool
    let onActivate: (AgentSession) -> Void

    var body: some View {
        // 경과 시간은 분 단위라 갱신 주기와 상관없이 따로 시계를 둔다. 펼친 동안에만 돌아 접힌 상태의 유휴 CPU에는 영향이 없다
        TimelineView(.periodic(from: .now, by: Motion.labelTick)) { context in
            ScrollView(.vertical) {
                SessionListContent(groups: groups, unseen: unseen, now: context.date, canNavigate: canNavigate, onActivate: onActivate)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: listHeight)
        }
    }
}

/// 스크롤 없이 늘어놓은 목록. 펼치기 전에 같은 뷰로 높이를 재야 창과 유리가 한 번에 목표 높이에 닿는다
struct SessionListContent: View {
    let groups: [SessionGroup]
    let unseen: Set<SessionKey>
    let now: Date
    let canNavigate: (AgentSession) -> Bool
    let onActivate: (AgentSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups, id: \.status) { group in
                HStack(spacing: 4) {
                    Text(Self.title(of: group.status))
                    Text("\(group.sessions.count)").monospacedDigit()
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 3)
                ForEach(group.sessions) { session in
                    SessionRow(
                        session: session,
                        isUnseen: unseen.contains(session.key),
                        canNavigate: canNavigate(session),
                        now: now,
                        onActivate: { onActivate(session) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func title(of status: AgentStatus) -> String {
        switch status {
        case .waiting: "내 응답 대기"
        case .running: "진행 중"
        case .done: "완료"
        case .unknown: "상태 확인 불가"
        }
    }
}
