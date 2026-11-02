import Foundation

/// Hide agent-specific storage behind AgentSession so adding providers does not change rendering.
public protocol AgentProvider: Sendable {
    var id: String { get }
    /// Providers expose their own watch directories because agent storage layouts differ.
    var watchedDirectories: [URL] { get }
    func snapshot(now: Date) throws -> [AgentSession]
}
