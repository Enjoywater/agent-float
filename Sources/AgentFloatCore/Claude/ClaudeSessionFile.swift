import Foundation

/// `~/.claude/sessions/<pid>.json` 한 개. Claude Code 가 버전마다 필드를 바꾸므로 식별자(pid·sessionId) 외에는 모두 선택값이다
public struct ClaudeSessionFile: Decodable, Equatable, Sendable {
    public let pid: Int32
    public let sessionId: String
    public let cwd: String?
    public let kind: String?
    public let status: String?
    public let waitingFor: String?
    public let name: String?
    public let statusUpdatedAt: Double?
    public let procStart: String?
    public let jobId: String?

    public static func parse(_ data: Data) -> ClaudeSessionFile? {
        try? JSONDecoder().decode(ClaudeSessionFile.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, kind, status, waitingFor, name, statusUpdatedAt, procStart, jobId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(Int32.self, forKey: .pid)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        // 선택 필드의 타입이 어긋났다고 세션 전체를 버리면 실행 중인 에이전트가 목록에서 사라진다
        cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        waitingFor = try? container.decodeIfPresent(String.self, forKey: .waitingFor)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        statusUpdatedAt = try? container.decodeIfPresent(Double.self, forKey: .statusUpdatedAt)
        procStart = try? container.decodeIfPresent(String.self, forKey: .procStart)
        jobId = try? container.decodeIfPresent(String.self, forKey: .jobId)
    }

    // 사용자 정의 init(from:) 가 있으면 memberwise init 이 사라지므로 테스트·상위 계층용으로 따로 둔다
    public init(
        pid: Int32,
        sessionId: String,
        cwd: String? = nil,
        kind: String? = nil,
        status: String? = nil,
        waitingFor: String? = nil,
        name: String? = nil,
        statusUpdatedAt: Double? = nil,
        procStart: String? = nil,
        jobId: String? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.kind = kind
        self.status = status
        self.waitingFor = waitingFor
        self.name = name
        self.statusUpdatedAt = statusUpdatedAt
        self.procStart = procStart
        self.jobId = jobId
    }
}
