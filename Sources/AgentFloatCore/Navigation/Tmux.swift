import Foundation

public enum TmuxCLI {
    /// pane id 는 `%` 뒤 숫자다. 명령 인자와 새 탭 입력에 그대로 들어가므로 이 형태만 받는다
    public static func isPaneId(_ text: String) -> Bool {
        guard text.first == "%", text.count > 1 else { return false }
        return text.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }
}
