public enum TerminalBundle {
    public static let ghostty = "com.mitchellh.ghostty"
    public static let orca = "com.stablyai.orca"
    public static let appleTerminal = "com.apple.Terminal"
    public static let iTerm = "com.googlecode.iterm2"
    public static let cursor = "com.todesktop.230313mzl4w4u92"
    public static let vscode = "com.microsoft.VSCode"
}

/// 이동 명령이 성공해도 그 앱이 실제로 앞에 왔다는 보장은 없다(macOS 14+ 협조적 활성화).
/// 앞에 온 앱이 기대한 앱일 때만 사용자가 그 터미널을 봤다고 본다 (R37)
public enum ExpectedFrontmost: Equatable, Sendable {
    case bundle(String)
    case process(Int32)

    /// 폴백은 조상 중 어느 앱을 올렸는지 실행해 봐야 알 수 있어 그 pid 를 따로 받는다
    public static func expected(for locator: TerminalLocator, activatedPid: Int32?) -> ExpectedFrontmost? {
        switch locator {
        case .ghostty, .background: .bundle(TerminalBundle.ghostty)
        case .orca: .bundle(TerminalBundle.orca)
        case .appleTerminal: .bundle(TerminalBundle.appleTerminal)
        case .iTerm: .bundle(TerminalBundle.iTerm)
        // 붙은 클라이언트가 없으면 Ghostty 새 탭에서 붙이므로, 올린 바깥 앱이 기록되지 않았으면 Ghostty 를 기대한다
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

/// Ghostty 직접 선택 감시의 간격. 실패가 이어지면 간격을 늘리고, 자동화 권한이 거부되면 다시 허용될 때까지 멈춘다 (R38)
public struct GhosttyWatchSchedule: Equatable, Sendable {
    public static let baseInterval: Duration = .seconds(3)
    public static let maxInterval: Duration = .seconds(60)
    // 2^5 배면 이미 상한을 넘으므로 그 이상은 셀 필요가 없다
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
        // 감시를 멈추거나 세션이 사라져 스스로 취소한 것은 Ghostty 쪽 실패가 아니다
        if error is CancellationError { return }
        if Self.isAutomationDenied(error) {
            isSuspended = true
            return
        }
        consecutiveFailures += 1
    }

    /// 권한 상태가 바뀌었을 수 있는 시점(이동 성공)에 다시 시도할 수 있게 한다
    public mutating func resume() {
        isSuspended = false
        consecutiveFailures = 0
    }

    /// -1743 은 사용자가 거부한 경우, -1744 는 승인 창을 띄울 수 없어 동의가 필요한 경우다. 둘 다 재시도로는 풀리지 않는다
    public static func isAutomationDenied(_ error: any Error) -> Bool {
        guard case let .commandFailed(message) = error as? NavigationError else { return false }
        return message.contains("-1743") || message.contains("-1744") || message.contains("Not authorized to send Apple events")
    }
}
