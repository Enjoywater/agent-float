import Foundation

public struct SessionKey: Hashable, Sendable {
    public let providerId: String
    public let sessionId: String

    // 암시적 memberwise init 은 internal 이라 앱 타깃에서 쓸 수 있게 명시한다
    public init(providerId: String, sessionId: String) {
        self.providerId = providerId
        self.sessionId = sessionId
    }
}

/// 선언 순서가 곧 화면의 묶음 순서다 (대기 → 실행 → 완료 → 알 수 없음)
public enum AgentStatus: String, Sendable, CaseIterable {
    case waiting, running, done, unknown
}

public enum WaitReason: Equatable, Sendable {
    case question, bodyQuestion, permission, worker, sandbox, dialog
    case other(String)
}

public enum TerminalApp: Equatable, Sendable {
    case ghostty, orca
    case other(String)
    case unknown
}

public enum TerminalLocator: Equatable, Sendable {
    case ghostty(title: String?, cwd: String)
    /// 아직 열지 않은 워크트리의 터미널은 목록에 tab·leaf 가 임시 값(`pty:…`)으로 나와도 handle 은 그대로 맞는다 (Orca 1.4.224 실측)
    case orca(tabId: String, leafId: String, handle: String? = nil)
    case background(jobId: String)
    /// Terminal.app·iTerm2 는 탭(세션)마다 tty 를 알려 줘서, 세션 프로세스의 tty 와 맞추면 탭이 하나로 정해진다
    case appleTerminal(tty: String)
    case iTerm(tty: String)
    /// tmux 안에서는 바깥 터미널의 탭을 직접 알 수 없어 pane 으로 먼저 가고, 바깥 터미널은 tmux 클라이언트에서 찾는다.
    /// pid 는 바깥 터미널로 실제 올린 앱을 기록·확인하는 열쇠다 (R37)
    case tmux(socket: String, paneId: String, pid: Int32)
    /// 정확한 탭은 모르고 세션 프로세스만 앎 → 부모를 따라 터미널 앱을 앞으로 올리는 폴백 대상
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
