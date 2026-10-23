import Testing
@testable import AgentFloatCore

@Suite struct PendingPromptTests {
    @Test func recommendedSuffixBecomesBadge() {
        let option = ChoiceOption(label: "읽은 때부터 다시 세기 (Recommended)", description: "읽을 때마다 만료가 10분 늘어남", hasPreview: false)
        #expect(option.displayLabel == "읽은 때부터 다시 세기")
        #expect(option.isRecommended)
    }

    @Test func plainLabelIsUnchanged() {
        let option = ChoiceOption(label: "고정 10분 유지", description: nil, hasPreview: false)
        #expect(option.displayLabel == "고정 10분 유지")
        #expect(!option.isRecommended)
    }

    @Test func promptIdComesFromEachCase() {
        #expect(PendingPrompt.choices(id: "toolu_01", questions: []).id == "toolu_01")
        #expect(PendingPrompt.text(id: "a-2", message: "진행할까요?").id == "a-2")
        #expect(PendingPrompt.permission(id: "toolu_02", tool: "Bash", summary: "swift test").id == "toolu_02")
    }
}
