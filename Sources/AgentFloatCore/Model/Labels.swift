import Foundation

public enum Labels {
    /// Show elapsed status time using the largest unit only; less than a minute is <1m.
    public static func elapsed(_ interval: TimeInterval) -> String {
        switch interval {
        case ..<60: "<1m"
        case ..<3_600: "\(Int(interval / 60))m"
        case ..<86_400: "\(Int(interval / 3_600))h"
        default: "\(Int(interval / 86_400))d"
        }
    }

    /// Use the final folder component to fit the widget; home and empty paths display ~.
    public static func folder(cwd: String, home: String) -> String {
        let path = trimmingTrailingSlashes(cwd)
        if cwd.isEmpty || path == trimmingTrailingSlashes(home) { return "~" }
        return path.split(separator: "/").last.map(String.init) ?? "/"
    }

    public static func inactivityMinutes(since: Date, now: Date) -> Int {
        Int(max(0, now.timeIntervalSince(since)) / 60)
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }
}
