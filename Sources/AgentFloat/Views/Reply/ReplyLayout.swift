import AgentFloatCore
import SwiftUI

/// 답장 화면의 수치. v1.2 설계 4.8 표의 값 그대로다
enum ReplyLayout {
    static let width: CGFloat = 320
    static let innerRadius: CGFloat = 12
    static let buttonHeight: CGFloat = 28
    static let buttonRadius: CGFloat = 14
    static let keycapSize: CGFloat = 18
    static let keycapRadius: CGFloat = 5
    static let chipHeight: CGFloat = 18
    static let chipRadius: CGFloat = 9
    static let backSize: CGFloat = 24
    static let titleLeading: CGFloat = 34
    static let contentInset: CGFloat = 10
    static let navToContent: CGFloat = 12
    static let chipToQuestion: CGFloat = 8
    static let questionToOptions: CGFloat = 12
    static let optionGap: CGFloat = 6
    static let optionsToField: CGFloat = 6
    static let contentToFooter: CGFloat = 12
    static let bottomPadding: CGFloat = 10
    static let fieldMaxLines = 5
    static let slideOffset: CGFloat = 12
    static let autoReturn: Duration = .milliseconds(1200)
    /// 본문 질문은 끝에 묻는 말이 있어 끝부분만 보여 준다 (설계 6장 빌더 재량의 출발점)
    static let messageTailLines = 12
    static let messageTailCharacters = 600
    static let messageMaxHeight: CGFloat = 182
    static let messageFade: CGFloat = 34
}

/// 답장 화면의 문구. 설계 4.6 문구 표와 rulings R57·R58·R62 그대로다
enum ReplyCopy {
    struct Strip {
        let title: String
        let detail: String
    }

    static func delivered(_ answer: String) -> Strip {
        Strip(title: "보냈어요", detail: "\"\(answer)\"이 그대로 기록된 것까지 확인했어요")
    }

    static let alreadyAnswered = Strip(title: "터미널에서 이미 답했어요", detail: "")
    static let questionChanged = Strip(title: "질문이 바뀌었어요", detail: "새 질문을 확인해 주세요")
    static let terminalDraft = Strip(title: "터미널 입력 칸에 쓰던 글이 있어요", detail: "섞여 들어갈 수 있어 아무것도 보내지 않았어요. 쓴 답은 남겨 둘게요")
    static let unexpectedScreen = Strip(title: "터미널 화면이 예상과 달라요", detail: "아무것도 보내지 않았어요")
    static let unreadableScreen = Strip(title: "터미널 화면을 확인할 수 없어요", detail: "아무것도 보내지 않았어요")
    static let sessionEnded = Strip(title: "세션이 끝났어요", detail: "")
    static let stopped = Strip(title: "보내다 멈췄어요", detail: "질문 창이 예상과 달라 입력을 멈췄어요. 일부 키가 들어갔을 수 있으니 터미널에서 확인해 주세요")
    static let mismatched = Strip(title: "기록된 답이 보낸 답과 달라요", detail: "")
    static let mismatchTimeout = Strip(title: "기록된 답이 보낸 답과 달라요", detail: "기록을 확인하지 못했어요")
    static let permission = Strip(title: "승인은 터미널에서 해 주세요", detail: "")

    static func readOnly(_ reason: ReadOnlyReason) -> Strip {
        let title = "여기서는 답할 수 없어요"
        switch reason {
        case let .unsupportedTerminal(app):
            return Strip(title: title, detail: "\(app) 터미널에는 여기서 보낼 수 없어요")
        case .hiddenTab:
            return Strip(title: title, detail: "보이지 않는 Ghostty 탭이라 터미널 화면을 확인할 수 없어요")
        case .tabNotFound:
            return Strip(title: title, detail: "이 세션의 Ghostty 탭을 찾지 못했어요")
        case .accessibilityNeeded:
            return Strip(title: title, detail: "Ghostty 화면을 읽으려면 손쉬운 사용 권한이 필요해요")
        case .ambiguousTab:
            return Strip(title: title, detail: "같은 이름의 Ghostty 탭이 여러 개라 어느 탭인지 확실하지 않아요")
        case .splitTab:
            return Strip(title: title, detail: "Ghostty 탭이 나뉘어 있어 어느 화면인지 확실하지 않아요")
        case .previewQuestion:
            return Strip(title: title, detail: "미리보기가 있는 질문은 터미널에서 답해 주세요")
        case .permissionPrompt:
            return permission
        case .promptUnverifiable:
            return Strip(title: title, detail: "이 터미널에서는 입력 칸이 비었는지 확인할 수 없어요")
        }
    }

    static func textBlock(_ block: TextBlock) -> String {
        switch block {
        case .commandLike: "명령으로 읽힐 수 있어 여기서 보낼 수 없어요"
        case .mention: "파일 자동 완성으로 읽힐 수 있어 여기서 보낼 수 없어요"
        case .multiline: "줄바꿈은 여기서 보낼 수 없어요"
        case .controlCharacter: "보낼 수 없는 글자가 들어 있어요"
        }
    }

    static let openTerminal = "터미널에서 열기"
    static let openSettings = "설정 열기"
    static let send = "보내기"
    static let next = "다음"
    static let close = "닫기"
    static let backToList = "목록으로"
    static let recheck = "다시 확인"
    static let otherPlaceholder = "직접 입력"
    static let replyPlaceholder = "답장 입력"
    static let review = "이렇게 보낼게요"
    static let edit = "수정"
    static let fromOther = "직접 입력"
    static let lastMessage = "마지막 답변"
    static let showAll = "전체 보기"
    static let recommended = "추천"
    static let drafting = "작성 중"
    static let deliveryFailed = "보내기 실패"
    static let needsReview = "확인 필요"
    static let sentAnswer = "보낸 답"
    static let recordedAnswer = "기록된 답"
    static let stages = ["같은 질문을 기다리는지 확인", "터미널 화면 확인", "입력하는 중", "기록된 답 확인"]
}

/// 답장 화면의 채움·선 색. 색은 상태·선택·주요 버튼에만 쓴다 (설계 4.8)
enum ReplyPalette {
    static let accent = Color(nsColor: .systemBlue)
    static let failed = Color(nsColor: .systemRed)

    static func fill(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.07 : 0.045)
    }

    static func strongFill(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.11 : 0.075)
    }

    /// 입력 칸의 오목한 바닥
    static func well(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.62)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.16 : 0.12)
    }
}
