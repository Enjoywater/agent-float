import Foundation
import Testing
import AgentFloatCore
@testable import AgentFloat

@Test func waitReasonCopy() {
    #expect(Strings.ko.waitReason(.question) == "질문 답변 대기")
    #expect(Strings.ko.waitReason(.bodyQuestion) == "질문(본문)")
    #expect(Strings.ko.waitReason(.permission) == "승인 대기")
    #expect(Strings.ko.waitReason(.worker) == "워커 요청 대기")
    #expect(Strings.ko.waitReason(.sandbox) == "샌드박스 승인 대기")
    #expect(Strings.ko.waitReason(.dialog) == "창 열림")
    #expect(Strings.ko.waitReason(.other("custom thing")) == "custom thing")
}

@Test func inactivityCopy() {
    let now = Date(timeIntervalSince1970: 10_000)
    #expect(Strings.ko.inactivity(Labels.inactivityMinutes(since: now.addingTimeInterval(-14 * 60 - 5), now: now)) == "14분째 활동 없음")
}

@Test func englishBoundaryCopy() {
    #expect(Strings.en.inactivity(1) == "No activity for 1 minute")
    #expect(Strings.en.inactivity(2) == "No activity for 2 minutes")
    #expect(Strings.en.waitReason(.unspecified) == "Waiting")
    #expect(Strings.en.reply.readOnly(.unsupportedTerminal(nil)).detail == "Replies cannot be sent to this terminal here.")
    #expect(Strings.ko.reply.readOnly(.unsupportedTerminal(nil)).detail == "이 터미널에는 여기서 보낼 수 없어요")
}
