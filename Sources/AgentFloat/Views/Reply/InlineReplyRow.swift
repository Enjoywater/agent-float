import AgentFloatCore
import SwiftUI

/// 줄 안 배치(A)에서 목록이 답장 화면을 그리는 데 필요한 것
struct InlineReply {
    let center: ReplyCenter
    let actions: ReplyActions
}

/// 줄 안에서 펼친 대기 줄. 머리 줄은 접힌 줄과 같은 자리에 두고, 답장 내용은 점이 아니라 제목 첫 글자(10 + 7 + 9 = 26)에 맞춘다 (설계 4.8 A 행)
struct InlineReplyRow: View {
    static let contentLeading: CGFloat = 26
    /// 접힌 줄의 아래 여백(7)에 더해 머리 → 칩 10 이 되게 한다
    static let headerToContent: CGFloat = 3

    let session: AgentSession
    let inline: InlineReply
    let now: Date
    let onHeaderTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionRow(session: session, isUnseen: false, canNavigate: true, now: now, onActivate: onHeaderTap, showsBackground: false)
            ReplyContent(center: inline.center, session: session, actions: inline.actions, style: .inline)
                .padding(.top, Self.headerToContent)
                .padding(.leading, Self.contentLeading)
                .padding(.trailing, ReplyLayout.contentInset)
            ReplyFooter(center: inline.center, session: session, actions: inline.actions, insetsHorizontally: false)
                .padding(.leading, Self.contentLeading)
                .padding(.trailing, ReplyLayout.contentInset)
        }
        .background(Palette.waiting.opacity(0.11), in: RoundedRectangle(cornerRadius: Layout.rowCornerRadius))
    }
}
