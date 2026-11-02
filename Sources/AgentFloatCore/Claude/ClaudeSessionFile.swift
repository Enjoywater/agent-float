import Foundation

/// One ~/.claude/sessions/<pid>.json file; only pid/sessionId are required because fields vary by Claude Code version.
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
        // A malformed optional field must not hide an otherwise live agent.
        cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        waitingFor = try? container.decodeIfPresent(String.self, forKey: .waitingFor)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        statusUpdatedAt = try? container.decodeIfPresent(Double.self, forKey: .statusUpdatedAt)
        procStart = try? container.decodeIfPresent(String.self, forKey: .procStart)
        jobId = try? container.decodeIfPresent(String.self, forKey: .jobId)
    }

    // Provide explicit construction for tests/callers because custom decoding suppresses the memberwise initializer.
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
