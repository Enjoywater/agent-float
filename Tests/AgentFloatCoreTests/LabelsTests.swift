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
