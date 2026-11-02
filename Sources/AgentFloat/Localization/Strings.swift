import AgentFloatCore
import Foundation

struct Strings: Sendable {
    let untitled: String
    let waiting: String
    let running: String
    let done: String
    let unknown: String
    let selected: String
    let sending: String
    let terminal: String
    let questionWait: String
    let bodyWait: String
    let permissionWait: String
    let workerWait: String
    let sandboxWait: String
    let dialogWait: String
    let unspecifiedWait: String
    let inactivity: @Sendable (Int) -> String
    let terminalName: @Sendable (String) -> String
    let agentName: @Sendable (String) -> String
    let optionNumber: @Sendable (Int) -> String
    let questionNumber: @Sendable (Int) -> String
    let questionProgress: @Sendable (Int, Int) -> String
    let reply: ReplyStrings
    let resetPosition: String
    let edgeContrast: String
    let replyView: String
    let iconLocation: String
    let launchAtLogin: String
    let quit: String
    let plainGlass: String
    let outline: String
    let inverse: String
    let panel: String
    let inline: String
    let card: String
    let menuBar: String
    let dock: String
    let both: String
    let editMenu: String
    let undo: String
    let redo: String
    let cut: String
    let copy: String
    let paste: String
    let selectAll: String

    func waitReason(_ reason: WaitReason) -> String {
        switch reason {
        case .question: questionWait
        case .bodyQuestion: bodyWait
        case .permission: permissionWait
        case .worker: workerWait
        case .sandbox: sandboxWait
        case .dialog: dialogWait
        case .unspecified: unspecifiedWait
        case let .other(value): value
        }
    }

    static let ko = Strings(
        untitled: "이름 없는 세션",
        waiting: "내 응답 대기",
        running: "진행 중",
        done: "완료",
        unknown: "상태 확인 불가",
        selected: "선택됨",
        sending: "보내는 중",
        terminal: "터미널",
        questionWait: "질문 답변 대기",
        bodyWait: "질문(본문)",
        permissionWait: "승인 대기",
        workerWait: "워커 요청 대기",
        sandboxWait: "샌드박스 승인 대기",
        dialogWait: "창 열림",
        unspecifiedWait: "대기",
        inactivity: { "\($0)분째 활동 없음" },
        terminalName: { "\($0) 터미널" }, agentName: { "\($0) 에이전트" },
        optionNumber: { "\($0)번" }, questionNumber: { "질문 \($0)" },
        questionProgress: { "질문 \($0) / \($1)" },
        reply: .ko,
        resetPosition: "위치 초기화",
        edgeContrast: "가장자리 대비",
        replyView: "답장 화면",
        iconLocation: "아이콘 위치",
        launchAtLogin: "로그인 시 실행",
        quit: "Agent Float 종료",
        plainGlass: "유리 그대로",
        outline: "윤곽선",
        inverse: "뒤 화면과 반대",
        panel: "패널 전환",
        inline: "줄 안에서 펼침",
        card: "옆에 카드",
        menuBar: "메뉴바에서 보기",
        dock: "Dock에서 보기",
        both: "둘 다 보기",
        editMenu: "편집",
        undo: "실행 취소",
        redo: "실행 복귀",
        cut: "오려두기",
        copy: "복사하기",
        paste: "붙여넣기",
        selectAll: "모두 선택"
    )

    static let en = Strings(
        untitled: "Untitled session",
        waiting: "Awaiting you",
        running: "Running",
        done: "Done",
        unknown: "Status unavailable",
        selected: "Selected",
        sending: "Sending",
        terminal: "Terminal",
        questionWait: "Awaiting answer",
        bodyWait: "Question in reply",
        permissionWait: "Awaiting approval",
        workerWait: "Awaiting worker request",
        sandboxWait: "Awaiting sandbox approval",
        dialogWait: "Dialog open",
        unspecifiedWait: "Waiting",
        inactivity: { minutes in
            if minutes == 1 { return "No activity for 1 minute" }
            return "No activity for \(minutes) minutes"
        },
        terminalName: { "\($0) terminal" }, agentName: { "\($0) agent" },
        optionNumber: { "Option \($0)" }, questionNumber: { "Question \($0)" },
        questionProgress: { "Question \($0) of \($1)" },
        reply: .en,
        resetPosition: "Reset Position",
        edgeContrast: "Edge Contrast",
        replyView: "Reply View",
        iconLocation: "Icon Location",
        launchAtLogin: "Launch at Login",
        quit: "Quit Agent Float",
        plainGlass: "Plain Glass",
        outline: "Outline",
        inverse: "Inverse of Background",
        panel: "Switch Panel",
        inline: "Expand in Row",
        card: "Side Card",
        menuBar: "Menu Bar",
        dock: "Dock",
        both: "Both",
        editMenu: "Edit",
        undo: "Undo",
        redo: "Redo",
        cut: "Cut",
        copy: "Copy",
        paste: "Paste",
        selectAll: "Select All"
    )
}
