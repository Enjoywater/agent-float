public protocol TerminalNavigator: Sendable {
    func canNavigate(_ session: AgentSession) -> Bool
    func navigate(to session: AgentSession) async throws
}

/// Identify sessions selected manually in their terminal (spec §4.6, clearing condition 2).
/// A selected tab matters only when its app is frontmost, hence the bundle identifier.
public protocol FocusProbe: Sendable {
    var bundleIdentifier: String { get }
    /// Probe only when matchable sessions exist to preserve zero idle CPU (spec §4.9).
    func canProbe(_ session: AgentSession) -> Bool
    func focusedSessions(among sessions: [AgentSession]) async throws -> Set<SessionKey>
}

public struct NavigatorRegistry: Sendable {
    private let navigators: [any TerminalNavigator]

    public init(_ navigators: [any TerminalNavigator]) {
        self.navigators = navigators
    }

    public func canNavigate(_ session: AgentSession) -> Bool {
        navigators.contains { $0.canNavigate(session) }
    }

    /// Propagate the owner's failure; trying another navigator could raise the wrong terminal.
    public func navigate(to session: AgentSession) async throws {
        guard let navigator = navigators.first(where: { $0.canNavigate(session) }) else {
            throw NavigationError.terminalNotFound
        }
        try await navigator.navigate(to: session)
    }

    /// Bound navigation that may wait indefinitely for a first-run Automation prompt.
    /// On timeout, cancel navigation and its child commands before throwing timedOut (R23).
    public func navigate(to session: AgentSession, timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await navigate(to: session) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NavigationError.timedOut
            }
            // The first completed task decides the result; cancel and discard the other.
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
