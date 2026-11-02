/// App-level fallback when the exact tab is unknown; inject AppKit-dependent GUI discovery/activation from the app target.
public struct AppActivationNavigator: TerminalNavigator {
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
        guard activateFirstApp(ProcessAncestry.chain(from: pid, inspector: inspector)) else { throw NavigationError.terminalNotFound }
    }
}

enum ProcessAncestry {
    // Bound traversal to terminate on cycles or excessively deep parent trees.
    static let maxChainLength = 32

    /// Order nearest ancestors first so the innermost GUI app wins.
    static func chain(from pid: Int32, inspector: any ProcessInspecting) -> [Int32] {
        var chain = [pid]
        while chain.count < maxChainLength,
              let parent = inspector.parentPid(of: chain[chain.count - 1]),
              !chain.contains(parent) {
            chain.append(parent)
        }
        return chain
    }
}
