import AgentFloatCore
import SwiftUI

/// State needed for list rendering of inline replies (placement A).
struct InlineReply {
    let center: ReplyCenter
    let actions: ReplyActions
}

/// Keep the header fixed; align reply content to the title's first character, not the dot: 10 + 7 + 9 = 26 (design §4.8 A).
struct InlineReplyRow: View {
    static let contentLeading: CGFloat = 26
    /// Add to the collapsed row's bottom padding of 7 to make header-to-chip spacing 10.
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
