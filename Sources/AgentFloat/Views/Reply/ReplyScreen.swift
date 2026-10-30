import AgentFloatCore
import SwiftUI

/// 답장 화면의 버튼이 하는 일. 창 크기·키 입력·이동은 패널이 맡아 여기로 넘겨준다
struct ReplyActions {
    var back: () -> Void = {}
    var primary: () -> Void = {}
    var openTerminal: () -> Void = {}
    var close: () -> Void = {}
    var recheck: () -> Void = {}
    var openSettings: () -> Void = {}
    var editQuestion: (Int) -> Void = { _ in }
    /// 실제로 그려진 내용 높이. 화면 밖 측정이 줄 간격 큰 글을 낮게 재는 경우(실측)를 바로잡는 데 쓴다
    var contentHeight: (CGFloat) -> Void = { _ in }
}

private struct ReplyContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 패널이 답장 화면으로 바뀐 모습(C 배치): 내비 줄, 2행, 내용, 버튼 줄 (설계 4.8, 시안 1~10)
struct ReplyScreen: View {
    let center: ReplyCenter
    let session: AgentSession
    let actions: ReplyActions
    /// nil 이면 높이를 재는 중이라 스크롤 없이 내용 그대로 늘어놓는다
    let height: CGFloat?
    /// 옆 카드는 고른 줄에 제목이 있어 에이전트 배지만 따로 표시한다
    var showsHeader = true

    static let compactHeaderHeight: CGFloat = AgentBadge.height + 10
    private var headerHeight: CGFloat { showsHeader ? ReplyHeader.height : Self.compactHeaderHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                ReplyHeader(session: session, isLocked: isSending, onBack: actions.back)
            } else {
                HStack {
                    AgentBadge(session: session)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, ReplyLayout.contentInset)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
            if let height {
                // 내용만 스크롤하고 버튼 줄은 고정한다 (설계 4.8 높이)
                ScrollView(.vertical) {
                    content.background(GeometryReader { proxy in
                        Color.clear.preference(key: ReplyContentHeightKey.self, value: proxy.size.height)
                    })
                }
                    .scrollBounceBehavior(.basedOnSize)
                    .onPreferenceChange(ReplyContentHeightKey.self) { actions.contentHeight($0) }
                    .frame(maxHeight: .infinity)
                    .frame(height: max(0, height - headerHeight - ReplyFooter.height))
            } else {
                content
            }
            ReplyFooter(center: center, session: session, actions: actions)
        }
    }

    private var isSending: Bool {
        if case .sending = center.phase { return true }
        return false
    }

    private var content: some View {
        ReplyContent(center: center, session: session, actions: actions)
            .padding(.horizontal, ReplyLayout.contentInset)
            .padding(.top, ReplyLayout.navToContent)
    }
}

/// "‹" + 제목 + 경과 시간, 그 아래 앱 아이콘·폴더·사유 (‹ 24×24, 제목과 2행은 34에서 시작)
struct ReplyHeader: View {
    /// 내비 줄(위 6 + 24) + 2행(위 1 + 14)
    static let height: CGFloat = 45

    let session: AgentSession
    let isLocked: Bool
    let onBack: () -> Void

    @Environment(\.colorScheme) private var scheme
    private static let home = NSHomeDirectory()

    var body: some View {
        TimelineView(.periodic(from: .now, by: Motion.labelTick)) { context in
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ReplyPalette.accent)
                            .frame(width: ReplyLayout.backSize, height: ReplyLayout.backSize)
                            .background(ReplyPalette.fill(scheme), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLocked)
                    .opacity(isLocked ? 0.4 : 1)
                    .accessibilityLabel("목록으로")
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(Labels.elapsed(context.date.timeIntervalSince(session.statusSince)))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                .padding(.top, 6)
                .padding(.leading, ReplyLayout.titleLeading - ReplyLayout.backSize - 6)
                .padding(.trailing, ReplyLayout.contentInset)
                HStack(spacing: 5) {
                    AgentBadge(session: session)
                    if let icon = AppIcons.icon(for: session.terminalApp) {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 12, height: 12).fixedSize()
                    }
                    Text(detail).lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(height: 14)
                .padding(.leading, ReplyLayout.titleLeading)
                .padding(.trailing, ReplyLayout.contentInset)
            }
        }
    }

    private var detail: String {
        var parts = [Labels.folder(cwd: session.cwd, home: Self.home)]
        if session.status == .waiting, let reason = session.waitReason { parts.append(Labels.waitReason(reason)) }
        return parts.joined(separator: " · ")
    }
}

