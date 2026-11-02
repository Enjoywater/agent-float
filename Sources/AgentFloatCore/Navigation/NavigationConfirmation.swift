public enum TerminalBundle {
    public static let ghostty = "com.mitchellh.ghostty"
    public static let orca = "com.stablyai.orca"
    public static let appleTerminal = "com.apple.Terminal"
    public static let iTerm = "com.googlecode.iterm2"
    public static let cursor = "com.todesktop.230313mzl4w4u92"
    public static let vscode = "com.microsoft.VSCode"
}

/// Successful navigation commands do not guarantee foreground activation under macOS 14+ cooperative activation.
/// Only consider the terminal seen when the expected app becomes frontmost (R37).
public enum ExpectedFrontmost: Equatable, Sendable {
    case bundle(String)
    case process(Int32)

    /// Fallback app choice is discovered at runtime; accept its separately recorded PID.
    public static func expected(for locator: TerminalLocator, activatedPid: Int32?) -> ExpectedFrontmost? {
        switch locator {
        case .ghostty, .background: .bundle(TerminalBundle.ghostty)
        case .orca: .bundle(TerminalBundle.orca)
        case .appleTerminal: .bundle(TerminalBundle.appleTerminal)
        case .iTerm: .bundle(TerminalBundle.iTerm)
        // Without an attached tmux client, a new Ghostty tab attaches; expect Ghostty unless an outer app was recorded.
        case .tmux: activatedPid.map(ExpectedFrontmost.process) ?? .bundle(TerminalBundle.ghostty)
        case .application: activatedPid.map(ExpectedFrontmost.process)
        case .none: nil
        }
    }

    public func isReached(byBundle bundleIdentifier: String?, pid: Int32?) -> Bool {
        switch self {
        case let .bundle(expected): bundleIdentifier == expected
        case let .process(expected): pid == expected
        }
    }
}

/// Per-app manual-selection schedules back off on failure and suspend on Automation denial until restored (R38).
public struct FocusWatchSchedule: Equatable, Sendable {
    public static let baseInterval: Duration = .seconds(3)
    public static let maxInterval: Duration = .seconds(60)
    // Five doublings already exceed the cap; larger counts are unnecessary.
    private static let maxDoublings = 5

    public private(set) var isSuspended = false
    private var consecutiveFailures = 0

    public init() {}

    public var interval: Duration {
        min(Self.baseInterval * (1 << min(consecutiveFailures, Self.maxDoublings)), Self.maxInterval)
    }

    public mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    public mutating func recordFailure(_ error: any Error) {
        // Cancellation caused by stopping a probe or removing a session is not an app failure.
        if error is CancellationError { return }
        if Self.isAutomationDenied(error) {
            isSuspended = true
            return
        }
        consecutiveFailures += 1
    }

    /// Successful navigation may reflect restored permission, allowing a suspended probe to resume.
    public mutating func resume() {
        isSuspended = false
        consecutiveFailures = 0
    }

    /// Automation errors -1743 (denied) and -1744 (consent needed but prompt unavailable) cannot be fixed by retrying.
    public static func isAutomationDenied(_ error: any Error) -> Bool {
        guard case let .commandFailed(message) = error as? NavigationError else { return false }
        return message.contains("-1743") || message.contains("-1744") || message.contains("Not authorized to send Apple events")
    }
}
