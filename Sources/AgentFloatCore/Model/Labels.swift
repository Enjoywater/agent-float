import Foundation

public enum Labels {
    /// 상태가 유지된 시간을 가장 큰 단위 하나로만 보여준다 (분 미만은 "<1m")
    public static func elapsed(_ interval: TimeInterval) -> String {
        switch interval {
        case ..<60: "<1m"
        case ..<3_600: "\(Int(interval / 60))m"
        case ..<86_400: "\(Int(interval / 3_600))h"
        default: "\(Int(interval / 86_400))d"
        }
    }

    /// 경로 전체는 위젯 폭에 안 맞아 마지막 폴더명만 쓴다. 홈과 빈 값은 "~"
    public static func folder(cwd: String, home: String) -> String {
        let path = trimmingTrailingSlashes(cwd)
        if cwd.isEmpty || path == trimmingTrailingSlashes(home) { return "~" }
        return path.split(separator: "/").last.map(String.init) ?? "/"
    }

    public static func waitReason(_ reason: WaitReason) -> String {
        switch reason {
        case .question: "질문 답변 대기"
        case .bodyQuestion: "질문(본문)"
        case .permission: "승인 대기"
        case .worker: "워커 요청 대기"
        case .sandbox: "샌드박스 승인 대기"
        case .dialog: "창 열림"
        case .other(let text): text
        }
    }

    public static func inactivity(since: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(since)) / 60)
        return "\(minutes)분째 활동 없음"
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }
}
