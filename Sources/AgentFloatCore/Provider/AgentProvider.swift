import Foundation

/// 에이전트별 저장 형식을 `AgentSession` 뒤에 가두는 경계. 다른 AI 에이전트를 붙여도 화면 쪽은 바뀌지 않게 한다
public protocol AgentProvider: Sendable {
    var id: String { get }
    /// 에이전트마다 상태가 쌓이는 위치가 달라 감시 대상은 provider 가 알려준다
    var watchedDirectories: [URL] { get }
    func snapshot(now: Date) throws -> [AgentSession]
}