/// 왼쪽 보조 버튼 + 오른쪽 주요 캡슐 버튼(높이 28, 반경 14, ⏎ 표시)
struct ReplyFooter: View {
    /// 위 12 + 버튼 28 + 아래 10
    static let height: CGFloat = 50

    let center: ReplyCenter
    let session: AgentSession
    let actions: ReplyActions
    /// 줄 안 배치는 바깥 상자가 좌우 여백을 정한다
    var insetsHorizontally = true

    var body: some View {
        HStack(spacing: 8) {
            if let secondary {
                Button(secondary.title, action: secondary.action)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .disabled(!secondary.isEnabled)
                    .opacity(secondary.isEnabled ? 1 : 0.4)
            }
            Spacer(minLength: 0)
            PrimaryButton(model: primary, action: actions.primary)
        }
        .padding(.top, ReplyLayout.contentToFooter)
        .padding(.horizontal, insetsHorizontally ? ReplyLayout.contentInset : 0)
        .padding(.bottom, ReplyLayout.bottomPadding)
    }

    private struct Secondary {
        let title: String
        let action: () -> Void
        var isEnabled = true
    }

    private var readOnly: ReadOnlyReason? {
        if case let .readOnly(reason)? = center.availability[session.key] { return reason }
        return nil
    }

    private var secondary: Secondary? {
        switch center.phase {
        case .sending:
            return Secondary(title: ReplyCopy.openTerminal, action: {}, isEnabled: false)
        case let .result(outcome):
            switch outcome {
            case .delivered, .notSent(.alreadyAnswered), .notSent(.sessionEnded): return nil
            case .notSent: return Secondary(title: ReplyCopy.recheck, action: actions.recheck)
            case .stopped, .mismatched: return Secondary(title: ReplyCopy.close, action: actions.close)
            }
        case .editing:
            if readOnly == .accessibilityNeeded { return Secondary(title: ReplyCopy.openSettings, action: actions.openSettings) }
            if readOnly != nil { return nil }
            return Secondary(title: ReplyCopy.openTerminal, action: actions.openTerminal)
        }
    }

    private var primary: PrimaryButton.Model {
        switch center.phase {
        case .sending:
            return PrimaryButton.Model(title: "보내는 중", style: .accent, isEnabled: false, showsSpinner: true)
        case let .result(outcome):
            switch outcome {
            case .delivered, .notSent(.alreadyAnswered), .notSent(.sessionEnded):
                return PrimaryButton.Model(title: ReplyCopy.backToList, style: .neutral)
            case .notSent, .stopped, .mismatched:
                return PrimaryButton.Model(title: ReplyCopy.openTerminal, style: .accent)
            }
        case .editing:
            if readOnly != nil { return PrimaryButton.Model(title: ReplyCopy.openTerminal, style: .accent) }
            switch center.editor?.primary ?? .disabled {
            case .send: return PrimaryButton.Model(title: ReplyCopy.send, style: .accent)
            case .next: return PrimaryButton.Model(title: ReplyCopy.next, style: .accent)
            case .disabled: return PrimaryButton.Model(title: ReplyCopy.send, style: .accent, isEnabled: false)
            }
        }
    }
}

struct PrimaryButton: View {
    struct Model {
        enum Style {
            case accent, neutral
        }

        let title: String
        let style: Style
        var isEnabled = true
        var showsSpinner = false
    }

    let model: Model
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if model.showsSpinner { ProgressView().controlSize(.mini).tint(.white) }
                Text(model.title).font(.system(size: 13, weight: .semibold))
                if !model.showsSpinner { Text("⏎").font(.system(size: 11)).opacity(0.72) }
            }
            .foregroundStyle(model.style == .accent ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: ReplyLayout.buttonHeight)
            .background(background, in: RoundedRectangle(cornerRadius: ReplyLayout.buttonRadius))
        }
        .buttonStyle(.plain)
        .disabled(!model.isEnabled)
        .opacity(model.isEnabled ? 1 : 0.35)
    }

    private var background: Color {
        model.style == .accent ? ReplyPalette.accent : ReplyPalette.strongFill(scheme)
    }
}

/// 답장 화면 높이를 펼치기 전에 재기 위한 뷰. 스크롤 없이 늘어놓은 같은 내용이다
struct ReplyMeasure: View {
    let center: ReplyCenter
    let session: AgentSession

    var body: some View {
        ReplyScreen(center: center, session: session, actions: ReplyActions(), height: nil)
            .frame(width: ReplyLayout.width - Layout.panelPadding * 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
