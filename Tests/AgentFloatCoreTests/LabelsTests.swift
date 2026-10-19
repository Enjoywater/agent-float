import Foundation
import Testing
@testable import AgentFloatCore

@Test func elapsedShortForms() {
    #expect(Labels.elapsed(-5) == "<1m"); #expect(Labels.elapsed(59) == "<1m")
    #expect(Labels.elapsed(60) == "1m");  #expect(Labels.elapsed(3_599) == "59m")
    #expect(Labels.elapsed(3_600) == "1h"); #expect(Labels.elapsed(86_399) == "23h")
    #expect(Labels.elapsed(86_400) == "1d")
}

@Test func folderLabel() {
    #expect(Labels.folder(cwd: "/Users/me", home: "/Users/me") == "~")
    #expect(Labels.folder(cwd: "", home: "/Users/me") == "~")
    #expect(Labels.folder(cwd: "/Users/me/orca/workspaces/sample-app/", home: "/Users/me") == "sample-app")
}

@Test func waitReasonCopy() {
    #expect(Labels.waitReason(.question) == "질문 답변 대기")
    #expect(Labels.waitReason(.bodyQuestion) == "질문(본문)")
    #expect(Labels.waitReason(.permission) == "승인 대기")
    #expect(Labels.waitReason(.worker) == "워커 요청 대기")
    #expect(Labels.waitReason(.sandbox) == "샌드박스 승인 대기")
    #expect(Labels.waitReason(.dialog) == "창 열림")
    #expect(Labels.waitReason(.other("custom thing")) == "custom thing")
}

@Test func inactivityCopy() {
    let now = Date(timeIntervalSince1970: 10_000)
    #expect(Labels.inactivity(since: now.addingTimeInterval(-14 * 60 - 5), now: now) == "14분째 활동 없음")
}
