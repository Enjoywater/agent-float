/// 정확한 탭을 모르는 세션을 위한 앱 단위 폴백. GUI 앱 판별·활성화는 AppKit 이 필요해 앱 타깃이 클로저로 주입한다
public struct AppActivationNavigator: TerminalNavigator {
    // 순환하는 부모 표나 비정상적으로 깊은 트리에서도 순회가 끝나도록 상한을 둔다
    private static let maxChainLength = 32

    private let inspector: any ProcessInspecting
    private let activateFirstApp: @Sendable ([Int32]) -> Bool

    public init(inspector: any ProcessInspecting, activateFirstApp: @escaping @Sendable ([Int32]) -> Bool) {
        self.inspector = inspector
        self.activateFirstApp = activateFirstApp
    }

    public func canNavigate(_ session: AgentSession) -> Bool {
        if case .application = session.locator { return true }
        return false
    }

    public func navigate(to session: AgentSession) async throws {
        guard case let .application(pid) = session.locator else { throw NavigationError.terminalNotFound }
        // 가까운 조상부터 넘겨야 가장 안쪽의 GUI 앱이 먼저 고려된다
        var chain = [pid]
        while chain.count < Self.maxChainLength,
              let parent = inspector.parentPid(of: chain[chain.count - 1]),
              !chain.contains(parent) {
            chain.append(parent)
        }
        guard activateFirstApp(chain) else { throw NavigationError.terminalNotFound }
    }
}
