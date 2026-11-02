import AgentFloatCore

struct ReplyStrings: Sendable {
    let sent: String
    let alreadyAnsweredInTheTerminal: String
    let theQuestionChanged: String
    let reviewTheNewQuestion: String
    let theTerminalAlreadyHasADraft: String
    let nothingWasSentToAvoidMixingText: String
    let theTerminalScreenChangedUnexpectedly: String
    let nothingWasSent: String
    let couldNotReadTheTerminalScreen: String
    let theSessionEnded: String
    let sendingStopped: String
    let theDialogChangedUnexpectedlySomeKeysMay: String
    let theRecordedAnswerDoesNotMatch: String
    let couldNotVerifyTheRecordedAnswer: String
    let approveInTheTerminal: String
    let cannotReplyHere: String
    let thisGhosttyTabIsHiddenSoIts: String
    let couldNotFindThisSessionSGhostty: String
    let accessibilityPermissionIsRequiredToReadGhostty: String
    let multipleGhosttyTabsHaveThisTitleThe: String
    let theGhosttyTabIsSplitTheTarget: String
    let answerQuestionsWithPreviewsInTheTerminal: String
    let thisCouldBeInterpretedAsACommand: String
    let thisCouldTriggerFileCompletionSendIt: String
    let multilineRepliesCannotBeSentHere: String
    let thisContainsUnsupportedControlCharacters: String
    let openInTerminal: String
    let openSettings: String
    let send: String
    let next: String
    let close: String
    let backToList: String
    let recheck: String
    let customInput: String
    let writeAReply: String
    let reviewYourAnswers: String
    let edit: String
    let lastReply: String
    let showAll: String
    let recommended: String
    let drafting: String
    let sendFailed: String
    let needsAttention: String
    let sentAnswer: String
    let recordedAnswer: String
    let checkingTheQuestion: String
    let checkingTheTerminalScreen: String
    let enteringYourAnswer: String
    let verifyingTheRecordedAnswer: String
    let deliveredDetail: @Sendable (String) -> String
    let unsupportedDetail: @Sendable (String?) -> String
    let tooLong: @Sendable (Int) -> String

    struct Strip: Sendable {
        let title: String
        let detail: String
    }

    func delivered(_ answer: String) -> Strip {
        Strip(title: sent, detail: deliveredDetail(answer))
    }

    var alreadyAnswered: Strip { Strip(title: alreadyAnsweredInTheTerminal, detail: "") }
    var questionChanged: Strip { Strip(title: theQuestionChanged, detail: reviewTheNewQuestion) }
    var terminalDraft: Strip { Strip(title: theTerminalAlreadyHasADraft, detail: nothingWasSentToAvoidMixingText) }
    var unexpectedScreen: Strip { Strip(title: theTerminalScreenChangedUnexpectedly, detail: nothingWasSent) }
    var unreadableScreen: Strip { Strip(title: couldNotReadTheTerminalScreen, detail: nothingWasSent) }
    var sessionEnded: Strip { Strip(title: theSessionEnded, detail: "") }
    var stopped: Strip { Strip(title: sendingStopped, detail: theDialogChangedUnexpectedlySomeKeysMay) }
    var mismatched: Strip { Strip(title: theRecordedAnswerDoesNotMatch, detail: "") }
    var mismatchTimeout: Strip { Strip(title: theRecordedAnswerDoesNotMatch, detail: couldNotVerifyTheRecordedAnswer) }
    var permission: Strip { Strip(title: approveInTheTerminal, detail: "") }

    func readOnly(_ reason: ReadOnlyReason) -> Strip {
        let title = cannotReplyHere
        switch reason {
        case let .unsupportedTerminal(app):
            return Strip(title: title, detail: unsupportedDetail(app))
        case .hiddenTab:
            return Strip(title: title, detail: thisGhosttyTabIsHiddenSoIts)
        case .tabNotFound:
            return Strip(title: title, detail: couldNotFindThisSessionSGhostty)
        case .accessibilityNeeded:
            return Strip(title: title, detail: accessibilityPermissionIsRequiredToReadGhostty)
        case .ambiguousTab:
            return Strip(title: title, detail: multipleGhosttyTabsHaveThisTitleThe)
        case .splitTab:
            return Strip(title: title, detail: theGhosttyTabIsSplitTheTarget)
        case .previewQuestion:
            return Strip(title: title, detail: answerQuestionsWithPreviewsInTheTerminal)
        case .permissionPrompt:
            return permission
        }
    }

