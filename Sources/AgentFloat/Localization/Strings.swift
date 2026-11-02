import Foundation

struct Strings: Sendable {
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

    static let ko = Strings(
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
