import AgentFloatCore
import Foundation
import SwiftUI

/// 2행 사유 자리에 대신 쓰는 말. 쓰다 만 답이나 보내기 실패는 대기 사유보다 먼저 알아야 한다 (v1.2 설계 4.6·4.7)
enum RowNote: Equatable {
    case drafting, failed
}

struct SessionRow: View {
    let session: AgentSession
    let isUnseen: Bool
    let canNavigate: Bool
    let now: Date
    let onActivate: () -> Void
    var note: RowNote? = nil
    /// 줄 안 배치에서 펼친 줄은 바깥 상자가 배경을 깔므로 겹쳐 칠하지 않는다
    var showsBackground = true
    /// 옆 카드가 이 줄의 답장을 보여 주는 중 (설계 4.5 B: 진한 주황 + 1pt 테두리)
    var isSelected = false

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.paintedGlassTone) private var paintedTone

    private static let home = NSHomeDirectory()

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                detailLine
            }
            Spacer(minLength: 0)
            Text(Labels.elapsed(now.timeIntervalSince(session.statusSince)))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
                .padding(.top, 2)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background {
            // 대기 줄에 hover 하면 주황을 덮지 않고 겹쳐야 무엇을 가리키는지 계속 보인다
            if showsBackground {
                ZStack {
                    RoundedRectangle(cornerRadius: Layout.rowCornerRadius).fill(isSelected ? Palette.waiting.opacity(0.26) : statusTint)
                    RoundedRectangle(cornerRadius: Layout.rowCornerRadius).fill(hoverTint)
                    if isSelected {
                        RoundedRectangle(cornerRadius: Layout.rowCornerRadius).strokeBorder(Palette.waiting.opacity(0.55), lineWidth: 1)
                    }
                }
            }
        }
        .opacity(isSeenDone ? 0.62 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Layout.rowCornerRadius))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onActivate)
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(session.title)
                .font(.system(size: 13, weight: isUnseen ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if isUnseen {
                Text("NEW")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.3)
                    .foregroundStyle(Palette.newText(on: paintedTone))
                    .padding(.vertical, 1.5)
                    .padding(.horizontal, 6)
                    .background(Palette.done.opacity(colorScheme == .dark ? 0.2 : 0.18), in: Capsule())
                    .fixedSize()
            }
        }
    }

    private var detailLine: some View {
        HStack(spacing: 5) {
            AgentBadge(session: session)
            if let icon = AppIcons.icon(for: session.terminalApp) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 12, height: 12)
                    .fixedSize()
                    .accessibilityLabel(terminalLabel)
            }
            detailText
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var terminalLabel: String {
        switch session.terminalApp {
        case .ghostty: "Ghostty 터미널"
        case .orca: "Orca 터미널"
        case let .other(name): "\(name) 터미널"
        case .unknown: "터미널"
        }
    }

    private var detailText: Text {
        guard let note else { return Text(detail) }
        let base = Labels.folder(cwd: session.cwd, home: Self.home)
        switch note {
        case .drafting:
            return Text("\(base) · \(Text(ReplyCopy.drafting).foregroundColor(ReplyPalette.accent).fontWeight(.semibold))")
        case .failed:
            return Text("\(base) · \(Text(ReplyCopy.deliveryFailed).foregroundColor(ReplyPalette.failed).fontWeight(.semibold))")
        }
    }

    private var detail: String {
        var parts = [Labels.folder(cwd: session.cwd, home: Self.home)]
        if let reason = session.waitReason, session.status == .waiting {
            parts.append(Labels.waitReason(reason))
        }
        if session.isStale {
            parts.append(Labels.inactivity(since: session.lastActivityAt ?? session.statusSince, now: now))
        }
        return parts.joined(separator: " · ")
    }

    // 응답 없음 의심이면 진행 중이라도 회색으로 둬야 "일하는 중"으로 오해하지 않는다 (spec 4.7)
    private var dotColor: Color {
        session.isStale ? Palette.gray : Palette.dot(for: session.status)
    }

    private var isSeenDone: Bool {
        session.status == .done && !isUnseen
    }

    private var statusTint: Color {
        guard session.status == .waiting else { return .clear }
        return Palette.waiting.opacity(colorScheme == .dark ? 0.14 : 0.12)
    }

    // 눌러도 갈 곳이 없는 줄이 강조되면 이동할 수 있는 것처럼 보인다
    private var hoverTint: Color {
        guard isHovered, canNavigate else { return .clear }
        return Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06)
    }
}