    func textBlock(_ block: TextBlock) -> String {
        switch block {
        case .commandLike: thisCouldBeInterpretedAsACommand
        case .mention: thisCouldTriggerFileCompletionSendIt
        case .multiline: multilineRepliesCannotBeSentHere
        case .controlCharacter: thisContainsUnsupportedControlCharacters
        case .tooLong: tooLong(ReplyText.pasteFoldLimit)
        }
    }

    var openTerminal: String { openInTerminal }
    var otherPlaceholder: String { customInput }
    var replyPlaceholder: String { writeAReply }
    var review: String { reviewYourAnswers }
    var fromOther: String { customInput }
    var lastMessage: String { lastReply }
    var deliveryFailed: String { sendFailed }
    var needsReview: String { needsAttention }
    var stages: [String] { [checkingTheQuestion, checkingTheTerminalScreen, enteringYourAnswer, verifyingTheRecordedAnswer] }

    static let ko = ReplyStrings(
        sent: "보냈어요",
        alreadyAnsweredInTheTerminal: "터미널에서 이미 답했어요",
        theQuestionChanged: "질문이 바뀌었어요",
        reviewTheNewQuestion: "새 질문을 확인해 주세요",
        theTerminalAlreadyHasADraft: "터미널 입력 칸에 쓰던 글이 있어요",
        nothingWasSentToAvoidMixingText: "섞여 들어갈 수 있어 답을 보내지 않았어요. 쓴 답은 남겨 둘게요",
        theTerminalScreenChangedUnexpectedly: "터미널 화면이 예상과 달라요",
        nothingWasSent: "아무것도 보내지 않았어요",
        couldNotReadTheTerminalScreen: "터미널 화면을 확인할 수 없어요",
        theSessionEnded: "세션이 끝났어요",
        sendingStopped: "보내다 멈췄어요",
        theDialogChangedUnexpectedlySomeKeysMay: "질문 창이 예상과 달라 입력을 멈췄어요. 일부 키가 들어갔을 수 있으니 터미널에서 확인해 주세요",
        theRecordedAnswerDoesNotMatch: "기록된 답이 보낸 답과 달라요",
        couldNotVerifyTheRecordedAnswer: "기록을 확인하지 못했어요",
        approveInTheTerminal: "승인은 터미널에서 해 주세요",
        cannotReplyHere: "여기서는 답할 수 없어요",
        thisGhosttyTabIsHiddenSoIts: "보이지 않는 Ghostty 탭이라 터미널 화면을 확인할 수 없어요",
        couldNotFindThisSessionSGhostty: "이 세션의 Ghostty 탭을 찾지 못했어요",
        accessibilityPermissionIsRequiredToReadGhostty: "Ghostty 화면을 읽으려면 손쉬운 사용 권한이 필요해요",
        multipleGhosttyTabsHaveThisTitleThe: "같은 이름의 Ghostty 탭이 여러 개라 어느 탭인지 확실하지 않아요",
        theGhosttyTabIsSplitTheTarget: "Ghostty 탭이 나뉘어 있어 어느 화면인지 확실하지 않아요",
        answerQuestionsWithPreviewsInTheTerminal: "미리보기가 있는 질문은 터미널에서 답해 주세요",
        thisCouldBeInterpretedAsACommand: "명령으로 읽힐 수 있어 여기서 보낼 수 없어요",
        thisCouldTriggerFileCompletionSendIt: "파일 자동 완성으로 읽힐 수 있어 여기서 보낼 수 없어요",
        multilineRepliesCannotBeSentHere: "줄바꿈은 여기서 보낼 수 없어요",
        thisContainsUnsupportedControlCharacters: "보낼 수 없는 글자가 들어 있어요",
        openInTerminal: "터미널에서 열기",
        openSettings: "설정 열기",
        send: "보내기",
        next: "다음",
        close: "닫기",
        backToList: "목록으로",
        recheck: "다시 확인",
        customInput: "직접 입력",
        writeAReply: "답장 입력",
        reviewYourAnswers: "이렇게 보낼게요",
        edit: "수정",
        lastReply: "마지막 답변",
        showAll: "전체 보기",
        recommended: "추천",
        drafting: "작성 중",
        sendFailed: "보내기 실패",
        needsAttention: "확인 필요",
        sentAnswer: "보낸 답",
        recordedAnswer: "기록된 답",
        checkingTheQuestion: "같은 질문을 기다리는지 확인",
        checkingTheTerminalScreen: "터미널 화면 확인",
        enteringYourAnswer: "입력하는 중",
        verifyingTheRecordedAnswer: "기록된 답 확인",
        deliveredDetail: { "보낸 답이 그대로 기록된 것을 확인했어요: \"\($0)\"" },
        unsupportedDetail: { app in
            if let app { return "\(app) 터미널에는 여기서 보낼 수 없어요" }
            return "이 터미널에는 여기서 보낼 수 없어요"
        },
        tooLong: { "\($0)자를 넘는 글은 여기서 보낼 수 없어요" }
    )

