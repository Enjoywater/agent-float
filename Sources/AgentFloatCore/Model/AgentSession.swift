import Foundation

public struct SessionKey: Hashable, Sendable {
    public let providerId: String
    public let sessionId: String

    // Explicit public construction is needed because the implicit memberwise initializer is internal.
    public init(providerId: String, sessionId: String) {
        self.providerId = providerId
        self.sessionId = sessionId
    }
}

/// Declaration order determines group order: waiting, running, done, unknown.
public enum AgentStatus: String, Sendable, CaseIterable {
    case waiting, running, done, unknown
}

public enum WaitReason: Equatable, Sendable {
    case question, bodyQuestion, permission, worker, sandbox, dialog
    case unspecified
    case other(String)
}

public enum TerminalApp: Equatable, Sendable {
    case ghostty, orca, herdr
    case other(String)
    case unknown
}

public enum TerminalLocator: Equatable, Sendable {
    case ghostty(title: String?, cwd: String)
    /// Unopened Orca worktrees may expose temporary pty tab/leaf IDs while their handles remain stable (1.4.224).
    case orca(tabId: String, leafId: String, handle: String? = nil)
    case herdr(HerdrTarget)
    case background(jobId: String)
    /// Terminal.app/iTerm2 expose each tab/session tty, uniquely matching the agent's tty.
    case appleTerminal(tty: String)
    case iTerm(tty: String)
    /// Inside tmux, select the pane first and discover the outer terminal from its client.
    /// PID keys the outer app actually activated for confirmation (R37).
    case tmux(socket: String, paneId: String, pid: Int32)
    /// When only the agent PID is known, walk ancestors to raise its terminal app.
    case application(pid: Int32)
    case none
}

public struct AgentSession: Identifiable, Equatable, Sendable {
    public var id: SessionKey { key }
    public let key: SessionKey
    public let agentName: String
    public let title: String
    public let cwd: String
    public let status: AgentStatus
    public let waitReason: WaitReason?
    public let statusSince: Date
    public let isStale: Bool
    public let lastActivityAt: Date?
    public let terminalApp: TerminalApp
    public let locator: TerminalLocator
    public let prompt: PendingPrompt?

    public init(
        key: SessionKey,
        agentName: String,
        title: String,
        cwd: String,
        status: AgentStatus,
        waitReason: WaitReason?,
        statusSince: Date,
        isStale: Bool,
        lastActivityAt: Date?,
        terminalApp: TerminalApp,
        locator: TerminalLocator,
        prompt: PendingPrompt? = nil
    ) {
        self.key = key
        self.agentName = agentName
        self.title = title
        self.cwd = cwd
        self.status = status
        self.waitReason = waitReason
        self.statusSince = statusSince
        self.isStale = isStale
        self.lastActivityAt = lastActivityAt
        self.terminalApp = terminalApp
        self.locator = locator
        self.prompt = prompt
    }
}