    static let en = ReplyStrings(
        sent: "Sent",
        alreadyAnsweredInTheTerminal: "Already answered in the terminal",
        theQuestionChanged: "The question changed",
        reviewTheNewQuestion: "Review the new question.",
        theTerminalAlreadyHasADraft: "The terminal already has a draft",
        nothingWasSentToAvoidMixingText: "Nothing was sent to avoid mixing text. Your draft is preserved.",
        theTerminalScreenChangedUnexpectedly: "The terminal screen changed unexpectedly",
        nothingWasSent: "Nothing was sent.",
        couldNotReadTheTerminalScreen: "Could not read the terminal screen",
        theSessionEnded: "The session ended",
        sendingStopped: "Sending stopped",
        theDialogChangedUnexpectedlySomeKeysMay: "The dialog changed unexpectedly. Some keys may have been sent. Check the terminal.",
        theRecordedAnswerDoesNotMatch: "The recorded answer does not match",
        couldNotVerifyTheRecordedAnswer: "Could not verify the recorded answer.",
        approveInTheTerminal: "Approve in the terminal",
        cannotReplyHere: "Cannot reply here",
        thisGhosttyTabIsHiddenSoIts: "This Ghostty tab is hidden, so its screen cannot be read.",
        couldNotFindThisSessionSGhostty: "Could not find this session’s Ghostty tab.",
        accessibilityPermissionIsRequiredToReadGhostty: "Accessibility permission is required to read Ghostty.",
        multipleGhosttyTabsHaveThisTitleThe: "Multiple Ghostty tabs have this title. The target is ambiguous.",
        theGhosttyTabIsSplitTheTarget: "The Ghostty tab is split. The target screen is ambiguous.",
        answerQuestionsWithPreviewsInTheTerminal: "Answer questions with previews in the terminal.",
        thisCouldBeInterpretedAsACommand: "This could be interpreted as a command. Send it in the terminal.",
        thisCouldTriggerFileCompletionSendIt: "This could trigger file completion. Send it in the terminal.",
        multilineRepliesCannotBeSentHere: "Multiline replies cannot be sent here.",
        thisContainsUnsupportedControlCharacters: "This contains unsupported control characters.",
        openInTerminal: "Open in Terminal",
        openSettings: "Open Settings",
        send: "Send",
        next: "Next",
        close: "Close",
        backToList: "Back to List",
        recheck: "Recheck",
        customInput: "Custom input",
        writeAReply: "Write a reply",
        reviewYourAnswers: "Review your answers",
        edit: "Edit",
        lastReply: "Last reply",
        showAll: "Show All",
        recommended: "Recommended",
        drafting: "Drafting",
        sendFailed: "Send failed",
        needsAttention: "Needs attention",
        sentAnswer: "Sent answer",
        recordedAnswer: "Recorded answer",
        checkingTheQuestion: "Checking the question",
        checkingTheTerminalScreen: "Checking the terminal screen",
        enteringYourAnswer: "Entering your answer",
        verifyingTheRecordedAnswer: "Verifying the recorded answer",
        deliveredDetail: { "Verified the recorded answer: \"\($0)\"" },
        unsupportedDetail: { app in
            if let app { return "Replies cannot be sent to \(app) here." }
            return "Replies cannot be sent to this terminal here."
        },
        tooLong: { "Text longer than \($0) characters cannot be sent here." }
    )
}
